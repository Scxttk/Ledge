import SwiftUI
import AppKit

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var shelf: FileShelfModel
    @ObservedObject var activities: ActivityManager
    @ObservedObject var capture: ObsidianCapture
    @ObservedObject var spectrum: SpectrumAnalyzer

    /// Run the audio tap whenever music is playing and the screen is on — the
    /// wave is then live in both the expanded music tab and the collapsed pill.
    /// Gated on `screensAwake` so it isn't tapping/FFT-ing to a dark display.
    private func syncSpectrum() {
        if nowPlaying.isPlaying && nowPlaying.screensAwake {
            spectrum.start()
        } else {
            spectrum.stop()
        }
    }

    private var islandWidth: CGFloat {
        switch viewModel.islandState {
        case .expanded:
            return viewModel.expandedWidth
        case .band:
            return NotchLayout.bandWidth
        case .solo:
            // Playing: the pill hero (cover + spectrum) has already taken over,
            // so the capsule is pill-width — no tab label to make room for.
            if nowPlaying.isPlaying {
                return viewModel.collapsedWidth(isPlaying: true, hasItems: !shelf.items.isEmpty)
            }
            // Otherwise hug the single surviving tab group (selected icon + label).
            return viewModel.soloWidth(for: viewModel.selectedTab)
        case .condensing:
            // Already the pill's width: the capsule narrows onto the selected
            // icon during this stage, so the final swap changes nothing.
            return viewModel.collapsedWidth(isPlaying: nowPlaying.isPlaying, hasItems: !shelf.items.isEmpty)
        case .collapsed:
            if let activity = activities.current {
                return activity.kind == .audioRoute ? NotchLayout.activityRouteWidth : NotchLayout.activityWidth
            }
            return viewModel.collapsedWidth(isPlaying: nowPlaying.isPlaying, hasItems: !shelf.items.isEmpty)
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
        let cornerRadius = viewModel.isExpanded ? NotchLayout.expandedCornerRadius : NotchLayout.collapsedCornerRadius
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
            .shadow(
                color: .black.opacity(viewModel.isExpanded ? NotchLayout.islandShadowOpacityExpanded : NotchLayout.islandShadowOpacityCollapsed),
                radius: NotchLayout.islandShadowRadius,
                y: NotchLayout.islandShadowYOffset
            )
    }

    @ViewBuilder private var content: some View {
        let state = viewModel.islandState
        // When music plays, the collapse morphs toward the now-playing pill
        // (cover + live spectrum) rather than the selected tab's icon+label —
        // uniformly, whichever tab you close from. So from the `.solo` stage on
        // the pill hero stands in for the tab bar and just shrinks into place;
        // this dissolves the "close Capture while music runs" dilemma, because
        // the collapse target depends on playback, not on the tab.
        let pillHero = nowPlaying.isPlaying && (state == .solo || state == .condensing)
        let showsExpanded = state != .collapsed && !pillHero
        // Playing → the tab bar and the pill hero are *different* content, so
        // cross-dissolve them. Not playing → the condensed icon and the pill
        // glyph are identical, so keep the hold-opaque handover (no dip).
        let handover: AnyTransition = nowPlaying.isPlaying ? .heroCrossfade : .iconHandover

        // Two explicit layers so the collapsed pill is *always* on top of the
        // outgoing tab bar during the handover.
        ZStack(alignment: .top) {
            if showsExpanded {
                // Expanded through condensing: the tab bar is one persistent
                // view that sheds its parts itself (pages, then unselected
                // tabs, then labels), so nothing ever re-appears. By the time
                // it unmounts only the selected icon is left — pixel-identical
                // to the pill icon replacing it (idle case).
                ExpandedView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, capture: capture, spectrum: spectrum)
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
                    CollapsedView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, spectrum: spectrum)
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
            removal: .opacity.animation(.easeIn(duration: 0.12).delay(NotchLayout.pillHandoverFade))
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
        .frame(height: NotchLayout.collapsedHeight)
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
    @ObservedObject var capture: ObsidianCapture
    @ObservedObject var spectrum: SpectrumAnalyzer

    private var pageIndex: Int {
        NotchViewModel.Tab.allCases.firstIndex(of: viewModel.selectedTab) ?? 0
    }

    /// False during the band collapse stage: the island has shrunk to just the
    /// tab-bar capsule, the pages are gone, only the bar remains (and must stay
    /// the *same view* as in the expanded state, or its icons would visibly
    /// re-appear instead of simply staying put).
    private var showsPages: Bool { viewModel.islandState == .expanded }

    var body: some View {
        VStack(spacing: showsPages ? 8 : 0) {
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
            .frame(height: NotchLayout.collapsedHeight)

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
        .padding(.bottom, showsPages ? 20 : 0)
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

    var body: some View {
        HStack(spacing: 6) {
            tab(title: String(localized: "tab.music", defaultValue: "Musik"), icon: "music.note", value: .music)
            tab(title: String(localized: "tab.files", defaultValue: "Ablage"), icon: "tray.full", value: .files)
            tab(title: String(localized: "tab.capture", defaultValue: "Capture"), icon: "square.and.pencil", value: .capture)
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
                .padding(.vertical, 3)
                .padding(.horizontal, 10)
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.55))
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
    @ObservedObject var spectrum: SpectrumAnalyzer

    /// Idle glyph reflects the tab you'd return to, so it isn't always the music
    /// note when you last used another tab.
    private var idleIcon: String {
        switch viewModel.selectedTab {
        case .music: return "music.note"
        case .files: return "tray.full"
        case .capture: return "square.and.pencil"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if nowPlaying.isPlaying, let url = nowPlaying.track?.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.1)
                }
                .frame(width: NotchLayout.collapsedArtworkWidth, height: NotchLayout.collapsedArtworkWidth)
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
                WaveBarsView(
                    isActive: nowPlaying.screensAwake,
                    tint: nowPlaying.artworkColor,
                    bands: spectrum.isLive ? spectrum.bands : nil,
                    count: 3,
                    maxHeight: 12,
                    barWidth: 2.5,
                    spacing: 2
                )
                .frame(width: 14, height: 14)
            } else {
                Image(systemName: idleIcon)
                    .font(.system(size: NotchLayout.bandFontSize, weight: .medium))
            }

            if !shelf.items.isEmpty {
                Label("\(shelf.items.count)", systemImage: "tray.full.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .padding(.horizontal, 10)
        // Pin the pill row to a fixed top band. Without this the row is
        // vertically centered in the *animated* island frame during the morph,
        // so the glyph starts mid-island and drifts up — the diagonal flight.
        .frame(height: NotchLayout.collapsedHeight)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
