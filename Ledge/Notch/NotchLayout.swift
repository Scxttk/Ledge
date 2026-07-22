import SwiftUI

/// Central source of truth for the island's geometry, animation and timing
/// constants. Previously these were scattered as magic numbers across
/// `NotchViewModel`, `NotchWindowController`, `IslandShape` and the views.
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
    static let collapsedWavesWidth: CGFloat = 16
    /// Corner radius of the collapsed pill's artwork thumbnail.
    static let collapsedArtworkCornerRadius: CGFloat = 3.5
    /// Wave-bars geometry inside the collapsed pill: 5 bars, thicker relative
    /// to their gaps than a hairline equalizer — matches the iPhone Dynamic
    /// Island's chunkier, closely-packed bars more closely than the earlier
    /// 6-hairline-bar version did. (5 × 2.0 + 4 × 1.0 = 14, `collapsedWavesWidth`
    /// above rounds up for a hair of buffer.)
    static let collapsedWaveBarCount: Int = 5
    static let collapsedWaveMaxHeight: CGFloat = 12
    static let collapsedWaveBarWidth: CGFloat = 2.0
    static let collapsedWaveSpacing: CGFloat = 1.0
    /// Spectrum-only pill (`UserSettings.pillSpectrumOnly`): the wave replaces
    /// the artwork thumbnail entirely and the whole pill grows into a stage
    /// for it — this mode exists to *watch*, so it deliberately takes more
    /// room than the cover+wave layout it replaces. Bar count and wave width
    /// are user-tunable (`pillSpectrumBarCount`/`pillSpectrumWidth`); these
    /// constants are the defaults and what the snapshot tests render. The
    /// taller pill (`collapsedTallHeight`) gives the bars real travel.
    static let collapsedWideWaveBarCount: Int = 16
    static let collapsedWideWaveMaxHeight: CGFloat = 18
    static let collapsedWideWavesWidth: CGFloat = 48
    static let collapsedWideWaveFrameHeight: CGFloat = 20
    /// Pill height while the spectrum-only mode is on (all island stages read
    /// it through `NotchViewModel.collapsedHeight`, so silhouette, hit rect
    /// and content rows stay in lock-step). 30 + `islandTopGap` (2) = 32 —
    /// still inside the physical notch's band on notched MacBooks.
    static let collapsedTallHeight: CGFloat = 30
    /// The collapsed height currently in effect (see `collapsedTallHeight`).
    /// Views without a `NotchViewModel` read this; the view model's
    /// `collapsedHeight` returns the same value, so there is one formula.
    static var currentCollapsedHeight: CGFloat {
        UserSettings.shared.pillSpectrumOnly ? collapsedTallHeight : collapsedHeight
    }
    /// Font size of the shelf badge's item count in the collapsed pill.
    static let collapsedBadgeFontSize: CGFloat = 9
    /// The shelf badge (tray icon + item count, up to ~2 digits).
    static let collapsedBadgeWidth: CGFloat = 30
    /// Focus-timer segment in the collapsed pill (icon + monospaced readout).
    /// Its width is estimated as icon + inner spacing + chars × per-char width
    /// (see `NotchViewModel.collapsedWidth`); the per-char estimate errs
    /// generous like `soloLabelCharWidth` — looseness is harmless, clipping
    /// is not.
    static let collapsedTimerFontSize: CGFloat = 11
    static let collapsedTimerIconSize: CGFloat = 10
    static let collapsedTimerIconWidth: CGFloat = 12
    static let collapsedTimerInnerSpacing: CGFloat = 3
    static let collapsedTimerCharWidth: CGFloat = 7
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

    /// Width of the `.band` stage: a capsule holding all four icon+label tabs
    /// (~335pt natural) with breathing room to the rounded ends.
    static let bandWidth: CGFloat = 380
    /// `.solo` stage width is per selected tab (`NotchViewModel.soloWidth`);
    /// these size the estimate — a fixed base (icon + spacings + button and end
    /// padding + the two content insets) plus the label's estimated width,
    /// counted twice since the centred icon mirrors the label as empty space.
    static let soloBaseWidth: CGFloat = 74
    static let soloLabelCharWidth: CGFloat = 8
    /// HStack spacing between a tab's icon and its label — also the amount the
    /// solo tab is shifted by to re-centre the icon.
    static let tabIconLabelSpacing: CGFloat = 4
    /// Spacing between tab groups in the expanded tab bar.
    static let tabBarSpacing: CGFloat = 6
    /// Padding inside each tab button (around icon + label).
    static let tabItemPaddingVertical: CGFloat = 3
    static let tabItemPaddingHorizontal: CGFloat = 10
    /// Foreground opacity of an unselected tab (selected is fully opaque).
    static let tabInactiveOpacity: Double = 0.55
    /// Vertical spacing between the tab bar and the page carousel when expanded.
    static let expandedRowSpacing: CGFloat = 8
    /// Bottom padding below the page carousel when expanded.
    static let expandedBottomPadding: CGFloat = 20

    /// How long the island rests in each transient stage before advancing.
    /// Tuned frame-by-frame (see `IslandChoreographySheetTests`): each rest is
    /// deliberately *shorter* than the hop animation's settling time, so the
    /// next stage retargets the spring while the silhouette is still moving —
    /// the walk reads as one continuous gesture. At the earlier values
    /// (0.30–0.35, ≈ the settling time) every hop braked to a near-standstill
    /// before the next began: a visible staircase. The stages still fire in
    /// order, so the content choreography (pages out → tabs out → labels out,
    /// each a 0.15–0.16 s fade) keeps fitting inside its stage's rest.
    static let bandCollapseDelay: TimeInterval = 0.18  // .band → .solo
    static let soloCollapseDelay: TimeInterval = 0.18  // .solo → .condensing
    /// How long the condensing stage (label fades, icon centres, capsule
    /// narrows to pill width) runs before the pill content swaps in — long
    /// enough past the last retarget that the swap lands on a nearly still
    /// image.
    static let condenseSwapDelay: TimeInterval = 0.30
    /// Expand rests are near-zero: opening must move the instant the hover
    /// lands, and the expand hops exist as spring waypoints (each retargeted
    /// mid-flight), not as shapes to linger on. Stages that don't change the
    /// island at all for the current content are skipped entirely — see
    /// `NotchWindowController.stageRestDelay`.
    static let condenseExpandDelay: TimeInterval = 0.03  // .condensing → .solo
    static let soloExpandDelay: TimeInterval = 0.07      // .solo → .band
    static let bandExpandDelay: TimeInterval = 0.09      // .band → .expanded

    /// Fade of the labels and the unselected tabs as the capsule narrows around
    /// the surviving content. Deliberately much faster than the width spring:
    /// text must be gone *before* the narrowing rounded ends sweep over its
    /// position, or clipped letter fragments linger at the rim.
    static let condenseFadeAnimation: Animation = .easeOut(duration: 0.15)

    /// The arriving view fades in *on top* of the still-opaque departing one
    /// over this duration; the departing view only leaves once the newcomer is
    /// fully in (see `iconHandover`). Holding one layer opaque the whole time is
    /// what kills the crossfade brightness dip — the "flicker". The whole
    /// handover (fade-in + cut) must fit inside the expand walk's
    /// time-to-`.band` (`condenseExpandDelay` + `soloExpandDelay` = 0.10):
    /// the hold-opaque trick only works while the two icons sit superposed,
    /// and at `.band` the tab-bar icon starts flying to its slot — the
    /// departing pill icon has to be *fully gone* by then, or it stands at
    /// the capsule centre as a doubled glyph while its twin flies away
    /// (frame-by-frame this was plainly visible at 0.13–0.17 s).
    static let pillHandoverFade: TimeInterval = 0.05
    /// Duration of the departing layer's cut once the newcomer is fully in (the
    /// removal side of `iconHandover`), after the `pillHandoverFade` delay.
    /// Fade + cut = 0.10 = the moment the flight starts.
    static let pillHandoverRemoveFade: TimeInterval = 0.05
    /// Delay before the *unselected* tabs fade in once the band assembles on
    /// expand. The selected icon travels from the capsule centre to its slot
    /// during the band/final hops, passing over its neighbours' positions —
    /// fading them in immediately painted them under the still-flying icon
    /// (Scott: "voll die überlagerung"). Timed so the fade starts once the
    /// flight is essentially home: the capsule leads, its content follows.
    static let tabJoinFadeDelay: TimeInterval = 0.20

    /// When music plays, the collapse hands the tab bar off to the now-playing
    /// pill hero (cover + spectrum) at the `.solo` stage. Those two are *different*
    /// content, so unlike `pillHandoverFade` this is a genuine crossfade —
    /// a hold-opaque handover would show them overlapping. Slightly longer
    /// for a smooth dissolve as the capsule narrows.
    static let heroCrossfadeDuration: TimeInterval = 0.24
    /// The arriving side of the hero crossfade starts this much later than the
    /// departing side — sequenced, not overlapped: the wave dissolves first,
    /// *then* the tab bar materialises. At a shorter delay the two were both
    /// half-visible for ~0.14 s (the composite filmstrip showed tab icons
    /// appearing around a still-visible wave — the "mush" that read as
    /// buggy). Set to the crossfade duration minus a hair, so the departing
    /// side is ≥ 90% gone before the arriving side begins; the black island
    /// carries the brief quiet moment between them.
    static let heroCrossfadeInsertDelay: TimeInterval = 0.22

    /// Width of the collapsed pill while a live activity is showing.
    static let activityWidth: CGFloat = 220
    /// Wider pill for the audio-route activity (bigger icon + device name + battery)
    /// so a connecting device reads clearly.
    static let activityRouteWidth: CGFloat = 264

    // MARK: Island silhouette (iPhone Dynamic Island style)

    /// Gap between the physical top screen edge and the island — like the
    /// iPhone's Dynamic Island floating in the status bar. Identical in both
    /// states so the top edge stays put while the island morphs.
    static let islandTopGap: CGFloat = 2
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
    /// Outward tolerance around the *expanded* island before a cursor counts as
    /// having left it. Gives the collapse boundary a little hysteresis so a
    /// graze along the exact visible edge doesn't commit the slow collapse
    /// walk — "open" was already padded (`collapsedHoverInset`), this pads
    /// "stay open" to match.
    static let expandedHoverInset: CGFloat = 6
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
    /// collapsed pill (not the expand/collapse walk). A small, lively spring —
    /// damping low enough for a visible snap, like the iPhone's island pills.
    static let islandMorphAnimation: Animation = .spring(response: 0.40, dampingFraction: 0.74)

    /// Silhouette morph (frame + corner radius) for each *collapse* stage. A
    /// bounce-free `.smooth` spring: collapsing reads as a calm, silky settling,
    /// never a snap or wobble — overshoot on *closing* looks wrong.
    static let islandCollapseAnimation: Animation = .smooth(duration: 0.55)
    /// Each *intermediate* expand stage — quicker than the collapse so opening
    /// on hover feels snappy, with a whisper of bounce for life. These hops are
    /// re-animated almost immediately, so real overshoot would just wobble.
    static let islandExpandAnimation: Animation = .snappy(duration: 0.30, extraBounce: 0.1)
    /// The *final* expand hop (`.band → .expanded`) is the only one that rests,
    /// so it can afford a genuine overshoot-and-settle — the Dynamic-Island
    /// "pop" that the intermediate hops must not have.
    static let islandExpandFinalAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.70)

    /// Content fade-in on expand: slightly delayed so it appears once the
    /// silhouette has grown enough room, then springs out of the pill with the
    /// same character as the silhouette's final pop.
    static let contentInsertAnimation: Animation = .spring(response: 0.35, dampingFraction: 0.75).delay(0.05)
    /// Content fade-out on collapse: fast easeIn so the content is gone *before*
    /// the silhouette finishes shrinking (nothing lingers outside the shape).
    /// Long enough that the active tab glyph's matched-geometry flight into the
    /// pill is readable before the rest fades. Never springy — removal that
    /// bounces reads as broken.
    static let contentRemoveAnimation: Animation = .easeIn(duration: 0.16)
    /// Starting scale of inserted content — the "grow out of the pill" morph,
    /// pronounced enough to register now that the insert is a spring.
    static let contentMorphScale: CGFloat = 0.93

    /// Switching tabs (tap button and horizontal swipe both use it) — drives the
    /// page carousel offset and the tab bar's sliding selection capsule. A hint
    /// of overshoot; the pages are clipped, so it can't escape the island.
    static let tabChangeAnimation: Animation = .spring(response: 0.35, dampingFraction: 0.74)

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

    // MARK: Claude tab (usage + shifter)

    /// Gap between the usage column and the shifter block.
    static let claudeColumnSpacing: CGFloat = 18
    static let claudeUsageRowSpacing: CGFloat = 7
    static let claudeUsageBarHeight: CGFloat = 5
    /// Horizontal distance between two model lanes of the shift gate.
    static let claudeShifterLaneSpacing: CGFloat = 34
    /// Vertical distance between two effort rows (low → medium → high).
    static let claudeShifterRowSpacing: CGFloat = 36
    /// Inset from the gate plate's edge to the outermost slot endpoints —
    /// keeps the knob fully inside the plate at the end gates.
    static let claudeShifterPadding: CGFloat = 13
    /// Visual thickness of the milled slots the knob travels in.
    static let claudeShifterSlotWidth: CGFloat = 10
    static let claudeShifterKnobSize: CGFloat = 20
    /// Gap between the gearbox and the mode button below it.
    static let claudeShifterModeSpacing: CGFloat = 6
    /// AppleScript `delay` (seconds) between activating Claude.app and typing —
    /// the window needs a beat to take key focus or the first chars get eaten.
    static let claudeKeystrokeActivateDelay: Double = 0.4
    /// AppleScript `delay` between the `/model` and `/effort` commands, so the
    /// first command is accepted before the second starts typing. Generous:
    /// at 0.6 the `/effort` half was intermittently swallowed while the app
    /// still rendered the model-switch confirmation.
    static let claudeKeystrokeCommandDelay: Double = 1.2
    /// AppleScript `delay` between typing a slash command and pressing return —
    /// the command popup needs a beat, or the return gets swallowed and the
    /// command stays as plain text in the composer.
    static let claudeKeystrokeReturnDelay: Double = 0.25
    /// Distance (pt) above the Claude window's bottom edge where the focus
    /// click lands — mid-composer, clear of the window edge and send button.
    static let claudeComposerBottomOffset: Int = 60
    /// AppleScript `delay` between the composer click and typing. Empirically
    /// ≥1.2s: the Electron webview takes well over half a second to route the
    /// click focus; at 0.5s the whole command evaporated (worked at the ~2s
    /// the old focus-poll loop accidentally provided).
    static let claudeComposerClickDelay: Double = 1.2
}
