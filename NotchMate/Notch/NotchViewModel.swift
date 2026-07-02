import SwiftUI

final class NotchViewModel: ObservableObject {
    enum Tab: CaseIterable {
        case music
        case files
        case capture
    }

    @Published var isExpanded: Bool = false
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
    /// Depends on both playback (artwork + visualizer are wider than the idle
    /// glyph) and the shelf badge, plus the flare inset the notch silhouette
    /// carves out of each side — otherwise the shape clip swallows the edges.
    func collapsedWidth(isPlaying: Bool, hasItems: Bool) -> CGFloat {
        var core = isPlaying
            ? NotchLayout.collapsedArtworkWidth + NotchLayout.collapsedItemSpacing + NotchLayout.collapsedWavesWidth
            : NotchLayout.collapsedGlyphWidth
        if hasItems {
            core += NotchLayout.collapsedItemSpacing + NotchLayout.collapsedBadgeWidth
        }
        return core + 2 * (NotchLayout.collapsedContentPadding + NotchLayout.collapsedFlareInset)
    }

    // The panel keeps a constant size; only the SwiftUI island animates.
    // Extra margin leaves room for the island's shadow.
    var panelWidth: CGFloat { expandedWidth + NotchLayout.panelHorizontalMargin }
    var panelHeight: CGFloat { expandedHeight + NotchLayout.panelVerticalMargin }
}
