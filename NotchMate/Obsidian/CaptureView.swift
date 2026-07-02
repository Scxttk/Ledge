import SwiftUI

/// The Quick Capture surface inside the expanded notch: a one-line field that
/// appends to today's daily note, plus a button to capture the frontmost
/// browser tab as a link. Focus is locked while typing so the island won't
/// auto-collapse out from under the cursor.
struct CaptureView: View {
    @ObservedObject var capture: ObsidianCapture
    @ObservedObject var viewModel: NotchViewModel
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

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
        .onChange(of: viewModel.captureFocusToken) { _, _ in fieldFocused = true }
        .onChange(of: fieldFocused) { _, focused in viewModel.isInteractionLocked = focused }
        .onAppear { fieldFocused = true }
        .onDisappear { viewModel.isInteractionLocked = false }
    }

    private var captureField: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))

                TextField(
                    String(localized: "capture.placeholder", defaultValue: "Schnelle Notiz …"),
                    text: $text
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit(submit)

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

            Text(String(localized: "capture.hint", defaultValue: "→ heutige Daily Note"))
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: 340)   // keep the pill compact instead of spanning the notch
        .padding(.horizontal, 30)
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
