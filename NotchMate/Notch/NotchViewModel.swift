import SwiftUI

final class NotchViewModel: ObservableObject {
    enum Tab: CaseIterable {
        case music
        case files
        case capture
        case timer
    }

    /// The island's visual state. Collapsing is staged (iPhone-style):
    /// - `.band`  — capsule holding all three tab groups (icon + label).
    /// - `.solo`  — only the selected tab group remains (icon + label), the
    ///   others having faded out as the capsule narrows onto it.
    /// - `.condensing` — the label drops too; just the selected icon is left,
    ///   the capsule now exactly pill-width and -positioned.
    /// - `.collapsed` — the real pill content swaps in, pixel-identical to the
    ///   condensed icon, so the handover is invisible.
    /// The controller orchestrates the steps; only `.expanded` and `.collapsed`
    /// are resting states, the rest are transient stops on the way down.
    enum IslandState {
        case expanded
        case band
        case solo
        case condensing
        case collapsed
    }

    @Published var islandState: IslandState = .collapsed

    /// The logical open/closed state — `.band` counts as closed (it's a
    /// transient stop on the way down; hover/gesture logic treats it like the
    /// pill so a re-hover immediately re-expands).
    var isExpanded: Bool { islandState == .expanded }

    /// True whenever the island is *not* fully collapsed — i.e. at `.expanded`
    /// or anywhere along the staged collapse/expand walk (`.band`/`.solo`/
    /// `.condensing`). The click hit-test rect keys off this so it stays at the
    /// large footprint while the silhouette is still visibly springing down,
    /// instead of snapping to the tiny pill the instant the logical state
    /// flips. Without it the collapsing island can't be caught and clicks fall
    /// through mid-walk. Hover uses the stricter `isExpanded` instead (see
    /// `NotchWindowController.evaluateHover`) — a cursor sitting in the
    /// leftover space of a collapsing/expanding notch shouldn't reopen it,
    /// only actually hovering the pill should.
    var occupiesExpandedFootprint: Bool { islandState != .collapsed }

    @Published var selectedTab: Tab = .music

    /// While true (e.g. the capture field is focused) the island won't auto-
    /// collapse when the cursor leaves it — otherwise typing would dismiss it.
    @Published var isInteractionLocked: Bool = false

    /// Bumped to ask the capture field to take focus (e.g. via the global hotkey).
    @Published var captureFocusToken: Int = 0

    func requestCaptureFocus() {
        selectedTab = .capture
        captureFocusToken += 1
    }

    // Visible island dimensions (sourced from NotchLayout).
    var collapsedHeight: CGFloat { NotchLayout.collapsedHeight }
    var expandedWidth: CGFloat { NotchLayout.expandedWidth }
    var expandedHeight: CGFloat { NotchLayout.expandedHeight }

    /// Collapsed pill width, computed to hug whatever the pill actually shows.
    /// Depends on playback (artwork + visualizer are wider than the idle
    /// glyph), the focus-timer readout (replaces the glyph when idle, joins to
    /// the right of the visualizer when playing) and the shelf badge, plus the
    /// end padding that keeps content clear of the capsule's corner curve —
    /// otherwise the clip swallows edges.
    func collapsedWidth(isPlaying: Bool, hasItems: Bool, timerText: String?) -> CGFloat {
        var core: CGFloat
        if isPlaying {
            core = NotchLayout.collapsedArtworkWidth + NotchLayout.collapsedItemSpacing + NotchLayout.collapsedWavesWidth
            if let timerText {
                core += NotchLayout.collapsedItemSpacing + Self.timerSegmentWidth(timerText)
            }
        } else if let timerText {
            core = Self.timerSegmentWidth(timerText)
        } else {
            core = NotchLayout.collapsedGlyphWidth
        }
        if hasItems {
            core += NotchLayout.collapsedItemSpacing + NotchLayout.collapsedBadgeWidth
        }
        return core + 2 * (NotchLayout.collapsedContentPadding + NotchLayout.collapsedEndPadding)
    }

    /// Estimated width of the pill's timer segment (icon + readout). Must stay
    /// in lock-step with the segment layout in `CollapsedView`.
    private static func timerSegmentWidth(_ text: String) -> CGFloat {
        NotchLayout.collapsedTimerIconWidth + NotchLayout.collapsedTimerInnerSpacing
            + CGFloat(text.count) * NotchLayout.collapsedTimerCharWidth
    }

    /// Width of the intermediate `.solo` capsule. The icon is pinned at the
    /// capsule *centre* (its final pill position) with the label trailing to
    /// the right, so collapsing on further only fades the label and shrinks the
    /// capsule — the icon never moves. Keeping the icon centred means the label
    /// width is mirrored as empty space on the left, hence the label counts
    /// twice. The estimate errs generous; slight looseness is harmless,
    /// clipping is not.
    func soloWidth(for tab: Tab) -> CGFloat {
        let title: String
        switch tab {
        case .music:   title = String(localized: "tab.music", defaultValue: "Musik")
        case .files:   title = String(localized: "tab.files", defaultValue: "Ablage")
        case .capture: title = String(localized: "tab.capture", defaultValue: "Capture")
        case .timer:   title = String(localized: "tab.timer", defaultValue: "Timer")
        }
        let labelWidth = CGFloat(title.count) * NotchLayout.soloLabelCharWidth
        return NotchLayout.soloBaseWidth + 2 * labelWidth
    }

    // The panel keeps a constant size; only the SwiftUI island animates.
    // Extra margin leaves room for the island's shadow.
    var panelWidth: CGFloat { expandedWidth + NotchLayout.panelHorizontalMargin }
    var panelHeight: CGFloat { expandedHeight + NotchLayout.panelVerticalMargin }
}
