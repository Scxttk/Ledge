import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the user resets all data; live models clear themselves.
    static let notchMateResetData = Notification.Name("com.scott.notchmate.resetData")
}

/// User-facing preferences, persisted in `UserDefaults`. Injected as an
/// `@EnvironmentObject` / `@ObservedObject` so SwiftUI views and controllers
/// react to changes live. Keep keys stable — they are the on-disk contract.
final class UserSettings: ObservableObject {
    static let shared = UserSettings()

    enum MediaSource: String, CaseIterable, Identifiable {
        case auto
        case spotify
        case appleMusic

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .auto: return String(localized: "source.auto", defaultValue: "Automatisch")
            case .spotify: return String(localized: "source.spotify", defaultValue: "Spotify")
            case .appleMusic: return String(localized: "source.appleMusic", defaultValue: "Apple Music")
            }
        }

        /// Bundle ID of the player app, to match against the bundle ID
        /// `SpectrumAnalyzer` reports for whatever is actually feeding audio.
        /// nil for `.auto`, which is a selection mode, not an app.
        var bundleID: String? {
            switch self {
            case .auto: return nil
            case .spotify: return "com.spotify.client"
            case .appleMusic: return "com.apple.Music"
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case dark
        case light

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .system: return String(localized: "appearance.system", defaultValue: "Systemstandard")
            case .dark: return String(localized: "appearance.dark", defaultValue: "Dunkel")
            case .light: return String(localized: "appearance.light", defaultValue: "Hell")
            }
        }
    }

    /// Visual style for the now-playing spectrum bars (`WaveBarsView`).
    /// `.solid` keeps every bar tinted the same (cover accent or the cyan/blue
    /// fallback); `.alternating` and `.gradient` bring in a second accent
    /// colour, sourced per `spectrumColorSource`.
    enum SpectrumStyle: String, CaseIterable, Identifiable {
        case solid
        case shades
        case alternating
        case gradient
        case coverImage

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .solid: return String(localized: "spectrum.style.solid", defaultValue: "Einfarbig")
            case .shades: return String(localized: "spectrum.style.shades", defaultValue: "Schattierungen")
            case .alternating: return String(localized: "spectrum.style.alternating", defaultValue: "Alternierend")
            case .gradient: return String(localized: "spectrum.style.gradient", defaultValue: "Verlauf")
            case .coverImage: return String(localized: "spectrum.style.coverImage", defaultValue: "Cover")
            }
        }

        /// Whether this style consults the second accent colour at all.
        /// `.solid`/`.shades` are always single-hue from the cover, so the
        /// colour-source and accent pickers are irrelevant for them.
        var usesAccentPair: Bool {
            switch self {
            case .solid, .shades, .coverImage: return false
            case .alternating, .gradient: return true
            }
        }
    }

    /// Where the two accent colours for `.alternating`/`.gradient` come from.
    /// `.cover` derives them from the current track's artwork (same accent the
    /// solid style already uses, plus a hue-shifted twin) so the spectrum keeps
    /// matching whatever is playing. `.manual` uses the two fixed colours the
    /// user picked in Settings.
    enum SpectrumColorSource: String, CaseIterable, Identifiable {
        case cover
        case manual

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .cover: return String(localized: "spectrum.colorSource.cover", defaultValue: "Vom Cover")
            case .manual: return String(localized: "spectrum.colorSource.manual", defaultValue: "Manuell")
            }
        }
    }

    /// How Quick Capture writes into the vault. `.silentAppend` is the default —
    /// it appends directly to the daily note's file without stealing focus.
    /// `.openInObsidian` does the same silent append, then reveals the note in
    /// Obsidian so the user sees it.
    enum CaptureMode: String, CaseIterable, Identifiable {
        case silentAppend
        case openInObsidian

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .silentAppend: return String(localized: "capture.mode.silent", defaultValue: "Lautlos anhängen")
            case .openInObsidian: return String(localized: "capture.mode.open", defaultValue: "Anhängen & in Obsidian öffnen")
            }
        }
    }

    private enum Key {
        static let mediaSource = "mediaSource"
        static let appearance = "appearance"
        static let liveActivitiesEnabled = "liveActivitiesEnabled"
        static let hudEnabled = "hudEnabled"
        static let suppressSystemOSD = "suppressSystemOSD"
        static let spectrumStyle = "spectrumStyle"
        static let coverPaletteSize = "coverPaletteSize"
        static let coverBrightnessLevels = "coverBrightnessLevels"
        static let coverBarSaturation = "coverBarSaturation"
        static let coverBarBrightness = "coverBarBrightness"
        static let spectrumColorSource = "spectrumColorSource"
        static let spectrumColorA = "spectrumColorA"
        static let spectrumColorB = "spectrumColorB"
        static let pillSpectrumOnly = "pillSpectrumOnly"
        static let pillSpectrumBarCount = "pillSpectrumBarCount"
        static let pillSpectrumWidth = "pillSpectrumWidth"
        // Obsidian Quick Capture
        static let vaultBookmark = "obsidianVaultBookmark"
        static let vaultName = "obsidianVaultName"
        static let dailyFolder = "obsidianDailyFolder"
        static let dailyFormat = "obsidianDailyFormat"
        static let captureHeading = "obsidianCaptureHeading"
        static let captureMode = "obsidianCaptureMode"
        static let captureTimestamp = "obsidianCaptureTimestamp"
        static let captureHotkeyEnabled = "obsidianCaptureHotkeyEnabled"
        static let focusTrackingEnabled = "obsidianFocusTrackingEnabled"
        static let focusHeading = "obsidianFocusHeading"
        // Focus timers (pomodoro)
        static let timerPresets = "timerPresets"
        static let timerCountsUp = "timerCountsUp"
        static let timerAutoChain = "timerAutoChain"
        static let timerSoundEnabled = "timerSoundEnabled"
        // Tab visibility (claudeTabEnabled predates the others — keep its key)
        static let musicTabEnabled = "musicTabEnabled"
        static let filesTabEnabled = "filesTabEnabled"
        static let captureTabEnabled = "captureTabEnabled"
        static let timerTabEnabled = "timerTabEnabled"
        static let claudeTabEnabled = "claudeTabEnabled"
    }

    private let defaults: UserDefaults

    @Published var mediaSource: MediaSource {
        didSet { defaults.set(mediaSource.rawValue, forKey: Key.mediaSource) }
    }
    @Published var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }
    @Published var liveActivitiesEnabled: Bool {
        didSet { defaults.set(liveActivitiesEnabled, forKey: Key.liveActivitiesEnabled) }
    }
    @Published var hudEnabled: Bool {
        didSet { defaults.set(hudEnabled, forKey: Key.hudEnabled) }
    }
    /// Show volume (and brightness) changes *only* in the notch: NotchMate captures
    /// the hardware volume/brightness keys and adjusts the level itself so Apple's
    /// own OSD never appears. Brightness uses a private API and is only intercepted
    /// when available. Requires Accessibility; without it the notch HUD is additive.
    @Published var suppressSystemOSD: Bool {
        didSet { defaults.set(suppressSystemOSD, forKey: Key.suppressSystemOSD) }
    }
    @Published var spectrumStyle: SpectrumStyle {
        didSet { defaults.set(spectrumStyle.rawValue, forKey: Key.spectrumStyle) }
    }
    // Tuning for the `.coverImage` spectrum style. These four decide how hard
    // the cover's colours are bundled and how they read on the black notch;
    // exposed as controls because the right values are a matter of taste and
    // depend on the covers you actually listen to. Changing any of them
    // recomputes the current cover's palette live (`NowPlayingManager`).
    /// How many cover colours the bars are quantised onto (1…5).
    @Published var coverPaletteSize: Int {
        didSet { defaults.set(coverPaletteSize, forKey: Key.coverPaletteSize) }
    }
    /// Brightness steps kept per bar (1 = flat colour, higher = more of the
    /// cover's light and shade survives).
    @Published var coverBrightnessLevels: Int {
        didSet { defaults.set(coverBrightnessLevels, forKey: Key.coverBrightnessLevels) }
    }
    /// Multipliers on the bars' saturation and brightness (1.0 = as derived).
    @Published var coverBarSaturation: Double {
        didSet { defaults.set(coverBarSaturation, forKey: Key.coverBarSaturation) }
    }
    @Published var coverBarBrightness: Double {
        didSet { defaults.set(coverBarBrightness, forKey: Key.coverBarBrightness) }
    }
    /// Replace the collapsed pill's mini cover with a wider spectrum (more,
    /// longer bars) spanning the space the cover freed up. Pill only — the
    /// expanded music tab keeps its cover.
    @Published var pillSpectrumOnly: Bool {
        didSet { defaults.set(pillSpectrumOnly, forKey: Key.pillSpectrumOnly) }
    }
    /// How many bars the spectrum-only pill draws (6…32 — 32 is the
    /// analyzer's full band resolution) and how wide the pill's wave area is.
    /// The bars spread evenly across that width: fewer bars → wider gaps.
    @Published var pillSpectrumBarCount: Int {
        didSet { defaults.set(pillSpectrumBarCount, forKey: Key.pillSpectrumBarCount) }
    }
    @Published var pillSpectrumWidth: Double {
        didSet { defaults.set(pillSpectrumWidth, forKey: Key.pillSpectrumWidth) }
    }
    @Published var spectrumColorSource: SpectrumColorSource {
        didSet { defaults.set(spectrumColorSource.rawValue, forKey: Key.spectrumColorSource) }
    }
    @Published var spectrumColorA: Color {
        didSet { defaults.set(Self.encodeColor(spectrumColorA), forKey: Key.spectrumColorA) }
    }
    @Published var spectrumColorB: Color {
        didSet { defaults.set(Self.encodeColor(spectrumColorB), forKey: Key.spectrumColorB) }
    }

    // MARK: Obsidian Quick Capture

    /// Bookmark to the vault root folder (plain bookmark; the app isn't sandboxed).
    @Published var vaultBookmark: Data? {
        didSet { defaults.set(vaultBookmark, forKey: Key.vaultBookmark) }
    }
    /// Vault name for `obsidian://` URLs (defaults to the folder name when empty).
    @Published var vaultName: String {
        didSet { defaults.set(vaultName, forKey: Key.vaultName) }
    }
    /// Daily-note folder relative to the vault root (Obsidian "Daily notes" setting).
    @Published var dailyFolder: String {
        didSet { defaults.set(dailyFolder, forKey: Key.dailyFolder) }
    }
    /// Daily-note filename date format (accepts Obsidian/moment `YYYY-MM-DD`).
    @Published var dailyFormat: String {
        didSet { defaults.set(dailyFormat, forKey: Key.dailyFormat) }
    }
    /// Markdown heading the capture bullet is inserted under.
    @Published var captureHeading: String {
        didSet { defaults.set(captureHeading, forKey: Key.captureHeading) }
    }
    @Published var captureMode: CaptureMode {
        didSet { defaults.set(captureMode.rawValue, forKey: Key.captureMode) }
    }
    /// Prefix each captured bullet with the current `HH:mm`.
    @Published var captureTimestamp: Bool {
        didSet { defaults.set(captureTimestamp, forKey: Key.captureTimestamp) }
    }
    /// Register the global capture hotkey (⌥⌘Space). No Accessibility permission needed.
    @Published var captureHotkeyEnabled: Bool {
        didSet { defaults.set(captureHotkeyEnabled, forKey: Key.captureHotkeyEnabled) }
    }
    /// Log completed/aborted focus-preset sessions to the daily note.
    @Published var focusTrackingEnabled: Bool {
        didSet { defaults.set(focusTrackingEnabled, forKey: Key.focusTrackingEnabled) }
    }
    /// Markdown heading the focus-session bullet is inserted under.
    @Published var focusHeading: String {
        didSet { defaults.set(focusHeading, forKey: Key.focusHeading) }
    }

    // MARK: Focus timers (pomodoro)

    /// Ordered list of named timers; the list order is also the auto-chain
    /// order (a completed timer starts the next one, wrapping around).
    @Published var timerPresets: [TimerPreset] {
        didSet { defaults.set(Self.encodePresets(timerPresets), forKey: Key.timerPresets) }
    }
    /// Count up (elapsed time) instead of down (remaining time). Display only —
    /// the session still ends when the preset duration is reached.
    @Published var timerCountsUp: Bool {
        didSet { defaults.set(timerCountsUp, forKey: Key.timerCountsUp) }
    }
    /// Auto-start the next preset in list order when a timer completes.
    @Published var timerAutoChain: Bool {
        didSet { defaults.set(timerAutoChain, forKey: Key.timerAutoChain) }
    }
    /// Play a completion sound when a timer runs out.
    @Published var timerSoundEnabled: Bool {
        didSet { defaults.set(timerSoundEnabled, forKey: Key.timerSoundEnabled) }
    }

    // MARK: Tab visibility

    /// Per-tab visibility switches. `NotchViewModel.enabledTabs` filters on
    /// these; the Settings UI keeps at least one of them on.
    @Published var musicTabEnabled: Bool {
        didSet { defaults.set(musicTabEnabled, forKey: Key.musicTabEnabled) }
    }
    @Published var filesTabEnabled: Bool {
        didSet { defaults.set(filesTabEnabled, forKey: Key.filesTabEnabled) }
    }
    @Published var captureTabEnabled: Bool {
        didSet { defaults.set(captureTabEnabled, forKey: Key.captureTabEnabled) }
    }
    @Published var timerTabEnabled: Bool {
        didSet { defaults.set(timerTabEnabled, forKey: Key.timerTabEnabled) }
    }
    @Published var claudeTabEnabled: Bool {
        didSet { defaults.set(claudeTabEnabled, forKey: Key.claudeTabEnabled) }
    }

    func isTabEnabled(_ tab: NotchViewModel.Tab) -> Bool {
        switch tab {
        case .music: return musicTabEnabled
        case .files: return filesTabEnabled
        case .capture: return captureTabEnabled
        case .timer: return timerTabEnabled
        case .claude: return claudeTabEnabled
        }
    }

    func setTab(_ tab: NotchViewModel.Tab, enabled: Bool) {
        switch tab {
        case .music: musicTabEnabled = enabled
        case .files: filesTabEnabled = enabled
        case .capture: captureTabEnabled = enabled
        case .timer: timerTabEnabled = enabled
        case .claude: claudeTabEnabled = enabled
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.liveActivitiesEnabled: true,
            Key.hudEnabled: true,
            Key.suppressSystemOSD: true,
            Key.dailyFolder: "01-daily",
            Key.dailyFormat: "yyyy-MM-dd",
            Key.captureHeading: "## 📥 Capture",
            Key.captureTimestamp: true,
            Key.captureHotkeyEnabled: false,
            Key.focusTrackingEnabled: true,
            Key.focusHeading: "## ⏱️ Fokuszeit",
            Key.timerCountsUp: false,
            Key.timerAutoChain: false,
            Key.timerSoundEnabled: true,
            Key.musicTabEnabled: true,
            Key.filesTabEnabled: true,
            Key.captureTabEnabled: true,
            Key.timerTabEnabled: true,
            Key.claudeTabEnabled: true,
            Key.coverPaletteSize: 4,
            Key.coverBrightnessLevels: 3,
            Key.coverBarSaturation: 1.0,
            Key.coverBarBrightness: 1.0,
            Key.pillSpectrumOnly: false,
            Key.pillSpectrumBarCount: 16,
            Key.pillSpectrumWidth: 48.0,
        ])
        self.mediaSource = MediaSource(rawValue: defaults.string(forKey: Key.mediaSource) ?? "") ?? .auto
        self.appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        self.liveActivitiesEnabled = defaults.bool(forKey: Key.liveActivitiesEnabled)
        self.hudEnabled = defaults.bool(forKey: Key.hudEnabled)
        self.suppressSystemOSD = defaults.bool(forKey: Key.suppressSystemOSD)
        self.spectrumStyle = SpectrumStyle(rawValue: defaults.string(forKey: Key.spectrumStyle) ?? "") ?? .shades
        self.spectrumColorSource = SpectrumColorSource(rawValue: defaults.string(forKey: Key.spectrumColorSource) ?? "") ?? .cover
        self.coverPaletteSize = defaults.integer(forKey: Key.coverPaletteSize)
        self.coverBrightnessLevels = defaults.integer(forKey: Key.coverBrightnessLevels)
        self.coverBarSaturation = defaults.double(forKey: Key.coverBarSaturation)
        self.coverBarBrightness = defaults.double(forKey: Key.coverBarBrightness)
        self.pillSpectrumOnly = defaults.bool(forKey: Key.pillSpectrumOnly)
        self.pillSpectrumBarCount = max(6, min(32, defaults.integer(forKey: Key.pillSpectrumBarCount)))
        self.pillSpectrumWidth = max(36, min(140, defaults.double(forKey: Key.pillSpectrumWidth)))
        self.spectrumColorA = Self.decodeColor(defaults.data(forKey: Key.spectrumColorA)) ?? .cyan
        self.spectrumColorB = Self.decodeColor(defaults.data(forKey: Key.spectrumColorB)) ?? .purple
        self.vaultBookmark = defaults.data(forKey: Key.vaultBookmark)
        self.vaultName = defaults.string(forKey: Key.vaultName) ?? ""
        self.dailyFolder = defaults.string(forKey: Key.dailyFolder) ?? "01-daily"
        self.dailyFormat = defaults.string(forKey: Key.dailyFormat) ?? "yyyy-MM-dd"
        self.captureHeading = defaults.string(forKey: Key.captureHeading) ?? "## 📥 Capture"
        self.captureMode = CaptureMode(rawValue: defaults.string(forKey: Key.captureMode) ?? "") ?? .silentAppend
        self.captureTimestamp = defaults.bool(forKey: Key.captureTimestamp)
        self.captureHotkeyEnabled = defaults.bool(forKey: Key.captureHotkeyEnabled)
        self.focusTrackingEnabled = defaults.bool(forKey: Key.focusTrackingEnabled)
        self.focusHeading = defaults.string(forKey: Key.focusHeading) ?? "## ⏱️ Fokuszeit"
        self.timerPresets = Self.decodePresets(defaults.data(forKey: Key.timerPresets)) ?? TimerPreset.defaults
        self.timerCountsUp = defaults.bool(forKey: Key.timerCountsUp)
        self.timerAutoChain = defaults.bool(forKey: Key.timerAutoChain)
        self.timerSoundEnabled = defaults.bool(forKey: Key.timerSoundEnabled)
        self.musicTabEnabled = defaults.bool(forKey: Key.musicTabEnabled)
        self.filesTabEnabled = defaults.bool(forKey: Key.filesTabEnabled)
        self.captureTabEnabled = defaults.bool(forKey: Key.captureTabEnabled)
        self.timerTabEnabled = defaults.bool(forKey: Key.timerTabEnabled)
        self.claudeTabEnabled = defaults.bool(forKey: Key.claudeTabEnabled)
    }

    private static func encodeColor(_ color: Color) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: NSColor(color), requiringSecureCoding: true)
    }

    private static func decodeColor(_ data: Data?) -> Color? {
        guard let data,
              let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        else { return nil }
        return Color(nsColor)
    }

    private static func encodePresets(_ presets: [TimerPreset]) -> Data? {
        try? JSONEncoder().encode(presets)
    }

    private static func decodePresets(_ data: Data?) -> [TimerPreset]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([TimerPreset].self, from: data)
    }
}
