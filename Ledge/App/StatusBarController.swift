import AppKit
import ServiceManagement

final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let settingsWindow = SettingsWindowController()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.topthird.inset.filled",
                accessibilityDescription: "Ledge"
            )
        }

        let menu = NSMenu()

        let loginItem = NSMenuItem(
            title: String(localized: "menu.launchAtLogin", defaultValue: "Bei Anmeldung starten"),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: String(localized: "menu.settings", defaultValue: "Einstellungen …"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: String(localized: "menu.quit", defaultValue: "Ledge beenden"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("Ledge: launch-at-login toggle failed: \(error)")
        }
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }
}
