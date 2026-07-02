import Foundation

/// Best-effort AirPods battery readout. macOS has no public API for Bluetooth
/// accessory battery, so we parse `system_profiler SPBluetoothDataType -json`.
/// It's a heavyweight process call, so this only runs **once** when AirPods
/// connect (event-driven, never polled) and off the main thread.
enum BluetoothBattery {
    struct Levels: Equatable {
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        var main: Int?

        /// A single number to surface in the pill: the lower earbud (what runs out
        /// first), else a single-unit "main", else the case.
        var representative: Int? {
            [left, right].compactMap { $0 }.min() ?? main ?? caseLevel
        }
    }

    static func fetchAirPods(completion: @escaping (Levels?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let levels = readAirPods()
            DispatchQueue.main.async { completion(levels) }
        }
    }

    private static func readAirPods() -> Levels? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }

        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry where name.localizedCaseInsensitiveContains("AirPods") {
                    guard let info = value as? [String: Any] else { continue }
                    let levels = Levels(
                        left: percent(info["device_batteryLevelLeft"]),
                        right: percent(info["device_batteryLevelRight"]),
                        caseLevel: percent(info["device_batteryLevelCase"]),
                        main: percent(info["device_batteryLevelMain"])
                    )
                    if levels.representative != nil { return levels }
                }
            }
        }
        return nil
    }

    /// Parses values like `"80%"` into `80`.
    private static func percent(_ value: Any?) -> Int? {
        guard let string = value as? String else { return nil }
        return Int(string.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }
}
