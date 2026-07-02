import AppKit

enum ScreenManager {
    /// The screen the notch should currently live on: the one the cursor is on,
    /// so the island follows the user across a multi-display setup. Falls back to
    /// the menu-bar screen, then any screen.
    static func targetScreen() -> NSScreen? {
        let cursor = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Whether the given screen has a physical notch (camera housing). Used to
    /// decide whether to hug the real notch or just float a pill at top-center.
    static func hasPhysicalNotch(_ screen: NSScreen) -> Bool {
        // A notched display has a non-zero top safe-area inset.
        screen.safeAreaInsets.top > 0
    }
}
