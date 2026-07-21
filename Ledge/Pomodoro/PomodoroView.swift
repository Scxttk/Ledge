import SwiftUI

/// The timer tab in the expanded island: pick a named preset, watch the big
/// readout, and drive the session (start/pause/resume, reset, skip). The
/// passive readout in the collapsed pill mirrors the same session.
struct PomodoroView: View {
    @ObservedObject var pomodoro: PomodoroManager
    @ObservedObject private var settings = UserSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if settings.timerPresets.isEmpty && pomodoro.phase == .idle {
                Text(String(localized: "timer.empty", defaultValue: "Keine Timer angelegt. Füge welche in den Einstellungen hinzu."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            } else {
                VStack(spacing: 10) {
                    presetChips
                    readout
                    controlsRow
                }
                .frame(maxWidth: 340)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Preset chips

    private var presetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(settings.timerPresets) { preset in
                    chip(for: preset)
                }
            }
        }
    }

    /// While a session is active the chips are locked: the session runs on a
    /// snapshot of its preset, so switching mid-run would only mislead.
    private func chip(for preset: TimerPreset) -> some View {
        let isSelected = pomodoro.selectedPresetID == preset.id
        let isLocked = pomodoro.phase != .idle
        return Button {
            pomodoro.selectedPresetID = preset.id
        } label: {
            Text(preset.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(Capsule().fill(Color.white.opacity(isSelected ? 0.22 : 0.08)))
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.7))
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked && !isSelected ? 0.4 : 1)
        .pointingHandCursor(enabled: !isLocked)
    }

    // MARK: Readout

    private var selectedPreset: TimerPreset? {
        settings.timerPresets.first { $0.id == pomodoro.selectedPresetID } ?? settings.timerPresets.first
    }

    /// Live session readout, or the selected preset's duration as idle preview.
    private var displayText: String {
        if let text = pomodoro.pillText { return text }
        if let preset = selectedPreset { return preset.formattedDuration }
        return "--:--"
    }

    private var readout: some View {
        VStack(spacing: 6) {
            if let name = pomodoro.activeName {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Text(displayText)
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(pomodoro.phase == .paused ? 0.55 : 1))
            progressBar
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(Color.orange.opacity(0.9))
                    .frame(width: max(0, geo.size.width * pomodoro.progress))
                    // Ease between the 1s ticks so the fill glides instead of
                    // stepping (same trick as the music progress bar).
                    .animation(.linear(duration: 1), value: pomodoro.progress)
            }
        }
        .frame(width: 220, height: 4)
    }

    // MARK: Controls

    private var controlsRow: some View {
        HStack(spacing: 16) {
            TimerButton(systemName: "arrow.counterclockwise", size: 14, action: pomodoro.reset)
                .disabled(pomodoro.phase == .idle)
                .opacity(pomodoro.phase == .idle ? 0.35 : 1)
            TimerButton(systemName: pomodoro.phase == .running ? "pause.fill" : "play.fill", size: 20, action: primaryAction)
            if settings.timerAutoChain {
                TimerButton(systemName: "forward.end.fill", size: 14, action: pomodoro.skip)
                    .disabled(pomodoro.phase == .idle)
                    .opacity(pomodoro.phase == .idle ? 0.35 : 1)
            }
        }
    }

    private func primaryAction() {
        switch pomodoro.phase {
        case .idle:
            if let preset = selectedPreset { pomodoro.start(preset) }
        case .running:
            pomodoro.pause()
        case .paused:
            pomodoro.resume()
        }
    }
}

/// Transport-style button with a hover highlight, mirroring the music tab's
/// `ControlButton` (which is private to NowPlayingView).
private struct TimerButton: View {
    let systemName: String
    var size: CGFloat
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: 34, height: 32)
                .background(
                    Circle().fill(Color.white.opacity(hovering ? 0.16 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
