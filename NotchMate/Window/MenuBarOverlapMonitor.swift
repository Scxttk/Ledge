import AppKit
import ApplicationServices

/// Detects when the frontmost app's menu bar (File/Edit/View/...) reaches far
/// enough to the right that it visually collides with the notch pill at
/// top-center — e.g. Audacity's wide menu ("Bearbeiten", "Wiedergabe", ...).
/// The pill can't dodge sideways (it's pinned to the physical/virtual notch),
/// so on overlap we just hide it until the frontmost app changes or its menu
/// bar shrinks back below the threshold.
///
/// Reads the frontmost app's menu-bar item frames via the Accessibility API.
/// This reuses the same Accessibility permission already requested for the
/// volume-key tap (`MediaKeyTap`) — no separate prompt. If the permission
/// isn't granted, or reading fails for any reason, this fails open (reports
/// no overlap), which matches today's behaviour exactly.
final class MenuBarOverlapMonitor {
    /// Called on the main thread whenever the overlap state changes.
    var onChange: ((Bool) -> Void)?

    /// The left edge (screen coordinates, same space as `NSScreen.frame`) of
    /// the currently visible notch pill. Supplied by the window controller,
    /// which owns the actual geometry.
    var notchLeftEdgeProvider: (() -> CGFloat?)?

    private var activationObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private(set) var isOverlapping = false

    /// How close the frontmost app's rightmost menu item may get to the
    /// pill's left edge before it counts as an overlap.
    private static let safetyMargin: CGFloat = 8
    private static let pollInterval: TimeInterval = 1.0

    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.evaluate() }

        // A menu bar can also change width without an app switch (e.g. a
        // document window gaining menu items). There's no reliable system-wide
        // "menu bar changed" notification, so a light poll is the pragmatic
        // fallback — cheap since it only runs while there's a frontmost app.
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        evaluate()
    }

    func stop() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit { stop() }

    private func evaluate() {
        let overlapping = computeOverlap()
        guard overlapping != isOverlapping else { return }
        isOverlapping = overlapping
        onChange?(overlapping)
    }

    private func computeOverlap() -> Bool {
        guard MediaKeyTap.hasAccessibilityPermission(prompt: false) else { return false }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let notchLeftEdge = notchLeftEdgeProvider?(),
              let rightEdge = rightmostMenuItemEdge(pid: app.processIdentifier)
        else { return false }
        return rightEdge + Self.safetyMargin > notchLeftEdge
    }

    /// The right edge (screen coordinates) of the frontmost app's last
    /// top-level menu item — the one that determines how far the menu bar
    /// reaches to the right (typically "Hilfe"/"Fenster" or "Help"/"Window").
    /// AX screen coordinates share the same X axis as `NSScreen.frame` (only Y
    /// is flipped), so the X values are directly comparable.
    private func rightmostMenuItemEdge(pid: pid_t) -> CGFloat? {
        let axApp = AXUIElementCreateApplication(pid)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBarElement = menuBarValue
        else { return nil }

        // The AX API returns CFTypeRef; check the type IDs instead of
        // force-casting so an unexpected shape reads as "no menu bar found"
        // (fails open — the notch stays visible) rather than a crash.
        guard CFGetTypeID(menuBarElement) == AXUIElementGetTypeID() else { return nil }
        let menuBar = unsafeDowncast(menuBarElement, to: AXUIElement.self)

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement],
              let lastItem = children.last
        else { return nil }

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(lastItem, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(lastItem, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return nil }

        return position.x + size.width
    }
}
