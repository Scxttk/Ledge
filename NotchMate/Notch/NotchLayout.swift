import SwiftUI

/// Central source of truth for the island's geometry, animation and timing
/// constants. Previously these were scattered as magic numbers across
/// `NotchViewModel`, `NotchWindowController`, `NotchShape` and the views.
/// Keeping them in one place makes the island tunable and is the foundation
/// for user-configurable appearance.
enum NotchLayout {

    // MARK: Visible island dimensions

    /// Height of the collapsed pill — matches the macOS menu bar (24pt), so the
    /// pill reads as part of the bar. The expanded tab bar reuses this band
    /// (flush top, same height) so glyphs share the same y in both states.
    static let collapsedHeight: CGFloat = 24

    /// Text/glyph size in the pill band and the tab bar — menu-bar-sized (13pt)
    /// and identical in the collapsed and expanded state, so the hero glyph
    /// neither rescales nor shifts between them.
    static let bandFontSize: CGFloat = 13

    // MARK: Collapsed content metrics
    // The collapsed pill hugs whatever it shows, so its width is computed from
    // these element widths (see `NotchViewModel.collapsedWidth`). They must match
    // the `CollapsedView` layout. Getting this wrong shows up as clipped content,
    // because the island is clipped to the notch silhouette.

    /// The lone `music.note` glyph shown when nothing is playing.
    static let collapsedGlyphWidth: CGFloat = 14
    /// Now-playing artwork thumbnail. Sized so it keeps ~5pt of black above it
    /// in the 24pt pill — at 16pt it sat visually pressed against (Scott:
    /// "abgeschnitten von") the top screen edge.
    static let collapsedArtworkWidth: CGFloat = 14
    /// The little frequency (wave-bars) visualizer next to the artwork.
    static let collapsedWavesWidth: CGFloat = 14
    /// The shelf badge (tray icon + item count, up to ~2 digits).
    static let collapsedBadgeWidth: CGFloat = 30
    /// Spacing between the collapsed HStack items.
    static let collapsedItemSpacing: CGFloat = 6
    /// Horizontal breathing room inside the pill (matches `CollapsedView`).
    static let collapsedContentPadding: CGFloat = 10
    /// Extra padding at each rounded end of the collapsed capsule. Kept small:
    /// the content is only ~13pt tall and vertically centered, so the corner
    /// curve barely intrudes at its edges — a tight pill reads more iPhone-like
    /// than a wide one (Scott: idle pill with one icon was too wide).
    static let collapsedEndPadding: CGFloat = 4
    /// Horizontal inset of the expanded content (and the tab-page carousel clip
    /// in particular) from the island edge, clearing the rounded corners.
    static let expandedContentInset: CGFloat = 16

    static let expandedWidth: CGFloat = 460
    static let expandedHeight: CGFloat = 212

    /// Width of the `.band` stage: a capsule holding all three icon+label tabs
    /// (~255pt natural) with breathing room to the rounded ends.
    static let bandWidth: CGFloat = 300
    /// `.solo` stage width is per selected tab (`NotchViewModel.soloWidth`);
    /// these size the estimate — a fixed base (icon + spacing + button and end
    /// padding) plus the label's estimated width.
    static let soloBaseWidth: CGFloat = 78
    static let soloLabelCharWidth: CGFloat = 8

    /// How long the island rests in each transient stage before advancing —
    /// long enough to read the intermediate shape, short enough that the whole
    /// morph still feels like one continuous gesture. Collapse and expand walk
    /// the same stages in opposite directions; expand rests are a bit shorter
    /// so opening stays responsive on hover.
    static let bandCollapseDelay: TimeInterval = 0.55  // .band → .solo
    static let soloCollapseDelay: TimeInterval = 0.5   // .solo → .condensing
    /// How long the condensing stage (label fades, icon centres, capsule
    /// narrows to pill width) runs before the pill content swaps in — roughly
    /// the collapse spring's settling time, so the swap lands on a still image.
    static let condenseSwapDelay: TimeInterval = 0.42
    static let condenseExpandDelay: TimeInterval = 0.2  // .condensing → .solo
    static let soloExpandDelay: TimeInterval = 0.22     // .solo → .band
    static let bandExpandDelay: TimeInterval = 0.26     // .band → .expanded

    /// Fade of the labels and the unselected tabs as the capsule narrows around
    /// the surviving content. Deliberately much faster than the width spring:
    /// text must be gone *before* the narrowing rounded ends sweep over its
    /// position, or clipped letter fragments linger at the rim.
    static let condenseFadeAnimation: Animation = .easeOut(duration: 0.15)

    /// The arriving view fades in *on top* of the still-opaque departing one
    /// over this duration; the departing view only leaves once the newcomer is
    /// fully in (see `iconHandover`). Holding one layer opaque the whole time is
    /// what kills the crossfade brightness dip — the "flicker".
    static let pillHandoverFade: TimeInterval = 0.18

    /// Width of the collapsed pill while a live activity is showing.
    static let activityWidth: CGFloat = 220
    /// Wider pill for the audio-route activity (bigger icon + device name + battery)
    /// so a connecting device reads clearly.
    static let activityRouteWidth: CGFloat = 264

    // MARK: Island silhouette (iPhone Dynamic Island style)

    /// Gap between the physical top screen edge and the island — like the
    /// iPhone's Dynamic Island floating in the status bar. Identical in both
    /// states so the top edge stays put while the island morphs.
    static let islandTopGap: CGFloat = 6
    /// Collapsed corner radius = half the pill height, i.e. a true capsule.
    static var collapsedCornerRadius: CGFloat { collapsedHeight / 2 }
    /// Expanded corner radius — the iPhone's expanded Live Activity uses ~40pt;
    /// slightly tighter here since the panel band is denser.
    static let expandedCornerRadius: CGFloat = 36

    /// Pure black, iPhone-style — separation from a dark backdrop comes from
    /// the highlight rim and the shadow, not from the fill.
    static let islandFill = Color.black
    /// Hairline highlight rim: brighter along the top edge, fading out toward
    /// the bottom — sells the island as an object floating above the backdrop.
    static let islandStrokeTopOpacity: Double = 0.10
    static let islandStrokeBottomOpacity: Double = 0.02
    static let islandStrokeWidth: CGFloat = 1

    /// Drop shadow under the floating island (a touch stronger than before,
    /// since the detached island relies on it to read as elevated).
    static let islandShadowOpacityExpanded: Double = 0.55
    static let islandShadowOpacityCollapsed: Double = 0.35
    static let islandShadowRadius: CGFloat = 14
    static let islandShadowYOffset: CGFloat = 5

    // MARK: Panel margins

    /// The fixed panel is larger than the visible island so the SwiftUI
    /// island's shadow has room to render. Only the island animates inside.
    /// The vertical margin also absorbs the top gap the island floats below.
    static let panelHorizontalMargin: CGFloat = 60
    static var panelVerticalMargin: CGFloat { 24 + islandTopGap }

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
    /// Grace period before the island force-closes after the cursor leaves
    /// while the capture field is still focused (e.g. right after submitting
    /// a note, which re-focuses it for the next thought). Long enough to
    /// glance at the keyboard, short enough that the island doesn't stay open
    /// forever — nothing else ever un-focuses the field on its own.
    static let interactionLockGraceDelay: TimeInterval = 2.5
    /// Minimum vertical scroll magnitude to treat a swipe as a gesture.
    static let gestureScrollThreshold: CGFloat = 6
    /// A horizontal swipe only pages tabs once per gesture: a new gesture is
    /// recognized when this long has passed since the last horizontal scroll event
    /// (so trackpad momentum within one swipe doesn't flip through several tabs).
    static let tabSwipeGestureGap: TimeInterval = 0.25

    /// Silhouette morph for live-activity pills appearing/dismissing in the
    /// collapsed pill (not the expand/collapse walk). A small, lively spring.
    static let islandMorphAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.84)

    /// Silhouette morph (frame + corner radius) for each *collapse* stage. A
    /// bounce-free `.smooth` spring: collapsing reads as a calm, silky settling,
    /// never a snap or wobble.
    static let islandCollapseAnimation: Animation = .smooth(duration: 0.6)
    /// Same for each *expand* stage — the mirror of the collapse, a touch
    /// quicker so opening still feels responsive, but equally bounce-free.
    static let islandExpandAnimation: Animation = .smooth(duration: 0.44)

    /// Content fade-in on expand: slightly delayed so it appears once the
    /// silhouette has grown enough room, then a quick easeOut.
    static let contentInsertAnimation: Animation = .easeOut(duration: 0.20).delay(0.06)
    /// Content fade-out on collapse: fast easeIn so the content is gone *before*
    /// the silhouette finishes shrinking (nothing lingers outside the shape).
    /// Long enough that the active tab glyph's matched-geometry flight into the
    /// pill is readable before the rest fades.
    static let contentRemoveAnimation: Animation = .easeIn(duration: 0.16)
    /// Starting scale of inserted content — a subtle "grow out of the pill" morph.
    static let contentMorphScale: CGFloat = 0.96

    /// Switching tabs (tap button and horizontal swipe both use it) — drives the
    /// page carousel offset and the tab bar's sliding selection capsule.
    static let tabChangeAnimation: Animation = .spring(response: 0.38, dampingFraction: 0.82)

    /// Scale of the tab pages that aren't front — they sit slightly shrunken and
    /// dimmed beside the active page and grow in as they slide to front.
    static let tabPageInactiveScale: CGFloat = 0.96
    /// Opacity of the non-front tab pages while the carousel slides.
    static let tabPageInactiveOpacity: CGFloat = 0.3

    /// How long CaptureView waits before mounting its AppKit-backed text field.
    /// NSTextField ignores SwiftUI clip shapes, so the real field must not exist
    /// while the island morph (spring response 0.42) or the tab carousel spring
    /// (response 0.38) is still moving — a SwiftUI placeholder stands in until then.
    static let captureFieldMountDelay: TimeInterval = 0.45
}
