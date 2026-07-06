import AppKit
import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var nowPlaying: NowPlayingManager
    /// Shared spectrum tap, owned by AppDelegate and driven centrally in
    /// `NotchRootView` (so the collapsed pill's wave is live too). The music tab
    /// just observes it.
    @ObservedObject var spectrum: SpectrumAnalyzer
    /// Local to the music tab: only needs to enumerate output devices while the
    /// tab is on screen, so it starts/stops with the view.
    @StateObject private var output = AudioOutputController()

    /// Scrub fraction while the progress bar is being dragged (nil = not dragging),
    /// so the bar follows the finger before the seek lands.
    @State private var scrubFraction: Double?

    var body: some View {
        // Empty containers (Spacers + a narrower content column) pad the edges,
        // top and bottom so the actual controls cluster closer together in the
        // centre, while the island stays solid black.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                topRow
                progressRow
                controlsRow
            }
            .frame(maxWidth: 300)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { output.start() }
        .onDisappear { output.stop() }
    }

    // MARK: Row 1 — cover · title/artist · wave

    private var topRow: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                if let track = nowPlaying.track {
                    Text(track.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                } else if nowPlaying.permissionDenied {
                    Text(String(localized: "nowplaying.denied", defaultValue: "Kein Zugriff auf den Player"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    Button(action: openAutomationSettings) {
                        Text(String(localized: "nowplaying.denied.cta", defaultValue: "Automatisierung erlauben"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor(enabled: true)
                } else {
                    Text(nowPlaying.isRunning
                         ? String(localized: "nowplaying.idle", defaultValue: "Nichts läuft")
                         : String(localized: "nowplaying.notOpen", defaultValue: "Kein Player geöffnet"))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            WaveBarsView(
                isActive: nowPlaying.isPlaying && nowPlaying.screensAwake,
                tint: nowPlaying.artworkColor,
                bands: spectrum.isLive ? spectrum.bands : nil,
                count: 5
            )
            .frame(width: 34, height: 30)
        }
    }

    /// Tapping the cover opens the song in its app (deep link, or brings the app
    /// forward). Only interactive when there's actually a track.
    private var artwork: some View {
        Button(action: { nowPlaying.openCurrentTrack() }) {
            Group {
                if let url = nowPlaying.track?.artworkURL {
                    // Cross-fade to the new cover on track change instead of
                    // popping through the grey placeholder.
                    AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            placeholderArtwork
                        }
                    }
                } else {
                    placeholderArtwork
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(nowPlaying.track == nil)
        .pointingHandCursor(enabled: nowPlaying.track != nil)
    }

    /// Deep-link straight to System Settings → Privacy & Security → Automation
    /// so the user can re-enable our Apple Events access.
    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.08))
            .overlay(
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.4))
            )
    }

    // MARK: Row 2 — current time · progress · total time

    private var fraction: Double {
        guard let duration = nowPlaying.track?.duration, duration > 0 else { return 0 }
        return min(max(nowPlaying.position / duration, 0), 1)
    }

    /// What the bar shows: the drag position while scrubbing, else live playback.
    private var displayedFraction: Double { scrubFraction ?? fraction }

    private var progressRow: some View {
        HStack(spacing: 8) {
            timeLabel(displayedFraction * (nowPlaying.track?.duration ?? 0))
            GeometryReader { geo in
                let isScrubbing = scrubFraction != nil
                // Minimal: a dim track and a bright filled bar; the play head is
                // simply the end of the filled bar (no knob). The bar thickens a
                // touch while scrubbing for feedback.
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(Color.white.opacity(isScrubbing ? 1 : 0.9))
                        .frame(width: max(0, geo.size.width * displayedFraction))
                        // Ease the fill between the 1s local position ticks and
                        // over the discontinuous jump when the 5s hard refresh
                        // corrects the interpolated position — otherwise the bar
                        // steps and snaps. No easing while scrubbing, so the bar
                        // tracks the finger instantly.
                        .animation(isScrubbing ? nil : .linear(duration: 1), value: displayedFraction)
                }
                .frame(height: isScrubbing ? 5 : 3)
                .frame(maxHeight: .infinity)   // enlarge the vertical hit area
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard nowPlaying.track?.duration ?? 0 > 0 else { return }
                            scrubFraction = min(max(value.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { _ in
                            if let f = scrubFraction, let d = nowPlaying.track?.duration {
                                nowPlaying.seek(to: f * d)
                            }
                            scrubFraction = nil
                        }
                )
                .animation(.easeOut(duration: 0.12), value: isScrubbing)
            }
            .frame(height: 14)
            timeLabel(nowPlaying.track?.duration ?? 0)
        }
    }

    private func timeLabel(_ seconds: TimeInterval) -> some View {
        Text(timeString(seconds))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .frame(width: 30)
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Row 3 — prev · play/pause · next · output picker

    private var controlsRow: some View {
        HStack(spacing: 16) {
            ControlButton(systemName: "backward.fill", size: 15, action: nowPlaying.previousTrack)
            ControlButton(
                systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                size: 20,
                action: nowPlaying.playPause
            )
            ControlButton(systemName: "forward.fill", size: 15, action: nowPlaying.nextTrack)
            outputPicker
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Audio-output selector (replaces the old shuffle + favourite buttons):
    /// pick which device the sound plays through, current one checked.
    private var outputPicker: some View {
        Menu {
            ForEach(output.devices) { device in
                Button { output.select(device) } label: {
                    if device.id == output.currentDeviceID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor(enabled: true)
    }
}

/// A pointing-hand cursor while hovering, for clickable non-button surfaces.
private struct PointingHandCursor: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        content.onHover { inside in
            if enabled, inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

extension View {
    func pointingHandCursor(enabled: Bool) -> some View {
        modifier(PointingHandCursor(enabled: enabled))
    }
}

/// Transport button with a hover highlight (visible when expanded).
private struct ControlButton: View {
    let systemName: String
    var size: CGFloat
    var color: Color = .white
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundStyle(color)
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

/// Frequency bars for the now-playing wave. When `bands` carries real spectrum
/// data (from `SpectrumAnalyzer`) the bars reflect the song's actual frequencies;
/// otherwise they fall back to a procedural animation. Tinted to the cover's
/// accent colour when one is available, else the default blue.
struct WaveBarsView: View {
    var isActive: Bool
    var tint: Color?
    /// Live per-band magnitudes (0…1). nil/empty → procedural fallback.
    var bands: [CGFloat]? = nil
    var count: Int = 4
    var maxHeight: CGFloat = 26
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3

    @ObservedObject private var settings = UserSettings.shared

    /// Per-bar fill, top-to-bottom gradient as before, but the *base* colour
    /// now depends on the chosen spectrum style: same for every bar (`.solid`,
    /// unchanged behaviour), alternating between the two accent colours, or
    /// interpolated across the bar's position for a continuous left-to-right
    /// gradient look.
    /// The two accents used by `.alternating`/`.gradient`. `.cover` derives them
    /// from the current track's accent (same source the `.solid` tint uses) so
    /// the spectrum keeps matching whatever is playing; `.manual` uses the
    /// fixed pair chosen in Settings.
    private var accentPair: (Color, Color) {
        switch settings.spectrumColorSource {
        case .manual:
            return (settings.spectrumColorA, settings.spectrumColorB)
        case .cover:
            return Color.huePair(from: tint ?? .cyan)
        }
    }

    private func gradientColors(forBarAt index: Int, total: Int) -> [Color] {
        switch settings.spectrumStyle {
        case .solid:
            if let tint { return [tint, tint.opacity(0.55)] }
            return [.cyan, .blue]
        case .shades:
            // Same hue as the cover accent throughout (clean, single-colour
            // look like the iOS Dynamic Island), but each bar's brightness
            // steps up left-to-right so it doesn't read as flat/boring.
            let t = total > 1 ? Double(index) / Double(total - 1) : 0
            let base = Color.shaded(tint ?? .cyan, t: t)
            return [base, base.opacity(0.55)]
        case .alternating:
            let (colorA, colorB) = accentPair
            let base = index % 2 == 0 ? colorA : colorB
            return [base, base.opacity(0.55)]
        case .gradient:
            let (colorA, colorB) = accentPair
            let t = total > 1 ? Double(index) / Double(total - 1) : 0
            let base = Color.mix(colorA, colorB, t: t)
            return [base, base.opacity(0.55)]
        }
    }

    private func bar(_ height: CGFloat, index: Int, total: Int) -> some View {
        Capsule()
            .fill(LinearGradient(colors: gradientColors(forBarAt: index, total: total), startPoint: .top, endPoint: .bottom))
            .frame(width: barWidth, height: height)
    }

    private var floorHeight: CGFloat { max(3, maxHeight * 0.14) }

    /// Fit the source bands to `count` bars: pass through when they match, else
    /// group into `count` buckets (max per bucket keeps the punch) so the tiny
    /// collapsed pill can show 3 bars from the 5-band spectrum.
    private func fitted(_ source: [CGFloat]) -> [CGFloat] {
        guard count > 0, !source.isEmpty else { return source }
        if source.count == count { return source }
        return (0..<count).map { i in
            let lo = i * source.count / count
            let hi = max(lo + 1, (i + 1) * source.count / count)
            return source[lo..<min(hi, source.count)].max() ?? 0
        }
    }

    var body: some View {
        if let bands, !bands.isEmpty {
            // Real spectrum: bar height follows each band; the analyzer already
            // smooths, a short animation just eases between UI updates.
            let values = fitted(bands)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(values.indices, id: \.self) { i in
                    bar(max(floorHeight, maxHeight * values[i]), index: i, total: values.count)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.09), value: values)
            .animation(.easeInOut(duration: 0.4), value: tint)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<count, id: \.self) { index in
                        bar(proceduralHeight(index: index, time: time), index: index, total: count)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .animation(.easeInOut(duration: 0.4), value: tint)
            }
        }
    }

    private func proceduralHeight(index: Int, time: Double) -> CGFloat {
        guard isActive else { return floorHeight }
        let phase = Double(index) * 0.7
        let value = 0.35 + 0.65 * abs(sin(time * 4 + phase))
        return maxHeight * CGFloat(value)
    }
}

private extension Color {
    /// Linear RGB interpolation between two colours, `t` clamped to 0...1.
    static func mix(_ a: Color, _ b: Color, t: Double) -> Color {
        let ca = NSColor(a).usingColorSpace(.deviceRGB) ?? NSColor(a)
        let cb = NSColor(b).usingColorSpace(.deviceRGB) ?? NSColor(b)
        let fraction = CGFloat(max(0, min(1, t)))
        let r = ca.redComponent + (cb.redComponent - ca.redComponent) * fraction
        let g = ca.greenComponent + (cb.greenComponent - ca.greenComponent) * fraction
        let blue = ca.blueComponent + (cb.blueComponent - ca.blueComponent) * fraction
        return Color(red: r, green: g, blue: blue)
    }

    /// A two-tone pair derived from a single base colour: same saturation and
    /// brightness, hue shifted by ~130° so the pair reads as a deliberate
    /// two-tone rather than a harsh full complementary clash.
    static func huePair(from color: Color) -> (Color, Color) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let shifted = Color(hue: (h + 0.36).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b)
        return (color, shifted)
    }

    /// Same hue/saturation as `color`, brightness scaled by position `t`
    /// (0...1) so a row of bars reads as one colour deepening/lightening
    /// across the group rather than a flat wash.
    static func shaded(_ color: Color, t: Double) -> Color {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let factor = 0.65 + 0.5 * CGFloat(max(0, min(1, t)))
        let brightness = min(1, max(0.2, b * factor))
        return Color(hue: h, saturation: s, brightness: brightness)
    }
}
