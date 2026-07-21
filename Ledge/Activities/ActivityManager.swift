import SwiftUI

/// Owns the currently displayed live activity, applies priority, and auto-dismisses.
/// System providers (battery, audio route) and app events (file received) call
/// `present(_:)`; the collapsed pill observes `current`.
final class ActivityManager: ObservableObject {
    @Published private(set) var current: NotchActivity?

    private var dismissWork: DispatchWorkItem?
    private let settings: UserSettings
    private let battery = BatteryActivityProvider()
    private let audioRoute = AudioRouteActivityProvider()

    init(settings: UserSettings = .shared) {
        self.settings = settings
    }

    func start() {
        battery.onActivity = { [weak self] in self?.present($0) }
        audioRoute.onActivity = { [weak self] in self?.present($0) }
        battery.start()
        audioRoute.start()
    }

    func stop() {
        battery.stop()
        audioRoute.stop()
    }

    /// Present an activity unless a higher-priority one is already showing.
    func present(_ activity: NotchActivity) {
        guard settings.liveActivitiesEnabled else { return }
        if let current, current.priority > activity.priority { return }
        withAnimation(NotchLayout.islandMorphAnimation) {
            current = activity
        }
        scheduleDismiss(after: activity.autoDismiss)
    }

    func dismiss() {
        dismissWork?.cancel()
        withAnimation(NotchLayout.islandMorphAnimation) {
            current = nil
        }
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: App-driven activities

    /// Called when files are dropped onto the shelf.
    func fileReceived(count: Int) {
        let title = count == 1
            ? String(localized: "activity.fileReceived.one", defaultValue: "1 Datei abgelegt")
            : String(localized: "activity.fileReceived.many", defaultValue: "\(count) Dateien abgelegt")
        present(NotchActivity(kind: .fileReceived, priority: 1, icon: "tray.and.arrow.down.fill", tint: .cyan, title: title, autoDismiss: 2))
    }
}
