import AppKit
import Combine
import SwiftUI

/// Aggregates the available media sources into one observable now-playing state.
/// Picks the active source automatically (or per user preference), replaces the
/// old 1-second AppleScript polling with notification-driven refreshes plus
/// local position interpolation, and owns the local favorites list.
final class NowPlayingManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPlaying = false
    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var isShuffling = false
    /// A queried player is running but macOS is blocking our Apple Events, and
    /// there's nothing to show. Drives the "grant Automation access" prompt.
    @Published private(set) var permissionDenied = false
    @Published private(set) var activeSourceID: UserSettings.MediaSource = .spotify

    /// Accent colour derived from the current cover, tinting the wave visualizer.
    /// nil when there's no artwork (e.g. Apple Music) — the wave falls back to blue.
    @Published private(set) var artworkColor: Color?
    /// The cover's second and third colour families, when it really has them —
    /// feed the gradient/alternating spectrum styles in "Vom Cover" mode. nil
    /// when the artwork is essentially single-hued (the styles then derive a
    /// pair).
    @Published private(set) var artworkSecondaryColor: Color?
    @Published private(set) var artworkTertiaryColor: Color?
    /// Quantised per-column cover colours for the `.coverImage` spectrum style;
    /// nil when there's no artwork.
    @Published private(set) var coverBars: CoverBarPalette?
    /// The artwork URL the current `artworkColor` was computed for, so we only
    /// recompute when the cover actually changes.
    private var artworkColorURL: URL?

    /// False while the display sleeps: the visualizer reads this to stop its
    /// 30fps animation when nobody can see it (the idle-drain class reported
    /// against every competing notch app). See `setScreensAwake`.
    @Published private(set) var screensAwake = true

    private var favoriteKeys: Set<String>

    /// Local-only favorite marker. Player AppleScript APIs can't modify the
    /// service's Liked Songs, so this tracks favorites in-app per song.
    var isFavorite: Bool {
        guard let track else { return false }
        return favoriteKeys.contains(Self.key(for: track))
    }

    private let spotify = SpotifySource()
    private let music = AppleMusicSource()
    private var sources: [ScriptableMediaSource] { [spotify, music] }
    private var active: ScriptableMediaSource

    private let settings: UserSettings
    private var timer: Timer?
    /// Whether `start()` is in effect (distinguishes a screen-sleep pause, which
    /// keeps us "started", from a full `stop()`).
    private var isStarted = false
    private var secondsSinceHardRefresh = 0
    /// Real AppleScript refresh cadence: tight while playing (smooth position),
    /// relaxed when idle so an unused player doesn't cost a script every 5s.
    /// Genuine playback changes still arrive instantly via DistributedNotificationCenter.
    private let refreshIntervalActive = 5
    private let refreshIntervalIdle = 20
    private var currentRefreshInterval: Int { isPlaying ? refreshIntervalActive : refreshIntervalIdle }
    private var cancellable: AnyCancellable?
    private var tuningCancellable: AnyCancellable?

    init(settings: UserSettings = .shared) {
        self.settings = settings
        self.favoriteKeys = Set(Persistence.load([String].self, from: "favorites.json") ?? [])
        self.active = spotify
    }

    // MARK: Lifecycle

    func start() {
        for source in sources {
            if let name = source.changeNotification {
                DistributedNotificationCenter.default().addObserver(
                    self, selector: #selector(playbackChanged), name: name, object: nil
                )
            }
        }
        // Re-evaluate immediately when the user changes the preferred source.
        cancellable = settings.$mediaSource
            .dropFirst()
            .sink { [weak self] _ in self?.hardRefresh() }

        // Same for the cover-style tuning: recompute the current cover's bar
        // colours so the sliders read as live. Merged into one stream because
        // any of the four has the same effect.
        tuningCancellable = Publishers.MergeMany(
            settings.$coverPaletteSize.map { _ in () }.eraseToAnyPublisher(),
            settings.$coverBrightnessLevels.map { _ in () }.eraseToAnyPublisher(),
            settings.$coverBarSaturation.map { _ in () }.eraseToAnyPublisher(),
            settings.$coverBarBrightness.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(4)   // the four current values, replayed on subscribe
        // A slider drag emits continuously; recomputing per step would be
        // wasted work. Short enough to still feel immediate.
        .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.refreshCoverBars() }

        isStarted = true
        hardRefresh()
        startTimer()
    }

    func stop() {
        isStarted = false
        stopTimer()
        cancellable = nil
        tuningCancellable = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Pause/resume the per-second work and the visualizer when the display
    /// sleeps/wakes. We keep the (event-driven, cheap) DistributedNotificationCenter
    /// observers so playback state is still current the moment the screen wakes.
    func setScreensAwake(_ awake: Bool) {
        guard awake != screensAwake else { return }
        screensAwake = awake
        guard isStarted else { return }
        if awake {
            startTimer()
            hardRefresh()
        } else {
            stopTimer()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func playbackChanged() { hardRefresh() }

    private func tick() {
        secondsSinceHardRefresh += 1
        if secondsSinceHardRefresh >= currentRefreshInterval {
            hardRefresh()
            return
        }
        // Cheap local interpolation: advance the progress bar without IPC.
        guard isPlaying, let duration = track?.duration else { return }
        position = min(position + 1, duration)
    }

    // MARK: Source selection & publishing

    /// Which sources to actually query: all in auto mode (to detect the active
    /// app), only the chosen one otherwise.
    private func sourcesToQuery() -> [ScriptableMediaSource] {
        switch settings.mediaSource {
        case .auto: return sources
        case .spotify: return [spotify]
        case .appleMusic: return [music]
        }
    }

    private func hardRefresh() {
        secondsSinceHardRefresh = 0
        let group = DispatchGroup()
        for source in sourcesToQuery() {
            group.enter()
            source.refresh { _ in group.leave() }
        }
        group.notify(queue: .main) { [weak self] in self?.publishActive() }
    }

    private func selectActive() -> ScriptableMediaSource {
        switch settings.mediaSource {
        case .spotify: return spotify
        case .appleMusic: return music
        case .auto:
            if spotify.state.isPlaying { return spotify }
            if music.state.isPlaying { return music }
            if spotify.state.isRunning, spotify.state.track != nil { return spotify }
            if music.state.isRunning, music.state.track != nil { return music }
            return spotify
        }
    }

    private func publishActive() {
        active = selectActive()
        let s = active.state
        activeSourceID = active.id
        isRunning = s.isRunning
        isPlaying = s.isPlaying
        track = s.track
        position = s.position
        isShuffling = s.isShuffling
        // Only prompt when we have nothing to show anyway: any queried source
        // being blocked, with no track surfaced, means the denial is the reason.
        permissionDenied = s.track == nil && sourcesToQuery().contains { $0.state.permissionDenied }
        refreshArtworkColor(for: s.track?.artworkURL)
    }

    /// Recompute the wave tint only when the cover changes; clear it when there's
    /// no artwork so the visualizer reverts to its default blue.
    private func refreshArtworkColor(for url: URL?) {
        guard url != artworkColorURL else { return }
        artworkColorURL = url
        guard let url else {
            artworkColor = nil
            artworkSecondaryColor = nil
            artworkTertiaryColor = nil
            coverBars = nil
            return
        }
        ArtworkColor.fetch(from: url) { [weak self] accents in
            // Ignore a late result for a cover we've already moved on from.
            guard let self, self.artworkColorURL == url else { return }
            self.artworkColor = accents?.primary
            self.artworkSecondaryColor = accents?.secondary
            self.artworkTertiaryColor = accents?.tertiary
        }
        refreshCoverBars()
    }

    /// Recompute the bar palette for the cover we're already showing. Separate
    /// from `refreshArtworkColor` because the cover-style tuning can change
    /// while the same track keeps playing — the sliders in Settings are meant
    /// to be judged live, against whatever is on screen right now.
    private func refreshCoverBars() {
        guard let url = artworkColorURL else {
            coverBars = nil
            return
        }
        ArtworkColor.fetchBarPalette(from: url, tuning: CoverBarTuning(settings: settings)) { [weak self] palette in
            guard let self, self.artworkColorURL == url else { return }
            self.coverBars = palette
        }
    }

    // MARK: Transport (forward to active source)

    func playPause() { active.playPause(); scheduleQuickRefresh() }
    func nextTrack() { active.nextTrack(); scheduleQuickRefresh() }
    func previousTrack() { active.previousTrack(); scheduleQuickRefresh() }
    func toggleShuffle() { active.toggleShuffle(); scheduleQuickRefresh() }

    /// Scrub to `seconds`. Updates the local position immediately so the bar
    /// tracks the drag, then confirms with a refresh.
    func seek(to seconds: TimeInterval) {
        guard let duration = track?.duration, duration > 0 else { return }
        let target = min(max(seconds, 0), duration)
        position = target
        active.seek(to: target)
        scheduleQuickRefresh()
    }

    /// Open the current song in its app: the deep link when we have one
    /// (Spotify), otherwise just bring the player to the front (Apple Music).
    func openCurrentTrack() {
        // Only follow the player's deep link for schemes we expect; anything
        // else falls back to bringing the app forward rather than handing an
        // arbitrary URL to the system opener.
        let allowedSchemes: Set<String> = ["spotify", "https", "http"]
        if let url = track?.url, let scheme = url.scheme?.lowercased(),
           allowedSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
        } else {
            active.activate()
        }
    }

    private func scheduleQuickRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.hardRefresh()
        }
    }

    // MARK: Favorites

    func toggleFavorite() {
        guard let track else { return }
        let key = Self.key(for: track)
        if favoriteKeys.contains(key) {
            favoriteKeys.remove(key)
        } else {
            favoriteKeys.insert(key)
        }
        objectWillChange.send()
        persistFavorites()
    }

    func clearFavorites() {
        favoriteKeys.removeAll()
        objectWillChange.send()
        persistFavorites()
    }

    private func persistFavorites() {
        Persistence.save(Array(favoriteKeys), to: "favorites.json")
    }

    private static func key(for track: NowPlayingTrack) -> String {
        "\(track.name)—\(track.artist)"
    }
}
