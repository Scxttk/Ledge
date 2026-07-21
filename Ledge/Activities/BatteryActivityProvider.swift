import IOKit.ps
import SwiftUI

/// Watches the power source and emits an activity when the charger is plugged
/// in or removed. Uses IOKit power-source run-loop notifications (no polling).
final class BatteryActivityProvider {
    var onActivity: ((NotchActivity) -> Void)?

    private var runLoopSource: CFRunLoopSource?
    /// nil until the first reading, so we don't fire an activity at launch.
    private var lastCharging: Bool?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            Unmanaged<BatteryActivityProvider>.fromOpaque(ctx).takeUnretainedValue().evaluate()
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        evaluate()   // establish the baseline state
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
    }

    private func evaluate() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any]
        else { return }

        let state = desc[kIOPSPowerSourceStateKey] as? String
        let charging = (state == kIOPSACPowerValue)
        let level = desc[kIOPSCurrentCapacityKey] as? Int ?? 0

        defer { lastCharging = charging }
        guard let previous = lastCharging, previous != charging else { return }

        let activity = charging
            ? NotchActivity(kind: .charging, priority: 2, icon: "bolt.fill", tint: .green,
                            title: "\(level)%", autoDismiss: 3)
            : NotchActivity(kind: .battery, priority: 2, icon: batterySymbol(level), tint: .white,
                            title: "\(level)%", autoDismiss: 3)
        onActivity?(activity)
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
