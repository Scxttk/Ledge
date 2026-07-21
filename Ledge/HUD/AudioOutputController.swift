import CoreAudio
import Foundation

/// One selectable audio output device.
struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

/// Lists the system's audio output devices and switches the default output —
/// the data behind the music tab's output-picker button. CoreAudio property
/// listeners keep the list and current selection live (no polling), so it also
/// reflects AirPods connecting or a device being unplugged.
final class AudioOutputController: ObservableObject {
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var currentDeviceID: AudioDeviceID = 0

    var currentName: String {
        devices.first { $0.id == currentDeviceID }?.name ?? ""
    }

    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    private var defaultAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        reload()
        let system = AudioObjectID(kAudioObjectSystemObject)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.reload() }
        }
        defaultListener = block
        AudioObjectAddPropertyListenerBlock(system, &defaultAddress, DispatchQueue.main, block)
        let listBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.reload() }
        }
        deviceListListener = listBlock
        AudioObjectAddPropertyListenerBlock(system, &deviceListAddress, DispatchQueue.main, listBlock)
    }

    func stop() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let defaultListener {
            AudioObjectRemovePropertyListenerBlock(system, &defaultAddress, DispatchQueue.main, defaultListener)
        }
        if let deviceListListener {
            AudioObjectRemovePropertyListenerBlock(system, &deviceListAddress, DispatchQueue.main, deviceListListener)
        }
        defaultListener = nil
        deviceListListener = nil
    }

    /// Make `device` the system default output.
    func select(_ device: AudioOutputDevice) {
        guard device.id != currentDeviceID else { return }
        var id = device.id
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectSetPropertyData(
            system, &defaultAddress, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        reload()
    }

    // MARK: - Enumeration

    private func reload() {
        devices = Self.outputDevices()
        currentDeviceID = Self.defaultOutputDevice()
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        )
        return status == noErr ? id : 0
    }

    private static func outputDevices() -> [AudioOutputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutput(id) else { return nil }
            return AudioOutputDevice(id: id, name: name(id))
        }
    }

    /// A device is an output if it exposes at least one output stream.
    private static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func name(_ device: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr,
              let name else { return "Audio" }
        return name.takeRetainedValue() as String
    }
}
