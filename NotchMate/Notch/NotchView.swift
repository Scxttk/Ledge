import SwiftUI
import AppKit

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var shelf: FileShelfModel
    @ObservedObject var activities: ActivityManager
    @ObservedObject var capture: ObsidianCapture

    private var islandWidth: CGFloat {
        switch viewModel.islandState {
        case .expanded:
            return viewModel.expandedWidth
        case .band:
            return NotchLayout.bandWidth
        case .solo:
            // Hugs the single surviving tab group (selected icon + its label).
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
        .onChange(of: nowPlaying.isPlaying) { _, playing in
            // When music starts, surface the music tab.
            if playing { viewModel.selectedTab = .music }
        }
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
        // Two explicit layers so the collapsed pill is *always* on top of the
        // outgoing tab bar during the handover: the pill fades in over the
        // still-opaque condensed icon, which only cuts once the pill is fully
        // there — no crossfade brightness dip (the "flicker").
        ZStack(alignment: .top) {
            if viewModel.islandState != .collapsed {
                // Expanded through condensing: the tab bar is one persistent
                // view that sheds its parts itself (pages, then unselected
                // tabs, then labels), so nothing ever re-appears. By the time
                // it unmounts only the selected icon is left — pixel-identical
                // to the pill icon replacing it.
                ExpandedView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, capture: capture)
                    .transition(.iconHandover)
            }
            if viewModel.islandState == .collapsed {
                if let activity = activities.current {
                    ActivityCompactView(activity: activity)
                        .foregroundStyle(.white)
                        .transition(.notchContent)
                } else {
                    CollapsedView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf)
                        .foregroundStyle(.white)
                        .transition(.iconHandover)
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
                showsLabels: viewModel.islandState != .condensing
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
                        page(.music, in: geo.size) { NowPlayingView(nowPlaying: nowPlaying) }
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
            Button {
                guard selection != value else { return }
                Haptics.perform(.alignment)
                withAnimation(NotchLayout.tabChangeAnimation) { selection = value }
            } label: {
                HStack(spacing: 4) {
                    // Every icon renders itself, always — switching tabs must only
                    // change the highlight (foreground opacity), never replace or
                    // move the icon view, or it visibly pops back in.
                    Image(systemName: icon)
                    if showsLabels {
                        // Fades fast (see condenseFadeAnimation); the layout
                        // space it frees still collapses with the ambient
                        // spring, sliding the icon toward the centre.
                        Text(title)
                            .transition(.opacity.animation(NotchLayout.condenseFadeAnimation))
                    }
                }
                .font(.system(size: NotchLayout.bandFontSize, weight: .medium))
                .padding(.vertical, 3)
                .padding(.horizontal, 10)
                .foregroundStyle(.white.opacity(selection == value ? 1 : 0.55))
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
                WaveBarsView(isActive: nowPlaying.screensAwake, count: 3, maxHeight: 12, barWidth: 2.5, spacing: 2)
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
