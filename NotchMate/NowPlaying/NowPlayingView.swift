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

            // Only the real track's accent when there's an actual track to
            // derive it from — otherwise (system audio with no scriptable
            // track) a stale accent from the last track shouldn't bleed in.
            //
            // `spectrum` is the shared tap and runs (and carries real bands)
            // whenever the screen is awake — regardless of whether Spotify/Music
            // is actually playing, e.g. while Safari plays a video with Spotify
            // paused. Gate `bands` on `nowPlaying.isPlaying` too, or this tab
            // shows someone else's audio moving under the paused track: `bands`
            // must never be passed live when `isActive` is false, since
            // `WaveBarsView` ignores `isActive` once it has real band data.
            WaveBarsView(
                isActive: nowPlaying.isPlaying && nowPlaying.screensAwake,
                tint: nowPlaying.track != nil ? nowPlaying.artworkColor : nil,
                secondaryTint: nowPlaying.track != nil ? nowPlaying.artworkSecondaryColor : nil,
                coverBars: nowPlaying.track != nil ? nowPlaying.coverBars : nil,
                bands: (nowPlaying.isPlaying && spectrum.isLive) ? spectrum.bands : nil,
                count: 6
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
    /// The cover's real second colour family (see `ArtworkAccents`), when it
    /// has one. Used by `.alternating`/`.gradient` in "Vom Cover" mode; nil →
    /// a pair is derived from `tint` instead.
    var secondaryTint: Color? = nil
    /// Quantised cover colours (see `ArtworkColor.fetchBarPalette`) for the
    /// `.coverImage` style: one colour per bar, taken from the slice of cover
    /// that bar sits over. nil → the style falls back to `.solid` behaviour.
    var coverBars: CoverBarPalette? = nil
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
            // Prefer the colour the sleeve actually contains; the synthetic
            // hue-shift pair is only for covers without a real second accent.
            if let tint, let secondaryTint { return (tint, secondaryTint) }
            return Color.huePair(from: tint ?? .white)
        }
    }

    // iOS's Dynamic Island wave bars are flat, fully-opaque colour top to
    // bottom — no fade. Ours used to fade each bar down to 55% opacity, which
    // (combined with how thin these bars are) made the colour nearly
    // impossible to actually see. Now returns one solid colour per bar.
    private func barColor(forBarAt index: Int, total: Int) -> Color {
        switch settings.spectrumStyle {
        case .solid, .coverImage:
            // `.coverImage` only lands here as the no-artwork fallback (with a
            // cover, the bars are a mask and their colour is irrelevant).
            // No tint (no artwork, or the cover's dominant-colour extraction
            // found no real hue) — default to white rather than a hardcoded
            // accent, matching `ArtworkColor`'s own "no real colour here" answer.
            return tint ?? .white
        case .shades:
            // Same hue as the cover accent throughout, muted toward grey at the
            // edges and fully saturated/bright toward the right — the actual
            // tell in the iOS reference (its quiet-looking edge bars are
            // washed-out, not just darker).
            let t = total > 1 ? Double(index) / Double(total - 1) : 0
            return Color.shaded(tint ?? .white, t: t)
        case .alternating:
            let (colorA, colorB) = accentPair
            return index % 2 == 0 ? colorA : colorB
        case .gradient:
            let (colorA, colorB) = accentPair
            let t = total > 1 ? Double(index) / Double(total - 1) : 0
            return Color.mix(colorA, colorB, t: t)
        }
    }

    /// `.coverImage` fill: the bar's quantised cover colour, with a faint
    /// top-to-bottom gradient. Neighbouring bars over the same region of the
    /// artwork quantise to the *same* colour — that bundling is the point — so
    /// when a column's two halves land on one palette entry the gradient is
    /// spread by brightness instead, keeping each bar from reading as a flat
    /// slab without reintroducing the old multi-colour smear.
    private func coverFill(forBarAt index: Int, total: Int) -> LinearGradient? {
        guard let pair = coverBars?.pair(forBarAt: index, total: total) else { return nil }
        let (top, bottom) = pair.top == pair.bottom
            ? (pair.top, Color.brightnessScaled(pair.bottom, 0.92))
            : pair
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    private func barFill(forBarAt index: Int, total: Int) -> AnyShapeStyle {
        if settings.spectrumStyle == .coverImage, let fill = coverFill(forBarAt: index, total: total) {
            return AnyShapeStyle(fill)
        }
        return AnyShapeStyle(barColor(forBarAt: index, total: total))
    }

    private func bar(_ height: CGFloat, index: Int, total: Int) -> some View {
        Capsule()
            .fill(barFill(forBarAt: index, total: total))
            .frame(width: barWidth, height: height)
    }

    /// iOS's spectrum bars never fully bottom out — even a silent band keeps a
    /// visible sliver. Ours read as flatter than that; nudge the hard floor up
    /// a touch (was 3) so the quietest bar still reads as "there".
    private var floorHeight: CGFloat { max(4, maxHeight * 0.14) }

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

    @ViewBuilder
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
            .animation(.easeInOut(duration: 0.4), value: secondaryTint)
            .animation(.easeInOut(duration: 0.4), value: coverBars)
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
                .animation(.easeInOut(duration: 0.4), value: secondaryTint)
                .animation(.easeInOut(duration: 0.4), value: coverBars)
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

    /// Same hue and saturation, brightness scaled by `factor` (clamped) — used
    /// to spread a faint gradient across a bar whose cover column quantised to
    /// a single colour.
    static func brightnessScaled(_ color: Color, _ factor: Double) -> Color {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: s, brightness: min(1, max(0.1, b * CGFloat(factor))))
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

    /// Same hue as `color`, saturation *and* brightness scaled by position `t`
    /// (0...1): low `t` fades toward a washed-out grey version of the hue, high
    /// `t` reaches full saturation/brightness. Matches the iOS Dynamic Island
    /// reference, where the quiet-looking bars read as genuinely desaturated,
    /// not just a darker version of the same colour (brightness-only, the
    /// original version of this, was too subtle to read as colour at all on
    /// bars this thin).
    static func shaded(_ color: Color, t: Double) -> Color {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let clampedT = CGFloat(max(0, min(1, t)))
        let saturation = s * (0.35 + 0.65 * clampedT)
        let brightness = min(1, max(0.55, b * (0.75 + 0.4 * clampedT)))
        return Color(hue: h, saturation: saturation, brightness: brightness)
    }
}
