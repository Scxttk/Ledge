import AppKit
import ApplicationServices
import CoreGraphics

/// Captures the hardware volume keys system-wide so macOS never draws its own
/// volume OSD — Ledge handles the change and shows its own HUD instead.
///
/// Works via a `CGEvent` tap on `NSSystemDefined` events, which requires the
/// **Accessibility** permission (unlike the Carbon capture hotkey). When a volume
/// key is pressed we consume the event (so nothing reaches the system) and invoke
/// the matching callback; the caller adjusts CoreAudio and presents the notch HUD.
final class MediaKeyTap {
    /// Called on the main thread when a volume key is pressed. `fine` is true when
    /// Shift+Option is held (quarter-step adjustment, matching macOS).
    var onVolumeUp: ((_ fine: Bool) -> Void)?
    var onVolumeDown: ((_ fine: Bool) -> Void)?
    var onMute: (() -> Void)?
    var onBrightnessUp: ((_ fine: Bool) -> Void)?
    var onBrightnessDown: ((_ fine: Bool) -> Void)?

    /// Only swallow the brightness keys when brightness control actually works;
    /// otherwise pass them through so the system keeps handling them.
    var handlesBrightness = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // NX_KEYTYPE_* key codes (IOKit `ev_keymap.h`).
    private static let soundUp = 0
    private static let soundDown = 1
    private static let brightnessUp = 2
    private static let brightnessDown = 3
    private static let mute = 7
    // NX_SYSDEFINED event type (not a named CGEventType case) and the
    // aux-control-buttons subtype.
    private static let sysDefinedType: UInt32 = 14
    private static let auxButtonSubtype = 8

    var isRunning: Bool { eventTap != nil }

    /// Whether Ledge is trusted for Accessibility. Pass `prompt: true` to show
    /// the system prompt (opens System Settings) when it isn't.
    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Returns whether the tap is (now) running. Fails if Accessibility is denied.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    deinit { stop() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that blocks too long; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.sysDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              Int(nsEvent.subtype.rawValue) == Self.auxButtonSubtype else {
            return Unmanaged.passUnretained(event)
        }
        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0x0000FF00) >> 8
        let isDown = keyState == 0x0A

        switch keyCode {
        case Self.soundUp, Self.soundDown, Self.mute:
            break
        case Self.brightnessUp, Self.brightnessDown:
            guard handlesBrightness else { return Unmanaged.passUnretained(event) }
        default:
            return Unmanaged.passUnretained(event) // not a key we own — pass through
        }
        // We own this key: consume both down and up so nothing leaks to the system.
        guard isDown else { return nil }

        let fine = nsEvent.modifierFlags.contains(.shift) && nsEvent.modifierFlags.contains(.option)
        switch keyCode {
        case Self.soundUp: onVolumeUp?(fine)
        case Self.soundDown: onVolumeDown?(fine)
        case Self.mute: onMute?()
        case Self.brightnessUp: onBrightnessUp?(fine)
        case Self.brightnessDown: onBrightnessDown?(fine)
        default: break
        }
        return nil
    }
}
