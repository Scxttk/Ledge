import Combine
import CoreAudio
import SwiftUI

/// Surfaces system volume changes as an in-notch HUD activity (reusing the
/// live-activity engine). Gated by `UserSettings.hudEnabled`.
///
/// Volume uses public CoreAudio APIs and works reliably. Brightness observation
/// requires the private `DisplayServices` framework on modern macOS and is
/// intentionally left out rather than shipping fragile private-API code; the
/// HUD is structured so a brightness provider can be added later.
///
/// When `UserSettings.suppressSystemOSD` is on, NotchMate captures the hardware
/// volume keys (`MediaKeyTap`, needs Accessibility), adjusts the volume itself and
/// shows only the notch HUD — so Apple's own OSD never appears. Without the
/// permission (or with the option off) the notch HUD is shown additively and the
/// system OSD still appears.
final class SystemHUD: NSObject {
    private let volume = VolumeHUDProvider()
    private let brightness = BrightnessController()
    private let keyTap = MediaKeyTap()
    private let settings: UserSettings
    private weak var activities: ActivityManager?
    private var cancellables = Set<AnyCancellable>()
    /// True once we're intercepting the hardware volume keys. While intercepting,
    /// only our own key presses show the HUD — external CoreAudio volume changes
    /// (notably AirPods' constant scalar drift) are ignored so the HUD doesn't
    /// pop on its own.
    private var interceptingKeys = false

    /// macOS adjusts volume/brightness in 1/16 steps; Shift+Option gives quarter steps.
    private static let volumeStep = 1.0 / 16.0

    init(settings: UserSettings = .shared) {
        self.settings = settings
        super.init()
    }

    func start(presenting activities: ActivityManager) {
        self.activities = activities
        volume.onChange = { [weak self] level, muted, userInitiated in
            guard let self, self.settings.hudEnabled else { return }
            // While we own the volume keys, only *our* key presses show the HUD.
            // External changes (AirPods report constant scalar drift on their
            // own) would otherwise pop it nonstop. When not intercepting, mirror
            // any change additively as before.
            if self.interceptingKeys && !userInitiated { return }
            self.activities?.present(NotchActivity(
                kind: .timer,            // generic HUD slot
                priority: 3,
                icon: Self.volumeIcon(level: level, muted: muted),
                tint: .white,
                title: "",
                autoDismiss: 1.5,
                progress: muted ? 0 : level
            ))
        }
        volume.start()

        keyTap.onVolumeUp = { [weak self] fine in self?.volume.changeVolume(by: Self.step(fine: fine)) }
        keyTap.onVolumeDown = { [weak self] fine in self?.volume.changeVolume(by: -Self.step(fine: fine)) }
        keyTap.onMute = { [weak self] in self?.volume.toggleMute() }
        keyTap.onBrightnessUp = { [weak self] fine in self?.adjustBrightness(by: Self.step(fine: fine)) }
        keyTap.onBrightnessDown = { [weak self] fine in self?.adjustBrightness(by: -Self.step(fine: fine)) }

        // Re-arm key interception whenever either relevant setting flips.
        // `combineLatest` emits immediately, so this also does the initial setup.
        settings.$hudEnabled
            .combineLatest(settings.$suppressSystemOSD)
            .sink { [weak self] _ in self?.updateKeyInterception() }
            .store(in: &cancellables)

        // Start the tap the moment the user grants Accessibility (no relaunch).
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSNotification.Name("com.apple.accessibility.api"), object: nil
        )
    }

    @objc private func accessibilityChanged() {
        // The setting flips slightly before the trust check reflects it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateKeyInterception()
        }
    }

    func stop() {
        volume.stop()
        keyTap.stop()
        cancellables.removeAll()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Start/stop the hardware-key interception based on settings + permission.
    private func updateKeyInterception() {
        guard settings.hudEnabled, settings.suppressSystemOSD else {
            keyTap.stop()
            interceptingKeys = false
            return
        }
        // Capturing the keys needs Accessibility. Prompt once; if it isn't granted
        // yet, fall back to the additive HUD (system OSD still shows) until the user
        // grants it and toggles the option again (or relaunches).
        guard MediaKeyTap.hasAccessibilityPermission(prompt: true) else {
            keyTap.stop()
            interceptingKeys = false
            return
        }
        // Only intercept the brightness keys if brightness control actually works
        // (private DisplayServices resolved + readable); otherwise leave them to macOS.
        keyTap.handlesBrightness = brightness.isAvailable
        interceptingKeys = keyTap.start()
    }

    /// Set brightness via the private controller and show the notch HUD directly
    /// (there is no brightness-change listener as there is for volume).
    private func adjustBrightness(by delta: Double) {
        guard settings.hudEnabled, let level = brightness.change(by: delta) else { return }
        activities?.present(NotchActivity(
            kind: .timer,
            priority: 3,
            icon: level < 0.01 ? "sun.min.fill" : "sun.max.fill",
            tint: .white,
            title: "",
            autoDismiss: 1.5,
            progress: level
        ))
    }

    private static func step(fine: Bool) -> Double {
        fine ? volumeStep / 4 : volumeStep
    }

    private static func volumeIcon(level: Double, muted: Bool) -> String {
        if muted || level < 0.01 { return "speaker.slash.fill" }
        switch level {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// Listens to (and drives) the default output device's volume and mute state,
/// re-attaching when the default device changes. No polling — CoreAudio property
/// listeners only.
private final class VolumeHUDProvider {
    /// Reports the current scalar volume and mute state on the main thread.
    /// `userInitiated` is true when the change came from the app's own key
    /// handling (vs. an external CoreAudio change like AirPods' scalar drift).
    var onChange: ((_ level: Double, _ muted: Bool, _ userInitiated: Bool) -> Void)?

    private var device: AudioDeviceID = 0
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    /// Level at the last HUD we actually showed. Jitter is measured against this
    /// (not the last raw read) so oscillation around a stable point never
    /// accumulates past the threshold.
    private var lastReportedLevel: Double = -1
    private var lastMuted = false
    /// Minimum volume change (listener-driven) before the HUD shows — a bit under
    /// one macOS step (1/16 ≈ 0.0625). AirPods report sub-step scalar jitter of
    /// their own accord (~0.01); without this floor the HUD popped constantly
    /// even when nobody touched the volume. Key presses bypass it via `force`.
    private static let minReportDelta = 0.04
    /// Reports before this instant are swallowed (level/mute tracked, but no HUD).
    /// Set briefly after the default device changes: switching output (AirPods
    /// connecting, unplugging headphones) makes CoreAudio report the *new*
    /// device's volume, which isn't a change the user made — showing the HUD then
    /// is the "volume bar opens on its own" bug. User key presses bypass this via
    /// `report(force:)`.
    private var suppressUntil = Date.distantPast
    /// The first attach (at start) must not arm suppression — only real switches.
    private var didInitialAttach = false
    /// Volume elements we attached a listener to, so we can remove exactly those.
    private var watchedElements: [AudioObjectPropertyElement] = []
    private var watchesMute = false

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        attachToDefaultDevice()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.attachToDefaultDevice() }
        }
        defaultListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, DispatchQueue.main, block
        )
    }

    func stop() {
        detachDeviceListeners()
        if let defaultListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, DispatchQueue.main, defaultListener
            )
        }
        defaultListener = nil
    }

    // MARK: Driving volume / mute

    /// Adjust the scalar volume by `delta`, clamped to 0...1, unmuting first so a
    /// volume-up while muted behaves like macOS.
    func changeVolume(by delta: Double) {
        guard device != 0 else { return }
        if readMute() { setMute(false) }
        let target = min(max(readVolume() + delta, 0), 1)
        setVolume(target)
    }

    func toggleMute() {
        guard device != 0 else { return }
        setMute(!readMute())
    }

    private func setVolume(_ level: Double) {
        var value = Float32(min(max(level, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        // Prefer the virtual main element; fall back to per-channel for devices
        // (e.g. built-in speakers) that expose no settable master scalar.
        var main = volumeAddress(element: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &main),
           AudioObjectIsPropertySettable(device, &main, &settable) == noErr, settable.boolValue {
            AudioObjectSetPropertyData(device, &main, 0, nil, size, &value)
        } else {
            for channel in UInt32(1)...UInt32(2) {
                var addr = volumeAddress(element: channel)
                var chSettable: DarwinBoolean = false
                if AudioObjectHasProperty(device, &addr),
                   AudioObjectIsPropertySettable(device, &addr, &chSettable) == noErr, chSettable.boolValue {
                    AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value)
                }
            }
        }
        // Setting fires the listener, but nudge in case the value didn't change
        // (e.g. already at a limit) so the HUD still shows. Forced: a key press
        // must show even inside a device-switch suppression window.
        report(force: true)
    }

    private func setMute(_ muted: Bool) {
        guard AudioObjectHasProperty(device, &muteAddress) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &muteAddress, &settable) == noErr, settable.boolValue else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        report(force: true)
    }

    private func readMute() -> Bool {
        guard AudioObjectHasProperty(device, &muteAddress) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    // MARK: Attach / detach

    private func attachToDefaultDevice() {
        detachDeviceListeners()
        device = currentDefaultDevice()
        guard device != 0 else { return }
        lastReportedLevel = readVolume()
        lastMuted = readMute()
        // Swallow the burst of volume reports that follows a device switch.
        if didInitialAttach { suppressUntil = Date().addingTimeInterval(0.8) }
        didInitialAttach = true

        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.report() }
        }
        deviceListener = volumeBlock
        // Built-in speakers often expose no master (Main) volume scalar — only
        // per-channel — so a listener on the Main element alone never fires.
        // Attach to every element that actually has the property (Main + L/R).
        for element in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
            var address = volumeAddress(element: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, volumeBlock)
            watchedElements.append(element)
        }

        if AudioObjectHasProperty(device, &muteAddress) {
            let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async { self?.report() }
            }
            muteListener = muteBlock
            AudioObjectAddPropertyListenerBlock(device, &muteAddress, DispatchQueue.main, muteBlock)
            watchesMute = true
        }
    }

    private func detachDeviceListeners() {
        if device != 0, let deviceListener {
            for element in watchedElements {
                var address = volumeAddress(element: element)
                AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, deviceListener)
            }
        }
        if device != 0, watchesMute, let muteListener {
            AudioObjectRemovePropertyListenerBlock(device, &muteAddress, DispatchQueue.main, muteListener)
        }
        watchedElements.removeAll()
        watchesMute = false
        deviceListener = nil
        muteListener = nil
    }

    /// Read the current level + mute and notify if either changed. `force`
    /// (used by the app's own key-driven changes) bypasses the post-device-switch
    /// suppression so the user's volume presses always show the HUD.
    private func report(force: Bool = false) {
        let level = readVolume()
        guard level >= 0 else { return }
        let muted = readMute()
        let bigEnough = abs(level - lastReportedLevel) >= Self.minReportDelta
        let muteChanged = muted != lastMuted
        // Ignore CoreAudio's sub-step scalar jitter (AirPods report it on their
        // own); only a real step-sized change, a mute toggle, or a user key
        // press (force) surfaces the HUD.
        guard force || bigEnough || muteChanged else { return }
        // Track the new baseline but stay silent during the device-switch window.
        guard force || Date() >= suppressUntil else {
            lastReportedLevel = level
            lastMuted = muted
            return
        }
        lastReportedLevel = level
        lastMuted = muted
        onChange?(level, muted, force)
    }

    private func currentDefaultDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &id
        )
        return status == noErr ? id : 0
    }

    /// Reads the virtual main volume, falling back to averaging the first two
    /// channels for devices without a master element.
    private func readVolume() -> Double {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = volumeAddress(element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &addr),
           AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
            return Double(value)
        }
        var sum: Float32 = 0
        var count: Float32 = 0
        for channel in UInt32(1)...UInt32(2) {
            var chAddr = volumeAddress(element: channel)
            var v = Float32(0)
            var s = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(device, &chAddr),
               AudioObjectGetPropertyData(device, &chAddr, 0, nil, &s, &v) == noErr {
                sum += v
                count += 1
            }
        }
        return count > 0 ? Double(sum / count) : -1
    }
}
