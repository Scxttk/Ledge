import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var settings = UserSettings.shared

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label(String(localized: "settings.general", defaultValue: "Allgemein"), systemImage: "gearshape") }

            NowPlayingSettings(settings: settings)
                .tabItem { Label(String(localized: "settings.nowPlaying", defaultValue: "Now Playing"), systemImage: "music.note") }

            FeatureSettings(settings: settings)
                .tabItem { Label(String(localized: "settings.features", defaultValue: "Features"), systemImage: "sparkles") }

            TimerSettings(settings: settings)
                .tabItem { Label(String(localized: "settings.timer", defaultValue: "Timer"), systemImage: "timer") }

            ObsidianSettings(settings: settings)
                .tabItem { Label(String(localized: "settings.obsidian", defaultValue: "Obsidian"), systemImage: "square.and.pencil") }

            DataSettings()
                .tabItem { Label(String(localized: "settings.data", defaultValue: "Daten"), systemImage: "externaldrive") }
        }
        .frame(width: 460, height: 360)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var settings: UserSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle(String(localized: "settings.launchAtLogin", defaultValue: "Bei Anmeldung starten"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    setLaunchAtLogin(enabled)
                }

            Picker(String(localized: "settings.appearance", defaultValue: "Erscheinungsbild"), selection: $settings.appearance) {
                ForEach(UserSettings.Appearance.allCases) { option in
                    Text(option.localizedName).tag(option)
                }
            }
            .onChange(of: settings.appearance) { _, value in applyAppearance(value) }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("NotchMate: launch-at-login toggle failed: \(error)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Apply the chosen appearance to the app (affects the Settings window chrome).
func applyAppearance(_ appearance: UserSettings.Appearance) {
    switch appearance {
    case .system: NSApp.appearance = nil
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    }
}

private struct NowPlayingSettings: View {
    @ObservedObject var settings: UserSettings

    var body: some View {
        Form {
            Picker(String(localized: "settings.mediaSource", defaultValue: "Quelle"), selection: $settings.mediaSource) {
                ForEach(UserSettings.MediaSource.allCases) { source in
                    Text(source.localizedName).tag(source)
                }
            }
            Text("settings.mediaSource.hint")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section {
                Picker(String(localized: "settings.spectrum.style", defaultValue: "Spektrum-Stil"), selection: $settings.spectrumStyle) {
                    ForEach(UserSettings.SpectrumStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }
                Picker(String(localized: "settings.spectrum.colorSource", defaultValue: "Farbquelle"), selection: $settings.spectrumColorSource) {
                    ForEach(UserSettings.SpectrumColorSource.allCases) { source in
                        Text(source.localizedName).tag(source)
                    }
                }
                .disabled(!settings.spectrumStyle.usesAccentPair)
                ColorPicker(String(localized: "settings.spectrum.colorA", defaultValue: "Akzentfarbe 1"), selection: $settings.spectrumColorA, supportsOpacity: false)
                    .disabled(!settings.spectrumStyle.usesAccentPair || settings.spectrumColorSource == .cover)
                ColorPicker(String(localized: "settings.spectrum.colorB", defaultValue: "Akzentfarbe 2"), selection: $settings.spectrumColorB, supportsOpacity: false)
                    .disabled(!settings.spectrumStyle.usesAccentPair || settings.spectrumColorSource == .cover)
            } header: {
                Text(String(localized: "settings.spectrum.header", defaultValue: "Sound-Spektrum"))
            } footer: {
                Text(String(localized: "settings.spectrum.hint", defaultValue: "„Vom Cover“ leitet die zweite Farbe automatisch aus dem Album-Akzent ab."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct FeatureSettings: View {
    @ObservedObject var settings: UserSettings

    var body: some View {
        Form {
            Toggle(String(localized: "settings.liveActivities", defaultValue: "Live Activities"), isOn: $settings.liveActivitiesEnabled)
            Toggle(String(localized: "settings.hud", defaultValue: "HUD-Ersatz (Lautstärke/Helligkeit)"), isOn: $settings.hudEnabled)
            Toggle(String(localized: "settings.suppressOSD", defaultValue: "Lautstärke & Helligkeit nur in der Notch (Bedienungshilfen nötig)"), isOn: $settings.suppressSystemOSD)
                .disabled(!settings.hudEnabled)
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct TimerSettings: View {
    @ObservedObject var settings: UserSettings

    var body: some View {
        Form {
            Section {
                ForEach($settings.timerPresets) { $preset in
                    HStack(spacing: 12) {
                        TextField(
                            String(localized: "settings.timer.name", defaultValue: "Name"),
                            text: $preset.name,
                            prompt: Text(String(localized: "settings.timer.name", defaultValue: "Name"))
                        )
                        .labelsHidden()
                        Spacer(minLength: 0)
                        Stepper(value: $preset.minutes, in: 1...180) {
                            Text(String(localized: "settings.timer.minutes", defaultValue: "\(preset.minutes) min"))
                                .monospacedDigit()
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                        Button {
                            settings.timerPresets.removeAll { $0.id == preset.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onMove { settings.timerPresets.move(fromOffsets: $0, toOffset: $1) }

                Button {
                    settings.timerPresets.append(
                        TimerPreset(name: String(localized: "timer.preset.new", defaultValue: "Neuer Timer"), minutes: 25)
                    )
                } label: {
                    Label(String(localized: "settings.timer.add", defaultValue: "Timer hinzufügen"), systemImage: "plus")
                }
            } header: {
                Text(String(localized: "settings.timer.presets", defaultValue: "Voreinstellungen"))
            } footer: {
                Text(String(localized: "settings.timer.chainHint", defaultValue: "Die Reihenfolge der Liste bestimmt die Kette beim automatischen Fortsetzen."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "settings.timer.countUp", defaultValue: "Aufwärts zählen (verstrichene Zeit)"), isOn: $settings.timerCountsUp)
                Toggle(String(localized: "settings.timer.autoChain", defaultValue: "Automatisch mit nächstem Timer fortsetzen"), isOn: $settings.timerAutoChain)
                Toggle(String(localized: "settings.timer.sound", defaultValue: "Ton bei Ablauf"), isOn: $settings.timerSoundEnabled)
            } header: {
                Text(String(localized: "settings.timer.behavior", defaultValue: "Verhalten"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ObsidianSettings: View {
    @ObservedObject var settings: UserSettings

    private var vaultDisplayName: String {
        if let data = settings.vaultBookmark, let url = Persistence.resolveBookmark(data) {
            return url.lastPathComponent
        }
        return String(localized: "settings.obsidian.noVault", defaultValue: "Kein Vault gewählt")
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "settings.obsidian.vault", defaultValue: "Vault-Ordner"))
                        Text(vaultDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "settings.obsidian.choose", defaultValue: "Wählen …"), action: chooseVault)
                }
            }

            Section {
                TextField(String(localized: "settings.obsidian.dailyFolder", defaultValue: "Daily-Ordner"), text: $settings.dailyFolder)
                TextField(String(localized: "settings.obsidian.dailyFormat", defaultValue: "Datumsformat"), text: $settings.dailyFormat)
                TextField(String(localized: "settings.obsidian.heading", defaultValue: "Capture-Überschrift"), text: $settings.captureHeading)
            } header: {
                Text(String(localized: "settings.obsidian.target", defaultValue: "Ziel"))
            }

            Section {
                Picker(String(localized: "settings.obsidian.mode", defaultValue: "Schreibweise"), selection: $settings.captureMode) {
                    ForEach(UserSettings.CaptureMode.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
                Toggle(String(localized: "settings.obsidian.timestamp", defaultValue: "Zeitstempel voranstellen"), isOn: $settings.captureTimestamp)
                Toggle(String(localized: "settings.obsidian.hotkey", defaultValue: "Globaler Hotkey (⌥⌘Space)"), isOn: $settings.captureHotkeyEnabled)
            } header: {
                Text(String(localized: "settings.obsidian.behavior", defaultValue: "Verhalten"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "settings.obsidian.choosePrompt", defaultValue: "Vault wählen")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.vaultBookmark = Persistence.bookmarkData(for: url)
        if settings.vaultName.isEmpty { settings.vaultName = url.lastPathComponent }
    }
}

private struct DataSettings: View {
    @State private var didReset = false

    var body: some View {
        Form {
            Button(role: .destructive) {
                Persistence.resetAll()
                NotificationCenter.default.post(name: .notchMateResetData, object: nil)
                didReset = true
            } label: {
                Label(String(localized: "settings.resetData", defaultValue: "Ablage, Favoriten & Cache zurücksetzen"), systemImage: "trash")
            }
            if didReset {
                Text("settings.resetData.done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
