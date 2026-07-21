import AppKit

/// Thin wrapper around the Force Touch trackpad's haptic feedback.
/// No-op on devices without a haptic trackpad.
enum Haptics {
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }
}
