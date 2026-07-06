import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NotchWindowController?
    private var statusBarController: StatusBarController?

    let viewModel = NotchViewModel()
    let nowPlaying = NowPlayingManager()
    let shelf = FileShelfModel()
    let activities = ActivityManager()
    let systemHUD = SystemHUD()
    /// Shared audio-spectrum tap. Long-lived (not owned by the music tab) so the
    /// collapsed pill's wave can show the real spectrum too; its lifecycle is
    /// driven centrally in `NotchRootView` off playback + screen state.
    let spectrum = SpectrumAnalyzer(bandCount: 5)
    lazy var capture = ObsidianCapture(activities: activities)
    lazy var pomodoro = PomodoroManager(activities: activities)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no Dock icon, lives in the menu bar / notch.
        NSApp.setActivationPolicy(.accessory)
        applyAppearance(UserSettings.shared.appearance)

        let controller = NotchWindowController(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, activities: activities, pomodoro: pomodoro, capture: capture, spectrum: spectrum)
        controller.show()
        windowController = controller

        statusBarController = StatusBarController()

        enableLaunchAtLogin()

        capture.onHotKey = { [weak self] in self?.windowController?.presentCapture() }
        capture.start()

        nowPlaying.start()
        activities.start()
        systemHUD.start(presenting: activities)

        // Keep the thumbnail cache from growing without bound across launches.
        DispatchQueue.global(qos: .utility).async {
            Persistence.pruneThumbnailCache()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resetData),
            name: .notchMateResetData,
            object: nil
        )
        registerSleepWakeObservers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
        activities.stop()
        systemHUD.stop()
        spectrum.stop()
        capture.stop()
        // Session state is already persisted on every transition; just disarm
        // the 1s tick. The wall-clock session resumes on the next launch.
        pomodoro.suspendTicking()
    }

    // MARK: - Sleep/Wake

    /// Tear down every live listener/monitor when the machine sleeps and rebuild
    /// them on wake. Without this the 1s now-playing timer, the CoreAudio/IOKit
    /// listeners and the global hover monitors stay armed through sleep — the
    /// crash/drain class reported against every competing notch app.
    private func registerSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
        // Screen sleep is *not* system sleep: the machine stays awake, so our
        // timers/observers keep running. Pause the per-second now-playing work and
        // the visualizer while the display is off — nobody can see it, and a
        // free-running 30fps visualizer is the documented idle-drain of these apps.
        center.addObserver(self, selector: #selector(screensDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private func systemWillSleep() {
        nowPlaying.stop()
        activities.stop()
        systemHUD.stop()
        spectrum.stop()
        pomodoro.suspendTicking()
        windowController?.suspendMonitors()
    }

    @objc private func systemDidWake() {
        nowPlaying.start()
        activities.start()
        systemHUD.start(presenting: activities)
        pomodoro.resumeTicking()
        windowController?.resumeMonitors()
    }

    @objc private func screensDidSleep() {
        nowPlaying.setScreensAwake(false)
        pomodoro.setScreensAwake(false)
    }

    @objc private func screensDidWake() {
        nowPlaying.setScreensAwake(true)
        pomodoro.setScreensAwake(true)
    }

    @objc private func screenParametersChanged() {
        windowController?.reposition()
    }

    @objc private func resetData() {
        shelf.clear()
        nowPlaying.clearFavorites()
        pomodoro.clear()
    }

    /// Register NotchMate as a login item so it starts automatically at every login.
    private func enableLaunchAtLogin() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("NotchMate: could not enable launch at login: \(error)")
        }
    }
}
