import AppKit
import SwiftUI

final class NotchWindowController {
    private let panel: NotchPanel
    private let viewModel: NotchViewModel
    private let nowPlaying: NowPlayingManager
    private let shelf: FileShelfModel
    private let activities: ActivityManager
    private let container: NotchContainerView

    private var collapseWorkItem: DispatchWorkItem?
    /// Pending "advance to the next stage" step of the staged expand/collapse
    /// walk, so a direction change mid-walk can cancel it and reverse.
    private var stageWorkItem: DispatchWorkItem?
    /// Where the staged walk is currently heading (`.expanded` or `.collapsed`),
    /// or nil when the island is at rest. Guards against hover events restarting
    /// a walk that's already going the right way.
    private var stagingTarget: NotchViewModel.IslandState?
    private var scrollMonitor: Any?
    private var scrollMonitorGlobal: Any?
    private var hoverMonitorGlobal: Any?
    private var hoverMonitorLocal: Any?

    /// Logs the live hover evaluation to a plain file when set (debugging only).
    /// A file is used instead of NSLog because modern macOS redacts dynamic
    /// `%@` substitutions in the unified log by default.
    private let debugHoverLogging = false

    private func debugLog(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/notchmate_hover_debug.log")
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// When the user closes the notch with a swipe-up, suppress hover-expand
    /// until the cursor has left the island once.
    private var suppressHover = false

    /// The screen the panel is currently positioned on, so we only move it when
    /// the cursor actually crosses to a different display.
    private weak var currentScreen: NSScreen?

    /// Last cursor position we actually evaluated hover for. `mouseMoved` fires
    /// far more often than the cursor meaningfully moves; skipping sub-pixel
    /// deltas keeps the monitor cheap.
    private var lastEvaluatedCursor: NSPoint?

    /// Timestamp of the last horizontal scroll event, so one swipe pages one tab
    /// (trackpad momentum keeps firing events; we only act on a fresh gesture).
    private var lastHorizontalScroll = Date.distantPast

    init(viewModel: NotchViewModel, nowPlaying: NowPlayingManager, shelf: FileShelfModel, activities: ActivityManager, capture: ObsidianCapture, spectrum: SpectrumAnalyzer) {
        self.viewModel = viewModel
        self.nowPlaying = nowPlaying
        self.shelf = shelf
        self.activities = activities

        let frame = NSRect(x: 0, y: 0, width: viewModel.panelWidth, height: viewModel.panelHeight)
        panel = NotchPanel(contentRect: frame)

        let root = NotchRootView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, activities: activities, capture: capture, spectrum: spectrum)
        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        container = NotchContainerView(frame: frame)
        container.islandRect = { [weak self, weak container] in
            guard let self, let container else { return .zero }
            let viewModel = self.viewModel
            let bounds = container.bounds
            let width: CGFloat
            let height: CGFloat
            // Stay at the expanded footprint through the whole staged walk, not
            // only at the terminal `.expanded` state — otherwise clicks fall
            // through the still-visible large island while it collapses.
            if viewModel.occupiesExpandedFootprint {
                width = viewModel.expandedWidth
                height = viewModel.expandedHeight
            } else {
                // Hug the visible pill (which sizes to its content) plus a small
                // tolerance, so it only expands when hovering the notch itself.
                width = viewModel.collapsedWidth(isPlaying: self.nowPlaying.isPlaying, hasItems: !self.shelf.items.isEmpty) + NotchLayout.hitTestWidthPadding
                height = viewModel.collapsedHeight + NotchLayout.hitTestHeightPadding
            }
            // The island floats `islandTopGap` below the container's top edge.
            return NSRect(
                x: (bounds.width - width) / 2,
                y: bounds.height - NotchLayout.islandTopGap - height,
                width: width,
                height: height
            )
        }
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container

        container.onDragEntered = { [weak self] in self?.handleDragEntered() }
        container.onDragExited = { [weak self] in self?.handleDragExited() }
        container.onDrop = { [weak self] urls in self?.handleDrop(urls) }

        installScrollMonitor()
        installHoverMonitor()
    }

    deinit {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        if let scrollMonitorGlobal {
            NSEvent.removeMonitor(scrollMonitorGlobal)
        }
        if let hoverMonitorGlobal {
            NSEvent.removeMonitor(hoverMonitorGlobal)
        }
        if let hoverMonitorLocal {
            NSEvent.removeMonitor(hoverMonitorLocal)
        }
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    // MARK: - Sleep/Wake lifecycle

    /// Tear down the live event monitors before the system sleeps so no stale
    /// global monitors fire during/after sleep. Paired with `resumeMonitors()`.
    func suspendMonitors() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let scrollMonitorGlobal {
            NSEvent.removeMonitor(scrollMonitorGlobal)
            self.scrollMonitorGlobal = nil
        }
        if let hoverMonitorGlobal {
            NSEvent.removeMonitor(hoverMonitorGlobal)
            self.hoverMonitorGlobal = nil
        }
        if let hoverMonitorLocal {
            NSEvent.removeMonitor(hoverMonitorLocal)
            self.hoverMonitorLocal = nil
        }
        collapseWorkItem?.cancel()
        // Don't strand the island mid-walk over a sleep: finish the remaining
        // stages immediately (no animation — the screen is going dark anyway).
        stageWorkItem?.cancel()
        stageWorkItem = nil
        stagingTarget = nil
        switch viewModel.islandState {
        case .band, .solo, .condensing:
            viewModel.islandState = .collapsed
        case .expanded, .collapsed:
            break
        }
    }

    /// Re-install the monitors on wake and snap the panel back to the correct
    /// screen (display topology can change while asleep).
    func resumeMonitors() {
        guard scrollMonitor == nil, scrollMonitorGlobal == nil, hoverMonitorGlobal == nil, hoverMonitorLocal == nil else { return }
        installScrollMonitor()
        installHoverMonitor()
        reposition()
    }

    // MARK: - Quick Capture

    /// Open the island on the capture tab and focus its text field. Driven by
    /// the global hotkey. The panel is non-activating, so we make it key
    /// explicitly so keystrokes reach the field.
    func presentCapture() {
        suppressHover = false
        collapseWorkItem?.cancel()
        viewModel.selectedTab = .capture
        // Open directly (not through the staged reveal) so the field is ready
        // to type into immediately.
        setExpanded(true, staged: false)
        panel.makeKeyAndOrderFront(nil)
        viewModel.requestCaptureFocus()
    }

    func reposition() {
        guard let screen = ScreenManager.targetScreen() else { return }
        currentScreen = screen
        let width = viewModel.panelWidth
        let height = viewModel.panelHeight
        panel.setFrame(
            NSRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.maxY - height,
                width: width,
                height: height
            ),
            display: true
        )
    }

    /// Move the panel to the screen the cursor is on if it has changed. Only
    /// acts while collapsed so an open island doesn't jump mid-interaction.
    private func followCursorScreenIfNeeded() {
        guard !viewModel.isExpanded else { return }
        guard let screen = ScreenManager.targetScreen(), screen !== currentScreen else { return }
        reposition()
    }

    // MARK: - Hover

    /// Hover detection is driven by the *real* cursor position
    /// (`NSEvent.mouseLocation`) checked against the actually-rendered island
    /// rect in screen coordinates — not by an `NSTrackingArea`. Tracking areas
    /// fire unreliably for a borderless, non-activating panel pinned to the top
    /// screen edge (it overlaps the menu bar), which caused the notch to expand
    /// while the cursor was merely inside the *expanded* footprint rather than
    /// over the small visible pill. A global + local mouse-moved monitor is
    /// deterministic: we only expand when the cursor is genuinely over the pill.
    private func installHoverMonitor() {
        hoverMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.evaluateHover()
        }
        hoverMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.evaluateHover()
            return event
        }
    }

    /// The visible island rect in global screen coordinates (origin bottom-left),
    /// matching what the SwiftUI island actually draws: centered horizontally,
    /// floating `islandTopGap` below the top screen edge.
    private func islandScreenRect(expanded: Bool) -> NSRect? {
        guard let screen = ScreenManager.targetScreen() else { return nil }
        let width: CGFloat
        let height: CGFloat
        if expanded {
            width = viewModel.expandedWidth + NotchLayout.expandedHoverInset * 2
            height = viewModel.expandedHeight + NotchLayout.expandedHoverInset
        } else {
            width = viewModel.collapsedWidth(isPlaying: nowPlaying.isPlaying, hasItems: !shelf.items.isEmpty) + NotchLayout.collapsedHoverInset * 2
            height = viewModel.collapsedHeight + NotchLayout.collapsedHoverInset
        }
        // The island floats `islandTopGap` below the edge, but the hover zone
        // still spans all the way to (and past) the top: pushing the cursor
        // against the screen edge above the island must keep opening it. The
        // extra bleed exists because the cursor's y at the very top equals
        // screen.frame.maxY, and NSRect.contains treats the top edge as
        // exclusive (y < maxY) — without it the notch would refuse to open at
        // the screen edge and collapse the instant the cursor reaches it.
        let topBleed = NotchLayout.hoverTopBleed
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - NotchLayout.islandTopGap - height,
            width: width,
            height: height + NotchLayout.islandTopGap + topBleed
        )
    }

    private func evaluateHover() {
        let cursor = NSEvent.mouseLocation
        if let last = lastEvaluatedCursor, abs(last.x - cursor.x) < 1, abs(last.y - cursor.y) < 1 {
            return
        }
        lastEvaluatedCursor = cursor
        followCursorScreenIfNeeded()

        // Key off the *visible* footprint, not the terminal `.expanded` state:
        // through the whole staged collapse walk the island is still large, so
        // it must stay catchable — a re-hover reverses the collapse, and the
        // hover rect matches what the user sees rather than snapping to the pill.
        if viewModel.occupiesExpandedFootprint {
            guard let rect = islandScreenRect(expanded: true) else { return }
            let inside = rect.contains(cursor)
            if debugHoverLogging {
                debugLog("hover expanded rect=\(NSStringFromRect(rect)) cursor=\(NSStringFromPoint(cursor)) inside=\(inside) dropTargeted=\(shelf.isDropTargeted) interactionLocked=\(viewModel.isInteractionLocked)")
            }
            if inside {
                collapseWorkItem?.cancel()
                // Reverse an in-progress collapse walk (no-op once fully open).
                // Respect the post-swipe suppression so a swipe-up close isn't
                // instantly undone by a stationary cursor.
                if !suppressHover { setExpanded(true) }
            } else if !shelf.isDropTargeted && !viewModel.isInteractionLocked {
                // Cursor left the expanded footprint: collapse immediately. The
                // hover monitor is deterministic, so no debounce delay is needed.
                suppressHover = false
                collapseWorkItem?.cancel()
                setExpanded(false)
            } else if !shelf.isDropTargeted && viewModel.isInteractionLocked {
                // The capture field is focused (e.g. right after submitting a
                // note, which re-focuses it for the next thought) and normally
                // that keeps the island open so typing isn't dismissed. But
                // nothing ever un-focuses it on its own, so without this the
                // island stayed open forever once you'd used Capture — the
                // cursor being gone is itself a signal you're done. Grant a
                // short grace period instead of blocking collapse indefinitely.
                if collapseWorkItem == nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        // Clear the slot first: the `== nil` guard above is what
                        // re-arms this grace timer, so a fired item must release
                        // it or the grace never schedules again after the first.
                        self.collapseWorkItem = nil
                        self.viewModel.isInteractionLocked = false
                        self.setExpanded(false)
                    }
                    collapseWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.interactionLockGraceDelay, execute: work)
                }
            }
        } else {
            guard let rect = islandScreenRect(expanded: false) else { return }
            let inside = rect.contains(cursor)
            if debugHoverLogging {
                debugLog("hover collapsed rect=\(NSStringFromRect(rect)) cursor=\(NSStringFromPoint(cursor)) inside=\(inside) suppress=\(suppressHover)")
            }
            if inside {
                guard !suppressHover else { return }
                collapseWorkItem?.cancel()
                setExpanded(true)
            } else {
                // Cursor left the pill: clear the post-swipe suppression so the
                // next genuine hover can expand again.
                suppressHover = false
            }
        }
    }

    // MARK: - File drag

    private func handleDragEntered() {
        collapseWorkItem?.cancel()
        suppressHover = false
        viewModel.selectedTab = .files
        shelf.isDropTargeted = true
        if !viewModel.isExpanded {
            setExpanded(true)
        }
    }

    private func handleDragExited() {
        shelf.isDropTargeted = false
        scheduleCollapse()
    }

    private func handleDrop(_ urls: [URL]) {
        shelf.isDropTargeted = false
        viewModel.selectedTab = .files
        for url in urls {
            shelf.add(url)
        }
        Haptics.perform(.generic)
        if !urls.isEmpty {
            activities.fileReceived(count: urls.count)
        }
    }

    private func scheduleCollapse() {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapseWorkItem = nil
            self?.setExpanded(false)
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.collapseDelay, execute: work)
    }

    // MARK: - Trackpad gestures

    private func installScrollMonitor() {
        // Local monitor: fires when the scroll lands on the panel (cursor over the
        // interactive island rect). Handles open *and* close and consumes the event.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleIslandScroll(event) ? nil : event
        }
        // Global monitor: while collapsed, a two-finger swipe-down should also open
        // the notch anywhere within the *expanded* notch footprint — not just over
        // the small pill. Outside the pill `NotchContainerView.hitTest` returns nil
        // (so clicks fall through), which means the local monitor never sees those
        // scrolls; the global monitor catches them. Global monitors are observe-only
        // (they can't consume the event), which is fine for a mere open.
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleBigNotchRegionScroll(event)
        }
    }

    /// Handle a deliberate swipe on the island itself. Returns whether it was
    /// consumed. Natural scrolling: two fingers down -> dy > 0 -> open; while
    /// expanded, a horizontal swipe pages between tabs.
    private func handleIslandScroll(_ event: NSEvent) -> Bool {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let threshold = NotchLayout.gestureScrollThreshold

        // Horizontal swipe while expanded -> page between tabs. Fire only on the
        // first event of a gesture so momentum doesn't skip through several tabs.
        if viewModel.isExpanded, abs(dx) > threshold, abs(dx) > abs(dy) {
            let now = Date()
            let isNewGesture = now.timeIntervalSince(lastHorizontalScroll) > NotchLayout.tabSwipeGestureGap
            lastHorizontalScroll = now
            if isNewGesture { pageTab(next: dx < 0) }
            return true
        }

        // Vertical swipe -> expand / collapse.
        guard abs(dy) > threshold, abs(dy) > abs(dx) else { return false }
        if dy > 0 {
            expandViaGesture()
        } else {
            collapseViaGesture()
        }
        return true
    }

    /// Move the tab selection one step, clamped to the ends (no wrap-around).
    /// `next` advances toward `.capture`; `!next` toward `.music`.
    private func pageTab(next: Bool) {
        let tabs = NotchViewModel.Tab.allCases
        guard let index = tabs.firstIndex(of: viewModel.selectedTab) else { return }
        let target = index + (next ? 1 : -1)
        guard tabs.indices.contains(target) else { return }
        Haptics.perform(.alignment)
        withAnimation(NotchLayout.tabChangeAnimation) { viewModel.selectedTab = tabs[target] }
    }

    /// Open the collapsed notch from a swipe-down that lands anywhere within the
    /// expanded-notch footprint (the "big notch" boundary), where the local monitor
    /// can't see the event because hit-testing lets it fall through.
    private func handleBigNotchRegionScroll(_ event: NSEvent) {
        guard !viewModel.isExpanded else { return }
        let dy = event.scrollingDeltaY
        guard dy > 0, abs(dy) > NotchLayout.gestureScrollThreshold, abs(dy) > abs(event.scrollingDeltaX) else { return }
        guard let rect = islandScreenRect(expanded: true), rect.contains(NSEvent.mouseLocation) else { return }
        expandViaGesture()
    }

    private func expandViaGesture() {
        suppressHover = false
        collapseWorkItem?.cancel()
        guard !viewModel.isExpanded else { return }
        setExpanded(true)
    }

    private func collapseViaGesture() {
        collapseWorkItem?.cancel()
        guard viewModel.isExpanded else { return }
        suppressHover = true
        setExpanded(false)
    }

    // MARK: - State

    /// The expand/collapse stage sequence, most-collapsed first. Both
    /// directions walk this list one step at a time (`advanceStaging`), so the
    /// collapse — panel → tab band → solo tab → lone icon → pill — plays in
    /// exact reverse when opening.
    private static let stageOrder: [NotchViewModel.IslandState] =
        [.collapsed, .condensing, .solo, .band, .expanded]

    /// Walk the island one stage at a time toward the given end state. Called
    /// repeatedly by hover/gesture; re-targeting mid-walk just reverses from
    /// wherever we are. `staged: false` jumps straight there (the capture
    /// hotkey wants the field open now, not after the staged reveal).
    private func setExpanded(_ expanded: Bool, staged: Bool = true) {
        let target: NotchViewModel.IslandState = expanded ? .expanded : .collapsed

        guard viewModel.islandState != target else {
            // Already there — make sure no stale walk keeps running.
            stageWorkItem?.cancel(); stageWorkItem = nil
            stagingTarget = nil
            return
        }
        guard staged else {
            stageWorkItem?.cancel(); stageWorkItem = nil
            stagingTarget = nil
            withAnimation(NotchLayout.islandExpandAnimation) { viewModel.islandState = target }
            Haptics.perform(.levelChange)
            return
        }
        guard stagingTarget != target else { return }  // already walking there
        stageWorkItem?.cancel(); stageWorkItem = nil
        stagingTarget = target
        // One tap the moment the morph is triggered — not per stage, which felt
        // like too much.
        Haptics.perform(.levelChange)
        advanceStaging()
    }

    /// Move the island one stage toward `stagingTarget`, then schedule the next
    /// step after that stage's rest delay. The final step lands on the target
    /// and ends the walk.
    private func advanceStaging() {
        guard let target = stagingTarget,
              let current = Self.stageOrder.firstIndex(of: viewModel.islandState),
              let goal = Self.stageOrder.firstIndex(of: target)
        else { return }
        guard current != goal else {
            stagingTarget = nil; stageWorkItem = nil
            return
        }

        let expanding = goal > current
        let next = Self.stageOrder[current + (expanding ? 1 : -1)]

        if next == .collapsed {
            // Handover to the pill: no withAnimation — the condensed icon and
            // the pill are visually identical; the content transition fades on
            // its own explicit clock (no crossfade dip).
            viewModel.islandState = .collapsed
        } else {
            withAnimation(expanding ? NotchLayout.islandExpandAnimation : NotchLayout.islandCollapseAnimation) {
                viewModel.islandState = next
            }
        }

        guard next != target else {
            stagingTarget = nil; stageWorkItem = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.advanceStaging() }
        stageWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + stageRestDelay(entering: next, expanding: expanding),
            execute: work
        )
    }

    /// How long to rest in an intermediate stage before advancing. Expand rests
    /// are shorter than collapse rests so opening stays responsive on hover.
    private func stageRestDelay(entering state: NotchViewModel.IslandState, expanding: Bool) -> TimeInterval {
        switch (state, expanding) {
        case (.band, false):       return NotchLayout.bandCollapseDelay
        case (.solo, false):       return NotchLayout.soloCollapseDelay
        case (.condensing, false): return NotchLayout.condenseSwapDelay
        case (.condensing, true):  return NotchLayout.condenseExpandDelay
        case (.solo, true):        return NotchLayout.soloExpandDelay
        case (.band, true):        return NotchLayout.bandExpandDelay
        default:                   return 0
        }
    }
}
