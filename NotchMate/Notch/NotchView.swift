import SwiftUI
import AppKit

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var shelf: FileShelfModel
    @ObservedObject var activities: ActivityManager
    @ObservedObject var pomodoro: PomodoroManager
    @ObservedObject var capture: ObsidianCapture
    @ObservedObject var spectrum: SpectrumAnalyzer
    @ObservedObject var claudeUsage: ClaudeUsageModel
    @ObservedObject var claudeDriver: ClaudeSessionDriver
    /// Observed so `islandWidth` re-evaluates when the spectrum-only pill mode
    /// flips — the pill's width formula changes with it.
    @ObservedObject private var settings = UserSettings.shared

    /// Run the audio tap whenever the screen is on, regardless of whether
    /// anything is playing — `spectrum.hasSignal` (derived from the tapped
    /// signal itself, see `SpectrumAnalyzer`) is what tells the rest of the UI
    /// whether audio is actually audible right now. Gated on `screensAwake` so
    /// it isn't tapping/FFT-ing to a dark display.
    private func syncSpectrum() {
        if nowPlaying.screensAwake {
            spectrum.start()
        } else {
            spectrum.stop()
        }
    }

    /// True whenever the pill hero (cover-or-generic-icon + live wave) should
    /// take over the collapsed pill — Spotify/Music playing, or any other
    /// system audio (browser video, calls, …) with no scriptable track to show.
    private var hasAudioHero: Bool {
        nowPlaying.isPlaying || spectrum.hasSignal
    }

    private var islandWidth: CGFloat {
        switch viewModel.islandState {
        case .expanded:
            return viewModel.expandedWidth
        case .band:
            return NotchLayout.bandWidth
        case .solo:
            // Playing or timing: the pill hero (cover + spectrum and/or timer
            // readout) has already taken over, so the capsule is pill-width —
            // no tab label to make room for.
            if hasAudioHero || pomodoro.pillText != nil {
                return viewModel.collapsedWidth(isPlaying: hasAudioHero, hasItems: !shelf.items.isEmpty, timerText: pomodoro.pillText)
            }
            // Otherwise hug the single surviving tab group (selected icon + label).
            return viewModel.soloWidth(for: viewModel.selectedTab)
        case .condensing:
            // Already the pill's width: the capsule narrows onto the selected
            // icon during this stage, so the final swap changes nothing.
            return viewModel.collapsedWidth(isPlaying: hasAudioHero, hasItems: !shelf.items.isEmpty, timerText: pomodoro.pillText)
        case .collapsed:
            if let activity = activities.current {
                return activity.kind == .audioRoute ? NotchLayout.activityRouteWidth : NotchLayout.activityWidth
            }
            return viewModel.collapsedWidth(isPlaying: hasAudioHero, hasItems: !shelf.items.isEmpty, timerText: pomodoro.pillText)
        }
    }
    private var islandHeight: CGFloat {
        viewModel.isExpanded ? viewModel.expandedHeight : viewModel.collapsedHeight
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            island
                // The island floats detached below the screen edge, iPhone-style.
                .padding(.top, NotchLayout.islandTopGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { syncSpectrum() }
        .onChange(of: nowPlaying.isPlaying) { _, playing in
            // When music starts, surface the music tab.
            if playing { viewModel.selectedTab = .music }
            syncSpectrum()
        }
        .onChange(of: nowPlaying.screensAwake) { _, _ in syncSpectrum() }
    }

    private var island: some View {
        let cornerRadius = viewModel.isExpanded ? NotchLayout.expandedCornerRadius : viewModel.collapsedHeight / 2
        let shape = IslandShape(cornerRadius: cornerRadius)
        // The dark silhouette leads; content is clipped to the same rounded rect
        // so it can't float outside the shape while it resizes. The highlight rim
        // and shadow stay outside the clip.
        //
        // The explicit `.frame` before the clip is load-bearing: mid-morph the
        // content lays out larger than the animated island, and `clipShape` clips
        // to the bounds of the view it's attached to. Without the frame those
        // bounds are the (full-size) content, so nothing gets clipped and the
        // content floats over the wallpaper without black behind it.
        return shape
            .fill(NotchLayout.islandFill)
            .overlay(
                content
                    .frame(width: islandWidth, height: islandHeight, alignment: .top)
                    .clipShape(shape)
            )
            .overlay(
                // Hairline rim, brightest along the top edge: separates the
                // near-black island from a dark menu bar / wallpaper.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(NotchLayout.islandStrokeTopOpacity),
                            .white.opacity(NotchLayout.islandStrokeBottomOpacity),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: NotchLayout.islandStrokeWidth
                )
            )
            .frame(width: islandWidth, height: islandHeight)
            // Settings toggles change the pill's width formula outside the
            // staged walk's withAnimation calls; morph instead of snapping.
            .animation(NotchLayout.islandMorphAnimation, value: settings.pillSpectrumOnly)
            .shadow(
                color: .black.opacity(viewModel.isExpanded ? NotchLayout.islandShadowOpacityExpanded : NotchLayout.islandShadowOpacityCollapsed),
                radius: NotchLayout.islandShadowRadius,
                y: NotchLayout.islandShadowYOffset
            )
    }

    @ViewBuilder private var content: some View {
        let state = viewModel.islandState
        // When music plays or a focus timer is active, the collapse morphs
        // toward the pill content (cover + live spectrum and/or timer readout)
        // rather than the selected tab's icon+label — uniformly, whichever tab
        // you close from. So from the `.solo` stage on the pill hero stands in
        // for the tab bar and just shrinks into place; this dissolves the
        // "close Capture while music runs" dilemma, because the collapse
        // target depends on the pill content, not on the tab.
        let heroContent = hasAudioHero || pomodoro.pillText != nil
        let pillHero = heroContent && (state == .solo || state == .condensing)
        let showsExpanded = state != .collapsed && !pillHero
        // Hero content → the tab bar and the pill hero are *different* content,
        // so cross-dissolve them. Otherwise the condensed icon and the pill
        // glyph are identical, so keep the hold-opaque handover (no dip).
        let handover: AnyTransition = heroContent ? .heroCrossfade : .iconHandover

        // Two explicit layers so the collapsed pill is *always* on top of the
        // outgoing tab bar during the handover.
        ZStack(alignment: .top) {
            if showsExpanded {
                // Expanded through condensing: the tab bar is one persistent
                // view that sheds its parts itself (pages, then unselected
                // tabs, then labels), so nothing ever re-appears. By the time
                // it unmounts only the selected icon is left — pixel-identical
                // to the pill icon replacing it (idle case).
                ExpandedView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, pomodoro: pomodoro, capture: capture, spectrum: spectrum, claudeUsage: claudeUsage, claudeDriver: claudeDriver)
                    .transition(handover)
            }
            if state == .collapsed || pillHero {
                if state == .collapsed, let activity = activities.current {
                    ActivityCompactView(activity: activity)
                        .foregroundStyle(.white)
                        .transition(.notchContent)
                } else {
                    // The pill hero: renders continuously across solo → condensing
                    // → collapsed when playing (one persistent view, so only the
                    // capsule shrinks around it — no swap), or just at collapsed
                    // when idle.
                    CollapsedView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, pomodoro: pomodoro, spectrum: spectrum, hasAudioHero: hasAudioHero)
                        .foregroundStyle(.white)
                        .transition(handover)
                }
            }
        }
    }
}

private extension AnyTransition {
    /// Content transition decoupled from the silhouette spring: content grows in
    /// (opacity + subtle scale, slightly delayed) and fades out fast on collapse,
    /// so it never lingers outside the shrinking shape.
    static var notchContent: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: NotchLayout.contentMorphScale, anchor: .top))
                .animation(NotchLayout.contentInsertAnimation),
            removal: .opacity.animation(NotchLayout.contentRemoveAnimation)
        )
    }

    /// The pill ⇄ condensed-icon handover, used by *both* layers so it works
    /// symmetrically in either direction: whichever view is arriving fades in,
    /// while the departing one *holds fully opaque* until the newcomer is all
    /// the way in, then cuts. One layer is always at full opacity, so there's
    /// no crossfade brightness dip (the "flicker") — and since the condensed
    /// icon and the pill icon are pixel-identical, the swap is invisible.
    static var iconHandover: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: NotchLayout.pillHandoverFade)),
            removal: .opacity.animation(.easeIn(duration: NotchLayout.pillHandoverRemoveFade).delay(NotchLayout.pillHandoverFade))
        )
    }

    /// Symmetric cross-dissolve used when music plays and the tab bar hands off
    /// to the now-playing pill hero (cover + spectrum) at the `.solo` stage.
    /// Both sides fade over the same clock so the tab bar melts into the hero as
    /// the capsule narrows — no overlap, since the two are different content.
    static var heroCrossfade: AnyTransition {
        .opacity.animation(.easeInOut(duration: NotchLayout.heroCrossfadeDuration))
    }
}

/// Compact rendering of a live activity inside the collapsed pill.
private struct ActivityCompactView: View {
    let activity: NotchActivity

    private var isRoute: Bool { activity.kind == .audioRoute }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: activity.icon)
                // The audio-route icon is bumped up so a connecting device reads
                // clearly at a glance (the main "markant" ask).
                .font(.system(size: isRoute ? 17 : 12, weight: .semibold))
                .foregroundStyle(activity.tint)
                .frame(width: isRoute ? 22 : 16)
            if let progress = activity.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 4)
            } else {
                Text(activity.title)
                    .font(.system(size: isRoute ? 12 : 11, weight: isRoute ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let detail = activity.detail {
                    BatteryBadge(text: detail)
                }
            }
        }
        .padding(.horizontal, isRoute ? 12 : 14)
        // Same fixed top band as CollapsedView, so activity content doesn't
        // drift vertically while the island morphs.
        .frame(height: NotchLayout.currentCollapsedHeight)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A small tinted battery pill (icon + percentage), tinted red/orange when low.
private struct BatteryBadge: View {
    let text: String

    private var level: Int? { Int(text.replacingOccurrences(of: "%", with: "")) }

    private var color: Color {
        switch level ?? 100 {
        case ..<15: return .red
        case ..<30: return .orange
        default: return .green
        }
    }

    private var symbol: String {
        switch level ?? 100 {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
    }
}

private struct ExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var shelf: FileShelfModel
    @ObservedObject var pomodoro: PomodoroManager
    @ObservedObject var capture: ObsidianCapture
    @ObservedObject var spectrum: SpectrumAnalyzer
    @ObservedObject var claudeUsage: ClaudeUsageModel
    @ObservedObject var claudeDriver: ClaudeSessionDriver

    private var pageIndex: Int {
        NotchViewModel.Tab.allCases.firstIndex(of: viewModel.selectedTab) ?? 0
    }

    /// False during the band collapse stage: the island has shrunk to just the
    /// tab-bar capsule, the pages are gone, only the bar remains (and must stay
    /// the *same view* as in the expanded state, or its icons would visibly
    /// re-appear instead of simply staying put).
    private var showsPages: Bool { viewModel.islandState == .expanded }

    var body: some View {
        VStack(spacing: showsPages ? NotchLayout.expandedRowSpacing : 0) {
            // The tab bar occupies exactly the collapsed pill's band (flush top,
            // same height), so its icons sit on the same y as the pill's glyph —
            // the hero flight between them is purely horizontal, not diagonal.
            NotchTabBar(
                selection: $viewModel.selectedTab,
                // .band/.expanded keep all three tabs; .solo/.condensing keep
                // only the selected one. Labels survive until .condensing, where
                // the text drops and just the icon remains.
                showsAllTabs: viewModel.islandState == .expanded || viewModel.islandState == .band,
                // Labels live only in expanded/band/solo. Must be false in
                // .collapsed too, not just .condensing: while the tab bar is
                // held opaque during the pill handover, `!= .condensing` would
                // flip true again and fade the label back in ("Mu" reappears).
                showsLabels: viewModel.islandState == .expanded
                    || viewModel.islandState == .band
                    || viewModel.islandState == .solo
            )
            .frame(maxWidth: .infinity)
            .frame(height: NotchLayout.currentCollapsedHeight)

            // All three pages live in a carousel that slides as one strip. Unlike
            // insertion/removal transitions this can't get the direction wrong on
            // quick back-and-forth swipes — the offset is a pure function of the
            // selected index.
            if showsPages {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        page(.music, in: geo.size) { NowPlayingView(nowPlaying: nowPlaying, spectrum: spectrum) }
                        page(.files, in: geo.size) { ShelfView(shelf: shelf) }
                        page(.capture, in: geo.size) { CaptureView(capture: capture, viewModel: viewModel) }
                        page(.timer, in: geo.size) { PomodoroView(pomodoro: pomodoro) }
                        page(.claude, in: geo.size) { ClaudeTabView(usage: claudeUsage, driver: claudeDriver, isFront: viewModel.selectedTab == .claude) }
                    }
                    .offset(x: -CGFloat(pageIndex) * geo.size.width)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .transition(.notchContent)
            }
        }
        // Inset the content (and the carousel clip in particular) from the
        // island edge so it clears the rounded corners; sliding pages must not
        // poke past the dark body onto the wallpaper.
        .padding(.horizontal, NotchLayout.expandedContentInset)
        .padding(.bottom, showsPages ? NotchLayout.expandedBottomPadding : 0)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func page<Content: View>(
        _ tab: NotchViewModel.Tab, in size: CGSize, @ViewBuilder content: () -> Content
    ) -> some View {
        let isFront = viewModel.selectedTab == tab
        content()
            .frame(width: size.width, height: size.height)
            .scaleEffect(isFront ? 1 : NotchLayout.tabPageInactiveScale)
            .opacity(isFront ? 1 : NotchLayout.tabPageInactiveOpacity)
            // Clipped-away pages are still hit-testable; don't let them swallow
            // clicks or file drops meant for the front page.
            .allowsHitTesting(isFront)
    }
}

private struct NotchTabBar: View {
    @Binding var selection: NotchViewModel.Tab
    /// When false (`.solo`/`.condensing`), only the selected tab is present —
    /// the others have left the layout, letting the capsule narrow onto it.
    let showsAllTabs: Bool
    /// When false (`.condensing`), the labels drop and only the icon remains.
    let showsLabels: Bool
    /// Observed so the bar re-renders live when tabs are toggled in Settings.
    @ObservedObject private var settings = UserSettings.shared

    var body: some View {
        HStack(spacing: NotchLayout.tabBarSpacing) {
            ForEach(NotchViewModel.enabledTabs, id: \.self) { value in
                tab(title: value.title, icon: value.icon, value: value)
            }
        }
    }

    @ViewBuilder
    private func tab(title: String, icon: String, value: NotchViewModel.Tab) -> some View {
        if showsAllTabs || selection == value {
            let isSelected = selection == value
            // Solo/condensing (this is the only tab): pin the *icon* at the
            // capsule centre — exactly where the pill icon will sit — so that
            // collapsing further only fades the label and shrinks the capsule;
            // the icon never moves again and the pill handover is pixel-exact.
            let soloMode = !showsAllTabs
            Button {
                guard selection != value else { return }
                Haptics.perform(.alignment)
                withAnimation(NotchLayout.tabChangeAnimation) { selection = value }
            } label: {
                HStack(spacing: NotchLayout.tabIconLabelSpacing) {
                    if soloMode {
                        // An invisible mirror of the real label, left of the
                        // icon: it reserves exactly the label's own width (real
                        // text metrics, no estimate), so the symmetric HStack
                        // centres the icon precisely. `.opacity(0)` (not
                        // `.hidden()`, which drops its layout space here) keeps
                        // the space through the label fade, so the icon holds
                        // dead centre — no wander, no flicker at the handover.
                        Text(title).fixedSize().opacity(0)
                    }
                    // Every icon renders itself, always — switching tabs must only
                    // change the highlight (foreground opacity), never replace or
                    // move the icon view, or it visibly pops back in.
                    Image(systemName: icon)
                    // The label stays in the layout even when hidden (fixed size,
                    // opacity only) so the mirror stays balanced; it just fades
                    // fast while the capsule narrows over it.
                    Text(title)
                        .fixedSize()
                        .opacity(showsLabels ? 1 : 0)
                        .animation(NotchLayout.condenseFadeAnimation, value: showsLabels)
                }
                .font(.system(size: NotchLayout.bandFontSize, weight: .medium))
                .padding(.vertical, NotchLayout.tabItemPaddingVertical)
                .padding(.horizontal, NotchLayout.tabItemPaddingHorizontal)
                .foregroundStyle(.white.opacity(isSelected ? 1 : NotchLayout.tabInactiveOpacity))
            }
            .buttonStyle(.plain)
            .transition(.opacity.animation(NotchLayout.condenseFadeAnimation))
        }
    }
}

private struct CollapsedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var shelf: FileShelfModel
    @ObservedObject var pomodoro: PomodoroManager
    @ObservedObject var spectrum: SpectrumAnalyzer
    @ObservedObject private var settings = UserSettings.shared
    /// Whether the pill hero (cover-or-generic-icon + wave) should show at all —
    /// true for Spotify/Music, but also for any other system audio (browser
    /// video, calls, …) that has no scriptable track to show a cover for.
    let hasAudioHero: Bool

    /// Cached icon for `spectrum.sourceBundleID`, resolved once per bundle ID
    /// change rather than on every wave-bar redraw.
    @State private var sourceAppIcon: NSImage?
    @State private var sourceAppIconBundleID: String?
    /// Accent derived from `sourceAppIcon`, the same way a track's cover tints
    /// its wave — so generic system audio (Safari, …) doesn't fall back to a
    /// flat white wave next to a colourful app icon.
    @State private var sourceAppTint: Color?

    /// Idle glyph reflects the tab you'd return to, so it isn't always the music
    /// note when you last used another tab.
    private var idleIcon: String { viewModel.selectedTab.icon }

    /// The accent to tint the wave with: the real track's accent when we're
    /// actually showing that track's cover, else the source app icon's accent
    /// (Safari's blue, …) for generic system audio, else `nil` (→ white) when
    /// neither is available.
    private var waveTint: Color? {
        if showsTrackArtwork { return nowPlaying.artworkColor }
        return sourceAppTint
    }

    /// Whether the hero shows the current track's cover rather than the audio
    /// source app's icon.
    ///
    /// Not simply `isPlaying`: pausing drops that flag at once while
    /// `spectrum.hasSignal` holds the pill open for another couple of seconds,
    /// and swapping the cover out for the player's own app icon in that window
    /// showed Spotify's logo beside flat bars for no reason. So a paused track
    /// keeps its cover — unless some *other* app is the one making noise
    /// (Safari playing a video while Spotify sits paused), which is exactly the
    /// case the app-icon branch exists for.
    private var showsTrackArtwork: Bool {
        guard nowPlaying.track?.artworkURL != nil else { return false }
        if nowPlaying.isPlaying { return true }
        guard let sourceBundleID = spectrum.sourceBundleID else { return true }
        return sourceBundleID == nowPlaying.activeSourceID.bundleID
    }

    private func refreshSourceAppIcon(for bundleID: String?) {
        guard bundleID != sourceAppIconBundleID else { return }
        sourceAppIconBundleID = bundleID
        sourceAppTint = nil
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            sourceAppIcon = nil
            return
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        sourceAppIcon = icon
        ArtworkColor.fetch(from: icon, cacheKey: bundleID) { color in
            guard bundleID == sourceAppIconBundleID else { return }
            sourceAppTint = color
        }
    }

    var body: some View {
        // Spacings/paddings here must stay in lock-step with the width estimate
        // in `NotchViewModel.collapsedWidth`, or the pill clips against the
        // silhouette — so both sides read from the same `NotchLayout` constants.
        HStack(spacing: NotchLayout.collapsedItemSpacing) {
            if hasAudioHero {
                if settings.pillSpectrumOnly {
                    // Spectrum-only mode: no thumbnail at all (neither cover
                    // nor source-app icon — "only the spectrum" holds for both
                    // kinds of audio), just a wider, taller wave across the
                    // space the thumbnail freed up.
                    WaveBarsView(
                        isActive: nowPlaying.screensAwake,
                        tint: waveTint,
                        secondaryTint: showsTrackArtwork ? nowPlaying.artworkSecondaryColor : nil,
                        tertiaryTint: showsTrackArtwork ? nowPlaying.artworkTertiaryColor : nil,
                        coverBars: showsTrackArtwork ? nowPlaying.coverBars : nil,
                        bands: spectrum.isLive ? spectrum.bands : nil,
                        count: NotchLayout.collapsedWideWaveBarCount,
                        maxHeight: NotchLayout.collapsedWideWaveMaxHeight,
                        barWidth: NotchLayout.collapsedWaveBarWidth,
                        spacing: NotchLayout.collapsedWaveSpacing
                    )
                    .frame(width: NotchLayout.collapsedWideWavesWidth, height: NotchLayout.collapsedWideWaveFrameHeight)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else if showsTrackArtwork, let url = nowPlaying.track?.artworkURL {
                    // Fade the new cover in (transaction animation) over a placeholder
                    // tinted to the track's accent colour rather than flat grey, so a
                    // track change doesn't flash a grey square then pop during the
                    // hero crossfade.
                    AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            nowPlaying.artworkColor ?? Color.white.opacity(0.1)
                        }
                    }
                    .frame(width: NotchLayout.collapsedArtworkWidth, height: NotchLayout.collapsedArtworkWidth)
                    .clipShape(RoundedRectangle(cornerRadius: NotchLayout.collapsedArtworkCornerRadius))
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                } else {
                    // System audio with no scriptable track (browser video, a
                    // call, …) — show the source app's own icon full-bleed when
                    // we can identify it (no background/padding: app icons like
                    // Safari's already bake in their own rounding and margin, so
                    // wrapping them in another rounded-rect frame just shrank
                    // them further and read as an extra border), else fall back
                    // to a plain glyph on a tinted background.
                    Group {
                        if let sourceAppIcon {
                            Image(nsImage: sourceAppIcon).resizable().scaledToFit()
                        } else {
                            RoundedRectangle(cornerRadius: NotchLayout.collapsedArtworkCornerRadius)
                                .fill(Color.white.opacity(0.1))
                                .overlay {
                                    Image(systemName: "waveform").font(.system(size: 11))
                                }
                        }
                    }
                    .frame(width: NotchLayout.collapsedArtworkWidth, height: NotchLayout.collapsedArtworkWidth)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                if !settings.pillSpectrumOnly {
                    WaveBarsView(
                        isActive: nowPlaying.screensAwake,
                        tint: waveTint,
                        secondaryTint: showsTrackArtwork ? nowPlaying.artworkSecondaryColor : nil,
                        tertiaryTint: showsTrackArtwork ? nowPlaying.artworkTertiaryColor : nil,
                        coverBars: showsTrackArtwork ? nowPlaying.coverBars : nil,
                        bands: spectrum.isLive ? spectrum.bands : nil,
                        count: NotchLayout.collapsedWaveBarCount,
                        maxHeight: NotchLayout.collapsedWaveMaxHeight,
                        barWidth: NotchLayout.collapsedWaveBarWidth,
                        spacing: NotchLayout.collapsedWaveSpacing
                    )
                    .frame(width: NotchLayout.collapsedWavesWidth, height: NotchLayout.collapsedArtworkWidth)
                    .transition(.opacity)
                }
            } else if pomodoro.pillText == nil {
                Image(systemName: idleIcon)
                    .font(.system(size: NotchLayout.bandFontSize, weight: .medium))
            }

            // The focus-timer readout joins to the right of the artwork + wave
            // while music plays and stands alone otherwise (it replaces the
            // idle glyph above rather than crowding it).
            if let readout = pomodoro.pillText {
                timerSegment(readout)
            }

            if !shelf.items.isEmpty {
                Label("\(shelf.items.count)", systemImage: "tray.full.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: NotchLayout.collapsedBadgeFontSize, weight: .semibold))
            }
        }
        .padding(.horizontal, NotchLayout.collapsedContentPadding)
        // Pin the pill row to a fixed top band. Without this the row is
        // vertically centered in the *animated* island frame during the morph,
        // so the glyph starts mid-island and drifts up — the diagonal flight.
        .frame(height: viewModel.collapsedHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        // The spectrum-only toggle swaps the hero's layout in place; a scoped
        // value animation can't interfere with the staged expand/collapse
        // walk's explicit withAnimation calls.
        .animation(NotchLayout.islandMorphAnimation, value: settings.pillSpectrumOnly)
        // Resolved at the pill level (not inside the thumbnail branch) so the
        // source-app tint keeps refreshing in spectrum-only mode, where no
        // icon is on screen but the wave still wants the app's accent.
        .onAppear { refreshSourceAppIcon(for: spectrum.sourceBundleID) }
        .onChange(of: spectrum.sourceBundleID) { _, bundleID in refreshSourceAppIcon(for: bundleID) }
    }

    /// The passive focus-timer readout. Sizes must stay in lock-step with the
    /// width estimate in `NotchViewModel.timerSegmentWidth`.
    private func timerSegment(_ readout: String) -> some View {
        let paused = pomodoro.phase == .paused
        return HStack(spacing: NotchLayout.collapsedTimerInnerSpacing) {
            Image(systemName: paused ? "pause.fill" : "timer")
                .font(.system(size: NotchLayout.collapsedTimerIconSize, weight: .semibold))
                .foregroundStyle(paused ? Color.white.opacity(0.55) : Color.orange)
                .frame(width: NotchLayout.collapsedTimerIconWidth)
            Text(readout)
                .font(.system(size: NotchLayout.collapsedTimerFontSize, weight: .semibold))
                .monospacedDigit()
                .opacity(paused ? 0.55 : 1)
        }
    }
}
