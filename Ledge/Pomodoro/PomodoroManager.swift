import AppKit
import Combine
import SwiftUI

/// A user-defined named timer (name + duration in minutes). The order of the
/// presets in Settings is also the auto-chain order: when »automatisch
/// fortsetzen« is on, a completed timer starts the next preset in the list,
/// wrapping around — ordering them Fokus/Pause/… yields a pomodoro cycle.
struct TimerPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var minutes: Int
    /// Whether a completed/aborted run of this preset counts as concentrated
    /// work and gets logged to the Obsidian daily note. Decoded presets saved
    /// before this field existed default to `true` (see `init(from:)`).
    var isFocus: Bool = true

    var duration: TimeInterval { TimeInterval(minutes) * 60 }

    /// The duration formatted the way the running readout will show it, for
    /// the idle preview in the timer tab.
    var formattedDuration: String {
        PomodoroManager.timeString(Int(duration), style: duration >= 3600 ? .hours : .minutes)
    }

    init(id: UUID = UUID(), name: String, minutes: Int, isFocus: Bool = true) {
        self.id = id
        self.name = name
        self.minutes = minutes
        self.isFocus = isFocus
    }

    private enum CodingKeys: String, CodingKey { case id, name, minutes, isFocus }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        minutes = try container.decode(Int.self, forKey: .minutes)
        isFocus = try container.decodeIfPresent(Bool.self, forKey: .isFocus) ?? true
    }

    static let defaults: [TimerPreset] = [
        TimerPreset(name: String(localized: "timer.preset.focus", defaultValue: "Fokus"), minutes: 25, isFocus: true),
        TimerPreset(name: String(localized: "timer.preset.shortBreak", defaultValue: "Kurze Pause"), minutes: 5, isFocus: false),
        TimerPreset(name: String(localized: "timer.preset.longBreak", defaultValue: "Lange Pause"), minutes: 15, isFocus: false),
    ]
}

/// Drives the named focus timers: one session at a time, ticking once per
/// second only while running (no idle polling). All session maths are
/// wall-clock based (`runStartedAt` + `accumulated`), so system sleep, screen
/// sleep and even a relaunch never desync the readout — the timer keeps
/// "running" through them and a missed completion fires on the next resume.
final class PomodoroManager: ObservableObject {
    enum Phase { case idle, running, paused }

    @Published private(set) var phase: Phase = .idle
    /// Name snapshot of the running preset — editing or deleting the preset in
    /// Settings must not rename or kill an in-flight session.
    @Published private(set) var activeName: String?
    /// The collapsed pill's readout ("24:59" / "0:24:59"), nil while idle.
    /// Also the width driver: `NotchViewModel.collapsedWidth` sizes the timer
    /// segment from this string's length, so the format is fixed per session
    /// (chosen from the duration, see `timeString`) and never jitters mid-run.
    @Published private(set) var pillText: String?
    /// Elapsed fraction 0…1 — fills up in both count directions.
    @Published private(set) var progress: Double = 0
    /// The preset highlighted in the timer tab (the start target while idle).
    @Published var selectedPresetID: UUID?

    private let activities: ActivityManager
    private let settings: UserSettings
    private var timer: Timer?
    private var screensAwake = true
    private var cancellables = Set<AnyCancellable>()

    // Active session, wall-clock based.
    private var activePresetID: UUID?
    private var duration: TimeInterval = 0
    /// Elapsed time folded in by finished run segments (grows on pause).
    private var accumulated: TimeInterval = 0
    /// Start of the current run segment; nil while paused/idle.
    private var runStartedAt: Date?
    /// Snapshot of `preset.isFocus` — like `activeName`, editing the preset in
    /// Settings mid-run must not change whether this session gets logged.
    private var activeIsFocus = false
    /// Real wall-clock start of the session, unlike `runStartedAt` which goes
    /// `nil` across a pause. Used only for the Obsidian focus-session log.
    private var sessionStartedAt: Date?

    private let storeFile = "pomodoro.json"

    private var elapsed: TimeInterval {
        accumulated + (runStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    init(activities: ActivityManager, settings: UserSettings = .shared) {
        self.activities = activities
        self.settings = settings
        restore()
        if selectedPresetID == nil { selectedPresetID = settings.timerPresets.first?.id }
        // Flip the readout immediately when the count direction changes — also
        // for a *paused* session, which has no tick to pick the change up.
        // @Published emits on willSet, so use the emitted value, not the property.
        settings.$timerCountsUp
            .dropFirst()
            .sink { [weak self] countsUp in self?.refreshDisplay(countsUp: countsUp) }
            .store(in: &cancellables)
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Session control

    func start(_ preset: TimerPreset) {
        stopTimer()
        activePresetID = preset.id
        duration = preset.duration
        accumulated = 0
        runStartedAt = Date()
        sessionStartedAt = runStartedAt
        activeIsFocus = preset.isFocus
        selectedPresetID = preset.id
        withAnimation(NotchLayout.islandMorphAnimation) {
            activeName = preset.name
            phase = .running
            refreshDisplay()
        }
        startTimer()
        persist()
    }

    func pause() {
        guard phase == .running else { return }
        accumulated = elapsed
        runStartedAt = nil
        stopTimer()
        withAnimation(NotchLayout.islandMorphAnimation) { phase = .paused }
        persist()
    }

    func resume() {
        guard phase == .paused else { return }
        runStartedAt = Date()
        withAnimation(NotchLayout.islandMorphAnimation) { phase = .running }
        startTimer()
        persist()
    }

    /// Abandon the session without completion side effects (no sound, no
    /// banner, no chain) — but a focus preset still logs the time actually
    /// spent, since an interrupted focus block is real concentrated work too.
    func reset() {
        if phase != .idle { logSessionIfNeeded(endedAt: Date()) }
        clearState()
    }

    private func clearState() {
        stopTimer()
        activePresetID = nil
        duration = 0
        accumulated = 0
        runStartedAt = nil
        sessionStartedAt = nil
        activeIsFocus = false
        withAnimation(NotchLayout.islandMorphAnimation) {
            phase = .idle
            activeName = nil
            pillText = nil
            progress = 0
        }
        persist()
    }

    /// End the session now as if it ran out, silently — chains to the next
    /// preset when auto-chain is on, otherwise just stops.
    func skip() {
        guard phase != .idle else { return }
        complete(notify: false)
    }

    /// Settings → reset. The store file is already gone (`Persistence.resetAll`
    /// wiped the directory); this drops the in-memory session without logging
    /// a focus entry for it — a full data wipe isn't a real abandoned session.
    func clear() {
        clearState()
    }

    // MARK: Lifecycle gates

    /// Screen sleep is not system sleep: the session keeps running on wall
    /// clock, we just stop ticking a readout nobody can see (same policy as
    /// `NowPlayingManager`). On wake, catch up immediately — including firing
    /// a completion that came due while the display was dark.
    func setScreensAwake(_ awake: Bool) {
        screensAwake = awake
        if awake {
            guard phase == .running else { return }
            startTimer()
            tick()
        } else {
            stopTimer()
        }
    }

    /// System sleep: per-second timers must not stay armed through sleep (see
    /// `AppDelegate.registerSleepWakeObservers`). Session state is untouched.
    func suspendTicking() {
        stopTimer()
    }

    func resumeTicking() {
        guard phase == .running else { return }
        startTimer()
        tick()
    }

    // MARK: Ticking

    private func startTimer() {
        stopTimer()
        guard screensAwake else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard phase == .running else { return }
        if elapsed >= duration {
            complete()
        } else {
            refreshDisplay()
        }
    }

    // MARK: Completion

    private func complete(notify: Bool = true) {
        stopTimer()
        logSessionIfNeeded(endedAt: Date())
        let finishedID = activePresetID
        let name = activeName ?? ""
        if notify {
            if settings.timerSoundEnabled {
                NSSound(named: "Glass")?.play()
            }
            // Priority 4: above the volume/brightness HUD (3), below a
            // connecting audio device (5).
            activities.present(NotchActivity(
                kind: .pomodoroEnd,
                priority: 4,
                icon: "timer",
                tint: .orange,
                title: String(localized: "activity.timerDone", defaultValue: "„\(name)“ beendet"),
                autoDismiss: 4
            ))
        }
        if settings.timerAutoChain, let next = nextPreset(after: finishedID) {
            start(next)
        } else {
            // Already logged above — clear state without logging again (unlike
            // `reset()`, which logs for the abandon-mid-session call path).
            clearState()
        }
    }

    /// The preset after `id` in list order, wrapping around. A preset deleted
    /// mid-run falls back to the first; an empty list ends the chain.
    private func nextPreset(after id: UUID?) -> TimerPreset? {
        let presets = settings.timerPresets
        guard !presets.isEmpty else { return nil }
        guard let id, let index = presets.firstIndex(where: { $0.id == id }) else { return presets.first }
        return presets[(index + 1) % presets.count]
    }

    // MARK: Readout

    private func refreshDisplay(countsUp: Bool? = nil) {
        guard phase != .idle, duration > 0 else { return }
        let up = countsUp ?? settings.timerCountsUp
        let clamped = min(max(elapsed, 0), duration)
        // Count-up floors (00:00 for the first second), count-down ceils
        // (25:00 until a full second has passed) — classic timer behaviour.
        let seconds = up ? Int(clamped.rounded(.down)) : Int((duration - clamped).rounded(.up))
        pillText = Self.timeString(seconds, style: duration >= 3600 ? .hours : .minutes)
        progress = min(clamped / duration, 1)
    }

    enum ReadoutStyle { case minutes, hours }

    /// Zero-padded readout. The style is fixed per session from the *duration*
    /// (not the current value), so the string length — and with it the pill
    /// width — stays constant for the whole run in both count directions.
    static func timeString(_ seconds: Int, style: ReadoutStyle) -> String {
        let s = max(0, seconds)
        switch style {
        case .minutes: return String(format: "%02d:%02d", s / 60, s % 60)
        case .hours: return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        }
    }

    // MARK: Obsidian focus log

    /// Log a completed or abandoned focus-preset session to the daily note.
    /// No-op for non-focus presets, when tracking is off, or for runs under a
    /// minute (avoids log spam from accidental starts). Failures (e.g. no
    /// vault configured) are silent — this is a background side effect, not a
    /// user-facing feature with its own error banner.
    private func logSessionIfNeeded(endedAt: Date) {
        guard activeIsFocus, settings.focusTrackingEnabled, let start = sessionStartedAt else { return }
        let minutes = Int(elapsed / 60)
        guard minutes >= 1 else { return }
        do {
            _ = try ObsidianVault().appendFocusSession(
                name: activeName ?? "", start: start, minutes: minutes, settings: settings)
        } catch {
            NSLog("Ledge: focus-session log failed: \(error)")
        }
    }

    // MARK: Persistence

    private struct StoredSession: Codable {
        var presetID: UUID?
        var name: String
        var duration: TimeInterval
        var accumulated: TimeInterval
        var runStartedAt: Date?
        var isFocus: Bool
        var sessionStartedAt: Date?

        init(presetID: UUID?, name: String, duration: TimeInterval, accumulated: TimeInterval,
             runStartedAt: Date?, isFocus: Bool, sessionStartedAt: Date?) {
            self.presetID = presetID
            self.name = name
            self.duration = duration
            self.accumulated = accumulated
            self.runStartedAt = runStartedAt
            self.isFocus = isFocus
            self.sessionStartedAt = sessionStartedAt
        }

        // Sessions persisted before `isFocus`/`sessionStartedAt` existed lack
        // those keys entirely — default them instead of failing to decode.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            presetID = try container.decodeIfPresent(UUID.self, forKey: .presetID)
            name = try container.decode(String.self, forKey: .name)
            duration = try container.decode(TimeInterval.self, forKey: .duration)
            accumulated = try container.decode(TimeInterval.self, forKey: .accumulated)
            runStartedAt = try container.decodeIfPresent(Date.self, forKey: .runStartedAt)
            isFocus = try container.decodeIfPresent(Bool.self, forKey: .isFocus) ?? false
            sessionStartedAt = try container.decodeIfPresent(Date.self, forKey: .sessionStartedAt)
        }
    }

    /// Saved on every transition, not per tick — the wall-clock fields fully
    /// describe a running session at any later point in time.
    private func persist() {
        guard phase != .idle else {
            Persistence.remove(storeFile)
            return
        }
        Persistence.save(
            StoredSession(presetID: activePresetID, name: activeName ?? "",
                          duration: duration, accumulated: accumulated, runStartedAt: runStartedAt,
                          isFocus: activeIsFocus, sessionStartedAt: sessionStartedAt),
            to: storeFile
        )
    }

    /// Resume a persisted session on launch (the app is a login item, so a
    /// running timer should survive a relaunch). A session that expired while
    /// the app was dead is stale news — drop it without sound, banner or chain.
    private func restore() {
        guard let stored = Persistence.load(StoredSession.self, from: storeFile) else { return }
        let storedElapsed = stored.accumulated + (stored.runStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
        guard stored.duration > 0, storedElapsed < stored.duration else {
            Persistence.remove(storeFile)
            return
        }
        activePresetID = stored.presetID
        duration = stored.duration
        accumulated = stored.accumulated
        runStartedAt = stored.runStartedAt
        activeName = stored.name
        activeIsFocus = stored.isFocus
        sessionStartedAt = stored.sessionStartedAt
        phase = stored.runStartedAt != nil ? .running : .paused
        selectedPresetID = stored.presetID
        refreshDisplay()
        if phase == .running { startTimer() }
    }
}
