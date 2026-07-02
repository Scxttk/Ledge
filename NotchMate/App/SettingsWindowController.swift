import AppKit
import SwiftUI

/// Hosts `SettingsView` in a dedicated AppKit window. We manage the window
/// ourselves instead of relying on SwiftUI's `Settings` scene + the
/// `showSettingsWindow:` selector, which is unreliable for a `.accessory`
/// (menu-bar) app across macOS versions.
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "NotchMate"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
