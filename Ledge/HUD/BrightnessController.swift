import CoreGraphics
import Foundation

/// Reads and sets the built-in display's brightness via the **private**
/// `DisplayServices` framework. There is no public API for this on modern macOS,
/// so we resolve the symbols dynamically with `dlopen`/`dlsym`: if Apple changes
/// or removes them in a future release, `isAvailable` simply becomes false and the
/// feature degrades (the system keeps handling the brightness keys) instead of
/// crashing. Built-in display only — external monitors use DDC/CI, out of scope.
final class BrightnessController {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let handle: UnsafeMutableRawPointer?
    private let getFn: GetBrightness?
    private let setFn: SetBrightness?

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getFn = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetBrightness.self) }
        setFn = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetBrightness.self) }
    }

    /// True when the private symbols resolved *and* a brightness read succeeds on
    /// the built-in display — i.e. it's safe to intercept the brightness keys.
    var isAvailable: Bool {
        getFn != nil && setFn != nil && current() != nil
    }

    /// Current brightness 0...1, or nil if it can't be read.
    func current() -> Double? {
        guard let getFn, let display = builtInDisplay() else { return nil }
        var level: Float = 0
        guard getFn(display, &level) == 0 else { return nil }
        return Double(level)
    }

    /// Adjust brightness by `delta`, clamped to 0...1. Returns the new level (for
    /// the HUD), or nil if unavailable.
    @discardableResult
    func change(by delta: Double) -> Double? {
        guard let setFn, let display = builtInDisplay(), let level = current() else { return nil }
        let target = min(max(level + delta, 0), 1)
        _ = setFn(display, Float(target))
        return target
    }

    private func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    deinit {
        if let handle { dlclose(handle) }
    }
}
