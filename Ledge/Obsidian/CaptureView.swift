import AppKit
import SwiftUI

/// The Quick Capture surface inside the expanded notch: a one-line field that
/// appends to today's daily note, framed by the vault name above and quick
/// actions (open in Obsidian / Claude Code terminal) below. Focus is locked
/// while typing so the island won't auto-collapse out from under the cursor.
///
/// AppKit gotcha: SwiftUI's `TextField` is backed by an `NSTextField`, and
/// AppKit views ignore SwiftUI clip shapes — a live field would float over the
/// island's edge during the expand morph and while paging tabs. So the real
/// field is only mounted once this tab is front *and* the slide/morph has
/// settled; until then a pure-SwiftUI look-alike (which clips correctly) is
/// shown in its place.
struct CaptureView: View {
    @ObservedObject var capture: ObsidianCapture
    @ObservedObject var viewModel: NotchViewModel
    @State private var text = ""
    @State private var fieldLive = false
    @State private var vaultDisplayName = ""
    @FocusState private var fieldFocused: Bool

    private var isFront: Bool { viewModel.selectedTab == .capture }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if capture.isConfigured {
                captureField
            } else {
                notConfigured
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.captureFocusToken) { _, _ in activateField() }
        .onChange(of: viewModel.selectedTab) { _, tab in
            if tab == .capture {
                activateField(after: NotchLayout.captureFieldMountDelay)
            } else {
                // Swap the AppKit field out *before* the page slides away, and
                // release focus explicitly — SwiftUI doesn't reliably clear
                // `@FocusState` just because the focused view left the hierarchy,
                // which otherwise left `isInteractionLocked` stuck `true` forever
                // and silently disabled auto-collapse.
                fieldLive = false
                fieldFocused = false
                viewModel.isInteractionLocked = false
            }
        }
        .onChange(of: fieldFocused) { _, focused in viewModel.isInteractionLocked = focused }
        .onAppear {
            vaultDisplayName = Self.resolveVaultName()
            if isFront { activateField(after: NotchLayout.captureFieldMountDelay) }
        }
        .onDisappear {
            fieldLive = false
            viewModel.isInteractionLocked = false
        }
    }

    private var captureField: some View {
        VStack(spacing: 8) {
            // Above the pill: which vault this lands in.
            HStack(spacing: 5) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 9))
                Text(vaultDisplayName)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.4))

            pill
                .frame(maxWidth: 260)

            // Below the pill: destination hint + shortcuts (moved here from the
            // island's top-right corner).
            HStack(spacing: 12) {
                Text(String(localized: "capture.hint", defaultValue: "→ heutige Daily Note"))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                Circle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 2.5, height: 2.5)
                CaptureIconButton(systemName: "diamond", help: String(localized: "capture.open", defaultValue: "In Obsidian öffnen")) {
                    openVaultInObsidian()
                }
                QuickLaunchButton()
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The capsule around the input. While `fieldLive` is false a SwiftUI-only
    /// placeholder stands in for the AppKit-backed `TextField` (see header doc).
    private var pill: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))

            if fieldLive {
                TextField(
                    String(localized: "capture.placeholder", defaultValue: "Schnelle Notiz …"),
                    text: $text
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit(submit)
            } else {
                Text(text.isEmpty ? String(localized: "capture.placeholder", defaultValue: "Schnelle Notiz …") : text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(text.isEmpty ? 0.35 : 1))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            CaptureIconButton(systemName: "safari", help: String(localized: "capture.browser", defaultValue: "Aktuelle Browser-Seite erfassen")) {
                capture.captureBrowserPage()
            }
            CaptureIconButton(systemName: "arrow.up.circle.fill", help: String(localized: "capture.submit", defaultValue: "An Daily Note anhängen"), prominent: true, action: submit)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(fieldFocused ? 0.35 : 0.12), lineWidth: 1))
    }

    private var notConfigured: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.5))
            Text(String(localized: "capture.setup", defaultValue: "Kein Vault konfiguriert.\nEinstellungen → Obsidian"))
                .multilineTextAlignment(.center)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func submit() {
        if capture.capture(text) {
            text = ""
            fieldFocused = true   // stay ready for the next thought
        }
    }

    /// Mount the real text field (optionally once animations settled) and focus it.
    private func activateField(after delay: TimeInterval = 0) {
        let mount = {
            guard isFront else { return }
            fieldLive = true
            fieldFocused = true
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { mount() }
        } else {
            mount()
        }
    }

    private func openVaultInObsidian() {
        let vault = vaultDisplayName
        guard !vault.isEmpty,
              let url = URL(string: "obsidian://open?vault=\(CaptureEscaping.urlEncoded(vault))") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func resolveVaultName() -> String {
        let settings = UserSettings.shared
        if !settings.vaultName.isEmpty { return settings.vaultName }
        if let bookmark = settings.vaultBookmark, let root = Persistence.resolveBookmark(bookmark) {
            return root.lastPathComponent
        }
        return ""
    }
}

private struct CaptureIconButton: View {
    let systemName: String
    var help: String = ""
    var prominent: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 18 : 14))
                .foregroundStyle(prominent ? Color.cyan : .white.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Opens Terminal in the configured Obsidian vault and starts Claude Code, so
/// tasks can be knocked out fast without leaving the notch. Falls back to the
/// home directory when no vault is set.
enum QuickLaunch {
    static var vaultURL: URL? {
        UserSettings.shared.vaultBookmark.flatMap(Persistence.resolveBookmark)
    }

    static func openClaudeInVault() {
        let path = vaultURL?.path ?? NSHomeDirectory()
        // Single-quote for the shell; escape the quotes for the AppleScript string.
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(quoted.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")) && claude"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    /// The real Obsidian app icon if installed, otherwise nil (caller falls back to an SF Symbol).
    static var obsidianIcon: NSImage? {
        let candidates = [
            "/Applications/Obsidian.app",
            "\(NSHomeDirectory())/Applications/Obsidian.app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }
}

struct QuickLaunchButton: View {
    var body: some View {
        Button {
            Haptics.perform(.alignment)
            QuickLaunch.openClaudeInVault()
        } label: {
            Group {
                if let icon = QuickLaunch.obsidianIcon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "terminal")
                        .resizable().scaledToFit()
                        .padding(3)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(String(localized: "capture.claude", defaultValue: "Claude Code im Vault öffnen"))
    }
}
