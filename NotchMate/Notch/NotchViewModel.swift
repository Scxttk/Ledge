import SwiftUI

final class NotchViewModel: ObservableObject {
    enum Tab: CaseIterable {
        case music
        case files
        case capture
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
    /// glyph) and the shelf badge, plus the end padding that keeps content
    /// clear of the capsule's corner curve — otherwise the clip swallows edges.
    func collapsedWidth(isPlaying: Bool, hasItems: Bool) -> CGFloat {
        var core = isPlaying
            ? NotchLayout.collapsedArtworkWidth + NotchLayout.collapsedItemSpacing + NotchLayout.collapsedWavesWidth
            : NotchLayout.collapsedGlyphWidth
        if hasItems {
            core += NotchLayout.collapsedItemSpacing + NotchLayout.collapsedBadgeWidth
        }
        return core + 2 * (NotchLayout.collapsedContentPadding + NotchLayout.collapsedEndPadding)
    }

    /// Width of the intermediate `.solo` capsule, hugging the single selected
    /// tab group (icon + its label) so it doesn't sit loose. The label width
    /// is estimated from the localized title; slight looseness is harmless,
    /// clipping is not, so the estimate errs generous.
    func soloWidth(for tab: Tab) -> CGFloat {
        let title: String
        switch tab {
        case .music:   title = String(localized: "tab.music", defaultValue: "Musik")
        case .files:   title = String(localized: "tab.files", defaultValue: "Ablage")
        case .capture: title = String(localized: "tab.capture", defaultValue: "Capture")
        }
        let labelWidth = CGFloat(title.count) * NotchLayout.soloLabelCharWidth
        return NotchLayout.soloBaseWidth + labelWidth
    }

    // The panel keeps a constant size; only the SwiftUI island animates.
    // Extra margin leaves room for the island's shadow.
    var panelWidth: CGFloat { expandedWidth + NotchLayout.panelHorizontalMargin }
    var panelHeight: CGFloat { expandedHeight + NotchLayout.panelVerticalMargin }
}
