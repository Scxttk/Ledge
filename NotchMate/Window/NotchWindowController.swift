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
    private var scrollMonitor: Any?
    private var scrollMonitorGlobal: Any?
    private var hoverMonitorGlobal: Any?
    private var hoverMonitorLocal: Any?

    /// Logs the live hover evaluation to the Console when set (debugging only).
    private let debugHoverLogging = false

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

    init(viewModel: NotchViewModel, nowPlaying: NowPlayingManager, shelf: FileShelfModel, activities: ActivityManager, capture: ObsidianCapture) {
        self.viewModel = viewModel
        self.nowPlaying = nowPlaying
        self.shelf = shelf
        self.activities = activities

        let frame = NSRect(x: 0, y: 0, width: viewModel.panelWidth, height: viewModel.panelHeight)
        panel = NotchPanel(contentRect: frame)

        let root = NotchRootView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, activities: activities, capture: capture)
        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        container = NotchContainerView(frame: frame)
        container.islandRect = { [weak self, weak container] in
            guard let self, let container else { return .zero }
            let viewModel = self.viewModel
            let bounds = container.bounds
            let width: CGFloat
            let height: CGFloat
            if viewModel.isExpanded {
                width = viewModel.expandedWidth
                height = viewModel.expandedHeight
            } else {
                // Hug the visible pill (which sizes to its content) plus a small
                // tolerance, so it only expands when hovering the notch itself.
                width = viewModel.collapsedWidth(isPlaying: self.nowPlaying.isPlaying, hasItems: !self.shelf.items.isEmpty) + NotchLayout.hitTestWidthPadding
                height = viewModel.collapsedHeight + NotchLayout.hitTestHeightPadding
            }
            return NSRect(
                x: (bounds.width - width) / 2,
                y: bounds.height - height,
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
        setExpanded(true)
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
    /// flush with the top screen edge.
    private func islandScreenRect(expanded: Bool) -> NSRect? {
        guard let screen = ScreenManager.targetScreen() else { return nil }
        let width: CGFloat
        let height: CGFloat
        if expanded {
            width = viewModel.expandedWidth
            height = viewModel.expandedHeight
        } else {
            width = viewModel.collapsedWidth(isPlaying: nowPlaying.isPlaying, hasItems: !shelf.items.isEmpty) + NotchLayout.collapsedHoverInset * 2
            height = viewModel.collapsedHeight + NotchLayout.collapsedHoverInset
        }
        // Bleed the rect above the physical top edge: the cursor's y at the very
        // top equals screen.frame.maxY, and NSRect.contains treats the top edge as
        // exclusive (y < maxY) — without this margin the notch would refuse to
        // open at the screen edge and collapse the instant the cursor reaches it.
        let topBleed = NotchLayout.hoverTopBleed
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height + topBleed
        )
    }

    private func evaluateHover() {
        let cursor = NSEvent.mouseLocation
        if let last = lastEvaluatedCursor, abs(last.x - cursor.x) < 1, abs(last.y - cursor.y) < 1 {
            return
        }
        lastEvaluatedCursor = cursor
        followCursorScreenIfNeeded()

        if viewModel.isExpanded {
            guard let rect = islandScreenRect(expanded: true) else { return }
            let inside = rect.contains(cursor)
            if debugHoverLogging {
                NSLog("[NotchMate] hover expanded rect=%@ cursor=%@ inside=%d",
                      NSStringFromRect(rect), NSStringFromPoint(cursor), inside ? 1 : 0)
            }
            if inside {
                collapseWorkItem?.cancel()
            } else if !shelf.isDropTargeted && !viewModel.isInteractionLocked {
                // Cursor left the expanded footprint: collapse immediately. The
                // hover monitor is deterministic, so no debounce delay is needed.
                // A locked interaction (e.g. the capture field is focused) keeps
                // the island open so typing isn't dismissed.
                collapseWorkItem?.cancel()
                setExpanded(false)
            }
        } else {
            guard let rect = islandScreenRect(expanded: false) else { return }
            let inside = rect.contains(cursor)
            if debugHoverLogging {
                NSLog("[NotchMate] hover collapsed rect=%@ cursor=%@ inside=%d suppress=%d",
                      NSStringFromRect(rect), NSStringFromPoint(cursor), inside ? 1 : 0, suppressHover ? 1 : 0)
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

    private func setExpanded(_ expanded: Bool) {
        guard viewModel.isExpanded != expanded else { return }
        withAnimation(NotchLayout.islandMorphAnimation) {
            viewModel.isExpanded = expanded
        }
        Haptics.perform(.levelChange)
    }
}
