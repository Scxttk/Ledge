import AppKit

/// Plain-file debug log for the Claude tab (`~/notchmate_claude_debug.log`).
/// Same rationale as `NotchWindowController.debugLog`: the unified log redacts
/// dynamic substitutions, so NSLog lines are useless for diagnosing this.
enum ClaudeDebugLog {
    /// Flip to true when diagnosing delivery/usage problems (same convention
    /// as `NotchWindowController.debugHoverLogging`).
    static let enabled = false

    static func write(_ message: String) {
        guard enabled else { return }
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/notchmate_claude_debug.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Drives the running Claude desktop-app session: there is no API for
/// switching model/effort/mode, so the shifter delivers `/model …` +
/// `/effort …` (or Shift+Tab for the permission mode) into the app's composer.
///
/// Delivery is pure CGEvent (synthetic mouse + keyboard), **not** AppleScript
/// UI scripting: Electron exposes no usable accessibility tree, so System
/// Events' `click at` silently hit nothing (`missing value`) and keystrokes
/// only landed when the composer happened to still have focus. Synthetic
/// events don't care about the AX tree — the click really lands on the pixel.
/// Sequence per command: click into the composer strip (bottom-centre of the
/// frontmost Claude window, frame from the window server) → clear it (⌘A, ⌫)
/// → paste the whole command (⌘V, atomic — per-character typing raced the
/// slash-command popup) → return. Requires the Accessibility permission
/// Ledge already holds for the volume-key tap.
///
/// The app cannot *read* the session's real state, so the last gear/mode sent
/// is remembered locally (UserDefaults) purely as a display hint.
final class ClaudeSessionDriver: ObservableObject {
    static let bundleID = "com.anthropic.claudefordesktop"

    /// Permission modes in Shift+Tab cycle order, as shown on the mode button.
    static let modes: [String] = [
        String(localized: "claude.mode.default", defaultValue: "Default"),
        String(localized: "claude.mode.autoAccept", defaultValue: "Auto-Accept"),
        String(localized: "claude.mode.plan", defaultValue: "Plan"),
    ]

    @Published private(set) var currentModel: String? {
        didSet { UserDefaults.standard.set(currentModel, forKey: "claudeShifterModel") }
    }
    @Published private(set) var currentEffort: String? {
        didSet { UserDefaults.standard.set(currentEffort, forKey: "claudeShifterEffort") }
    }
    @Published private(set) var modeIndex: Int {
        didSet { UserDefaults.standard.set(modeIndex, forKey: "claudeShifterMode") }
    }

    var currentMode: String { Self.modes[modeIndex % Self.modes.count] }

    /// Whether Claude.app is installed at all — hides the shifter otherwise.
    static var isClaudeAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Serialises deliveries so quick successive gear changes queue up instead
    /// of interleaving their clicks and keystrokes.
    private let deliveryQueue = DispatchQueue(label: "com.scott.notchmate.claude-driver", qos: .userInitiated)

    init() {
        let defaults = UserDefaults.standard
        currentModel = defaults.string(forKey: "claudeShifterModel")
        currentEffort = defaults.string(forKey: "claudeShifterEffort")
        modeIndex = defaults.integer(forKey: "claudeShifterMode")
    }

    /// Engage a gear: deliver `/model <model>` and `/effort <effort>`.
    func setGear(model: String, effort: String) {
        currentModel = model
        currentEffort = effort
        let commands = ["/model \(model)", "/effort \(effort)"]
        deliveryQueue.async { Self.deliver(commands: commands) }
    }

    /// Shift+Tab: cycle Default → Auto-Accept → Plan.
    func cycleMode() {
        modeIndex = (modeIndex + 1) % Self.modes.count
        deliveryQueue.async {
            Self.deliver(commands: []) {
                // Shift+Tab needs composer focus too, so it runs through the
                // same click-first path as a command, just without text.
                Self.clickComposerAndFocus()
                Self.keyStroke(Self.keyTab, flags: .maskShift)
            }
        }
    }

    /// Reset the locally remembered mode display (long-press on the button) —
    /// the real session state is unknowable, so the user can re-sync the label.
    func resetModeDisplay() {
        modeIndex = 0
    }

    // MARK: - Delivery (runs on deliveryQueue)

    private static func deliver(commands: [String], extra: (() -> Void)? = nil) {
        ClaudeDebugLog.write("deliver \(commands) axTrusted=\(AXIsProcessTrusted())")
        guard activateClaude() else {
            ClaudeDebugLog.write("Claude.app could not be activated")
            return
        }
        // Route text through the clipboard; put the user's content back after.
        let savedClipboard = onMain { NSPasteboard.general.string(forType: .string) }
        for command in commands {
            guard clickComposerAndFocus() else { return }
            // Clear leftovers (an earlier failed run may have stranded text).
            keyStroke(keyA, flags: .maskCommand)
            usleep(120_000)
            keyStroke(keyDelete)
            usleep(250_000)
            onMain {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            usleep(120_000)
            keyStroke(keyV, flags: .maskCommand)
            // Let the slash-command popup resolve the pasted command before
            // the return, or the return gets swallowed.
            usleep(700_000)
            keyStroke(keyReturn)
            // Let the command execute before the next one re-clicks the
            // composer (running a command moves the keyboard focus away).
            usleep(1_200_000)
        }
        extra?()
        if let savedClipboard {
            onMain {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(savedClipboard, forType: .string)
            }
        }
        ClaudeDebugLog.write("deliver done")
    }

    /// Bring Claude to the front and wait until it actually is.
    private static func activateClaude() -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if let running {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            return false
        }
        for _ in 0..<50 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                usleep(300_000)  // give the key window a beat to settle
                return true
            }
            usleep(100_000)
        }
        ClaudeDebugLog.write("Claude never became frontmost")
        return false
    }

    /// Synthetic click into the composer strip of Claude's frontmost window,
    /// then a settle pause — the Electron webview takes ~a second to route
    /// click focus into the input.
    @discardableResult
    private static func clickComposerAndFocus() -> Bool {
        guard let frame = frontWindowFrame() else {
            ClaudeDebugLog.write("no Claude window found")
            return false
        }
        let point = CGPoint(
            x: frame.midX,
            y: frame.maxY - CGFloat(NotchLayout.claudeComposerBottomOffset)
        )
        ClaudeDebugLog.write("click composer at \(Int(point.x)),\(Int(point.y)) window=\(Int(frame.width))x\(Int(frame.height))")
        postMouse(.leftMouseDown, at: point)
        usleep(60_000)
        postMouse(.leftMouseUp, at: point)
        usleep(useconds_t(NotchLayout.claudeComposerClickDelay * 1_000_000))
        return true
    }

    /// Frontmost on-screen window of the Claude process, in global top-left
    /// coordinates (same space CGEvent clicks use). From the window server —
    /// no accessibility tree involved.
    private static func frontWindowFrame() -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in windows {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            // Skip tiny auxiliary windows (tooltips, status items).
            if frame.width > 300, frame.height > 200 { return frame }
        }
        return nil
    }

    // MARK: - Synthetic events

    private static let keyA: CGKeyCode = 0
    private static let keyV: CGKeyCode = 9
    private static let keyReturn: CGKeyCode = 36
    private static let keyTab: CGKeyCode = 48
    private static let keyDelete: CGKeyCode = 51

    private static func keyStroke(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    private static func postMouse(_ type: CGEventType, at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Run a pasteboard interaction on the main thread (we're on the delivery
    /// queue here) and hand its value back.
    private static func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }
}
