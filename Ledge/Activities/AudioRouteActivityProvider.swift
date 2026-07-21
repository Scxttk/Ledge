import CoreAudio
import SwiftUI

/// Emits an activity when the default audio output device changes (e.g. AirPods
/// connect). Uses a CoreAudio property listener — no polling.
final class AudioRouteActivityProvider {
    var onActivity: ((NotchActivity) -> Void)?

    private var lastDeviceID: AudioDeviceID = 0
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        lastDeviceID = currentOutputDevice()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleChange() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    func stop() {
        if let listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listenerBlock
            )
        }
        listenerBlock = nil
    }

    private func handleChange() {
        let device = currentOutputDevice()
        guard device != 0, device != lastDeviceID else { return }
        lastDeviceID = device

        let name = deviceName(device)
        let isAirPods = name.localizedCaseInsensitiveContains("AirPods")
        let isHeadphones = isAirPods || name.localizedCaseInsensitiveContains("Kopfhörer")
            || name.localizedCaseInsensitiveContains("Headphone")
        let icon = Self.icon(for: name, isAirPods: isAirPods, isHeadphones: isHeadphones)

        func activity(detail: String?) -> NotchActivity {
            // Higher priority than the volume HUD (3) so connecting AirPods — which
            // also nudges the volume — isn't instantly overlaid by the volume bar.
            NotchActivity(kind: .audioRoute, priority: 5, icon: icon, tint: .white,
                          title: name, autoDismiss: 4, detail: detail)
        }

        // Show the route immediately; fetching the battery takes a beat.
        onActivity?(activity(detail: nil))

        guard isAirPods else { return }
        let connectedAt = Date()
        BluetoothBattery.fetchAirPods { [weak self] levels in
            guard let self, let percent = levels?.representative else { return }
            // Only fold the battery in if it arrived while the pill is still up,
            // so it doesn't pop back on screen seconds after connecting.
            guard Date().timeIntervalSince(connectedAt) < 3 else { return }
            self.onActivity?(activity(detail: "\(percent)%"))
        }
    }

    private static func icon(for name: String, isAirPods: Bool, isHeadphones: Bool) -> String {
        guard isAirPods else { return isHeadphones ? "headphones" : "hifispeaker.fill" }
        if name.localizedCaseInsensitiveContains("Max") { return "airpodsmax" }
        if name.localizedCaseInsensitiveContains("Pro") { return "airpodspro" }
        return "airpods"
    }

    private func currentOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    private func deviceName(_ device: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name)
        if status == noErr, let name {
            return name.takeRetainedValue() as String
        }
        return "Audio"
    }
}
