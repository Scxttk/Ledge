import AppKit
import Combine

/// Coordinates Quick Capture: owns the vault writer and the global hotkey,
/// performs captures, and surfaces a confirmation/error via the live-activity
/// engine. Injected into the notch UI like the other feature managers.
final class ObsidianCapture: ObservableObject {
    /// Mirrors whether a vault folder is configured, so the UI can prompt setup.
    @Published private(set) var isConfigured: Bool

    /// Set by the app delegate; called when the global hotkey fires.
    var onHotKey: (() -> Void)?

    private let settings: UserSettings
    private weak var activities: ActivityManager?
    private let vault = ObsidianVault()
    private let hotKey = CaptureHotKey()
    private var cancellables = Set<AnyCancellable>()

    init(settings: UserSettings = .shared, activities: ActivityManager) {
        self.settings = settings
        self.activities = activities
        self.isConfigured = settings.vaultBookmark != nil
    }

    func start() {
        hotKey.onTrigger = { [weak self] in self?.onHotKey?() }
        applyHotKeySetting()
        settings.$captureHotkeyEnabled
            .dropFirst()
            .sink { [weak self] _ in self?.applyHotKeySetting() }
            .store(in: &cancellables)
        settings.$vaultBookmark
            .map { $0 != nil }
            .sink { [weak self] configured in self?.isConfigured = configured }
            .store(in: &cancellables)
    }

    func stop() {
        hotKey.unregister()
        cancellables.removeAll()
    }

    /// Append a free-text capture to today's daily note. Returns true on success
    /// (the caller clears the field only then).
    @discardableResult
    func capture(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            _ = try vault.append(text: trimmed, asLink: false, settings: settings)
            confirm(String(localized: "capture.saved", defaultValue: "In Daily gespeichert"))
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Capture the frontmost browser tab as a markdown link.
    func captureBrowserPage() {
        do {
            _ = try vault.appendCurrentBrowserPage(settings: settings)
            confirm(String(localized: "capture.savedLink", defaultValue: "Link gespeichert"))
        } catch {
            report(error)
        }
    }

    // MARK: - Feedback

    private func confirm(_ title: String) {
        Haptics.perform(.generic)
        activities?.present(NotchActivity(
            kind: .fileReceived, priority: 2,
            icon: "tray.and.arrow.down.fill", tint: .green,
            title: title, autoDismiss: 1.8))
    }

    private func report(_ error: Error) {
        NSLog("NotchMate: capture failed: \(error)")
        activities?.present(NotchActivity(
            kind: .fileReceived, priority: 2,
            icon: "exclamationmark.triangle.fill", tint: .orange,
            title: String(localized: "capture.failed", defaultValue: "Capture fehlgeschlagen"),
            autoDismiss: 2))
    }

    private func applyHotKeySetting() {
        if settings.captureHotkeyEnabled {
            hotKey.register()
        } else {
            hotKey.unregister()
        }
    }
}
