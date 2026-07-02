import SwiftUI

/// Central source of truth for the island's geometry, animation and timing
/// constants. Previously these were scattered as magic numbers across
/// `NotchViewModel`, `NotchWindowController`, `NotchShape` and the views.
/// Keeping them in one place makes the island tunable and is the foundation
/// for user-configurable appearance.
enum NotchLayout {

    // MARK: Visible island dimensions

    /// Height of the collapsed pill.
    static let collapsedHeight: CGFloat = 26

    // MARK: Collapsed content metrics
    // The collapsed pill hugs whatever it shows, so its width is computed from
    // these element widths (see `NotchViewModel.collapsedWidth`). They must match
    // the `CollapsedView` layout. Getting this wrong shows up as clipped content,
    // because the island is clipped to the notch silhouette.

    /// The lone `music.note` glyph shown when nothing is playing.
    static let collapsedGlyphWidth: CGFloat = 12
    /// Now-playing artwork thumbnail.
    static let collapsedArtworkWidth: CGFloat = 16
    /// The little frequency (wave-bars) visualizer next to the artwork.
    static let collapsedWavesWidth: CGFloat = 14
    /// The shelf badge (tray icon + item count, up to ~2 digits).
    static let collapsedBadgeWidth: CGFloat = 30
    /// Spacing between the collapsed HStack items.
    static let collapsedItemSpacing: CGFloat = 6
    /// Horizontal breathing room inside the pill (matches `CollapsedView`).
    static let collapsedContentPadding: CGFloat = 10
    /// Horizontal inset each concave top flare carves out of the pill's side. The
    /// straight-sided black body is only `width − 2·flare` wide, so content must
    /// clear this on both sides or the silhouette clip swallows its edges.
    static var collapsedFlareInset: CGFloat { notchTopRadiusCollapsed * notchTopWidthFactor }

    static let expandedWidth: CGFloat = 460
    static let expandedHeight: CGFloat = 212

    /// Width of the collapsed pill while a live activity is showing.
    static let activityWidth: CGFloat = 220
    /// Wider pill for the audio-route activity (bigger icon + device name + battery)
    /// so a connecting device reads clearly.
    static let activityRouteWidth: CGFloat = 264

    // MARK: Notch silhouette

    /// How much wider than deep the concave top scoops are (larger = longer,
    /// more pronounced flares that read as "glued" to the screen edge).
    static let notchTopWidthFactor: CGFloat = 2.2
    static let notchTopRadiusCollapsed: CGFloat = 11
    static let notchTopRadiusExpanded: CGFloat = 24
    static let notchBottomRadiusCollapsed: CGFloat = 14
    static let notchBottomRadiusExpanded: CGFloat = 22

    // MARK: Panel margins

    /// The fixed panel is larger than the visible island so the SwiftUI
    /// island's shadow has room to render. Only the island animates inside.
    static let panelHorizontalMargin: CGFloat = 60
    static let panelVerticalMargin: CGFloat = 24

    // MARK: Hover detection

    /// Extra tolerance around the visible collapsed pill before hover counts
    /// as "on the notch". Kept tiny so it only triggers over the pill.
    static let collapsedHoverInset: CGFloat = 4
    /// Bleed the hover rect above the physical top edge: the cursor's y at the
    /// very top equals `screen.frame.maxY`, and `NSRect.contains` treats the top
    /// edge as exclusive (`y < maxY`). Without this the notch refuses to open at
    /// the screen edge.
    static let hoverTopBleed: CGFloat = 8
    /// Extra width/height added to the hit-test rect used by `NotchContainerView`.
    static let hitTestWidthPadding: CGFloat = 8
    static let hitTestHeightPadding: CGFloat = 6

    // MARK: Timing & animation

    /// Delay before collapsing after a drag exits, so brief exits don't flicker.
    static let collapseDelay: TimeInterval = 0.12
    /// Minimum vertical scroll magnitude to treat a swipe as a gesture.
    static let gestureScrollThreshold: CGFloat = 6
    /// A horizontal swipe only pages tabs once per gesture: a new gesture is
    /// recognized when this long has passed since the last horizontal scroll event
    /// (so trackpad momentum within one swipe doesn't flip through several tabs).
    static let tabSwipeGestureGap: TimeInterval = 0.25

    /// Spring driving the black silhouette (frame + corner radii) as it morphs
    /// between collapsed/expanded. Slightly higher damping than a classic bouncy
    /// spring so the settling tail is short — the content fade must not lag behind
    /// a long-settling silhouette (that caused the old "floating content" glitch).
    static let islandMorphAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.86)

    /// Content fade-in on expand: slightly delayed so it appears once the
    /// silhouette has grown enough room, then a quick easeOut.
    static let contentInsertAnimation: Animation = .easeOut(duration: 0.20).delay(0.06)
    /// Content fade-out on collapse: fast easeIn so the content is gone *before*
    /// the silhouette finishes shrinking (nothing lingers outside the shape).
    static let contentRemoveAnimation: Animation = .easeIn(duration: 0.10)
    /// Starting scale of inserted content — a subtle "grow out of the pill" morph.
    static let contentMorphScale: CGFloat = 0.96

    /// Switching tabs (tap button and horizontal swipe both use it) — drives the
    /// crossfade between tab pages (see `ExpandedView.pageTransition`).
    static let tabChangeAnimation: Animation = .easeInOut(duration: 0.26)

    /// How long CaptureView waits before mounting its AppKit-backed text field.
    /// NSTextField ignores SwiftUI clip shapes, so the real field must not exist
    /// while the island morph (spring response 0.42) or a tab slide (0.26) is
    /// still moving — a SwiftUI placeholder stands in until then.
    static let captureFieldMountDelay: TimeInterval = 0.30
}
