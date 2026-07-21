import AppKit

/// Immutable snapshot of a source's playback state.
struct NowPlayingState: Equatable {
    var isRunning = false
    var isPlaying = false
    var track: NowPlayingTrack?
    var position: TimeInterval = 0
    var isShuffling = false
    /// The player is running but macOS denied us Automation (Apple Events)
    /// access, so we can't read its state. Distinct from "not running" so the
    /// UI can prompt for a re-grant instead of silently showing "no player".
    var permissionDenied = false
}

/// A controllable media source (a scriptable player app). The manager polls
/// `refresh()` and forwards transport commands to whichever source is active.
protocol NowPlayingSource: AnyObject {
    var id: UserSettings.MediaSource { get }
    /// `DistributedNotificationCenter` name the app posts on playback changes.
    var changeNotification: Notification.Name? { get }
    var state: NowPlayingState { get }

    /// Re-read state from the app (executes AppleScript off the main thread).
    func refresh(completion: @escaping (NowPlayingState) -> Void)

    func playPause()
    func nextTrack()
    func previousTrack()
    func toggleShuffle()
    /// Jump to `seconds` within the current track (scrubbing).
    func seek(to seconds: TimeInterval)
    /// Bring the player app to the front (Apple Music has no track deep link).
    func activate()
}

/// Shared AppleScript plumbing for scriptable players. Subclasses provide the
/// app name and the dialect specifics (duration unit, shuffle command).
class ScriptableMediaSource: NowPlayingSource {
    let id: UserSettings.MediaSource
    let appName: String
    let changeNotification: Notification.Name?
    private(set) var state = NowPlayingState()

    /// Spotify reports duration in milliseconds, Apple Music in seconds.
    private let durationDivisor: Double
    /// Shared across all sources: the OSA/AppleScript component is not safe to
    /// enter concurrently from multiple threads (two scripts compiling at once
    /// can crash inside the shared Apple Event component), so every source
    /// must serialize onto the same queue rather than its own.
    private static let queue = DispatchQueue(label: "com.scott.notchmate.applescript")
    private var queue: DispatchQueue { Self.queue }

    init(id: UserSettings.MediaSource, appName: String, durationDivisor: Double, changeNotification: Notification.Name?) {
        self.id = id
        self.appName = appName
        self.durationDivisor = durationDivisor
        self.changeNotification = changeNotification
    }

    // MARK: Transport

    func playPause() { run("tell application \"\(appName)\" to playpause") }
    func nextTrack() { run("tell application \"\(appName)\" to next track") }
    func previousTrack() { run("tell application \"\(appName)\" to previous track") }
    /// Both Spotify and Music take `set player position to <seconds>`.
    func seek(to seconds: TimeInterval) {
        run("tell application \"\(appName)\" to set player position to \(Int(seconds.rounded()))")
    }
    func activate() { run("tell application \"\(appName)\" to activate") }

    /// Overridden per dialect (`set shuffling` vs `set shuffle enabled`).
    func shuffleCommand(_ on: Bool) -> String { "" }

    func toggleShuffle() {
        let command = shuffleCommand(!state.isShuffling)
        guard !command.isEmpty else { return }
        run("tell application \"\(appName)\" to \(command)")
    }

    // MARK: Reading

    func refresh(completion: @escaping (NowPlayingState) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let newState: NowPlayingState
            switch self.runScript(self.readScript) {
            case .success(let output):
                newState = self.parse(output)
            case .failure(let error):
                // errAEEventNotPermitted (-1743): the player is up but macOS
                // blocked our Apple Events. Surface it distinctly so the UI can
                // prompt; any other scripting error degrades to "not running".
                let denied = (error as NSError).code == -1743
                newState = NowPlayingState(permissionDenied: denied)
            }
            DispatchQueue.main.async {
                self.state = newState
                completion(newState)
            }
        }
    }

    /// Internal (not private) so unit tests can exercise the parsing directly.
    func parse(_ output: String) -> NowPlayingState {
        if output == "NOT_RUNNING" || output == "STOPPED" {
            return NowPlayingState(isRunning: output == "STOPPED")
        }
        let parts = output.components(separatedBy: "|||")
        // 8 legacy fields, or 9 with a trailing track deep-link URL.
        guard parts.count >= 8 else { return NowPlayingState() }
        let artwork = parts[3].isEmpty ? nil : URL(string: parts[3])
        let trackURL = parts.count >= 9 && !parts[8].isEmpty ? URL(string: parts[8]) : nil
        return NowPlayingState(
            isRunning: true,
            isPlaying: parts[6] == "playing",
            track: NowPlayingTrack(
                name: parts[0],
                artist: parts[1],
                album: parts[2],
                artworkURL: artwork,
                duration: Self.parseNumber(parts[4]) / durationDivisor,
                url: trackURL
            ),
            position: Self.parseNumber(parts[5]),
            isShuffling: parts[7] == "true"
        )
    }

    /// Parses an AppleScript number, tolerating a locale decimal comma.
    private static func parseNumber(_ string: String) -> Double {
        Double(string.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func run(_ source: String) {
        queue.async { [weak self] in _ = self?.runScript(source) }
    }

    private func runScript(_ source: String) -> Result<String, Error> {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(NSError(domain: "Ledge", code: -1))
        }
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            NSLog("Ledge: \(appName) AppleScript error: \(error)")
            // Preserve the AppleScript error number (e.g. -1743 = not permitted)
            // as the NSError code so callers can react to permission denials.
            let number = (error["NSAppleScriptErrorNumber"] as? Int) ?? -2
            return .failure(NSError(domain: "Ledge", code: number))
        }
        return .success(descriptor.stringValue ?? "")
    }

    /// Pipe-delimited read script. Subclasses override the dialect details.
    var readScript: String { "" }
}

/// Spotify-specific dialect.
final class SpotifySource: ScriptableMediaSource {
    init() {
        super.init(
            id: .spotify,
            appName: "Spotify",
            durationDivisor: 1000,   // Spotify duration is in milliseconds
            changeNotification: Notification.Name("com.spotify.client.PlaybackStateChanged")
        )
    }

    override func shuffleCommand(_ on: Bool) -> String { "set shuffling to \(on)" }

    override var readScript: String {
        """
        if application "Spotify" is running then
            tell application "Spotify"
                set ps to "stopped"
                if player state is playing then set ps to "playing"
                if player state is paused then set ps to "paused"
                set sh to "false"
                if shuffling then set sh to "true"
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackArt to artwork url of current track
                set trackDuration to duration of current track
                set trackPosition to (player position) as integer
                set trackUrl to spotify url of current track
                return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackArt & "|||" & trackDuration & "|||" & trackPosition & "|||" & ps & "|||" & sh & "|||" & trackUrl
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
    }
}

/// Apple Music dialect. Music exposes duration in seconds and has no artwork
/// URL (artwork is embedded image data), so the cover falls back to a placeholder.
final class AppleMusicSource: ScriptableMediaSource {
    init() {
        super.init(
            id: .appleMusic,
            appName: "Music",
            durationDivisor: 1,   // Apple Music duration is already in seconds
            changeNotification: Notification.Name("com.apple.Music.playerInfo")
        )
    }

    override func shuffleCommand(_ on: Bool) -> String { "set shuffle enabled to \(on)" }

    override var readScript: String {
        """
        if application "Music" is running then
            tell application "Music"
                if player state is stopped then return "STOPPED"
                set ps to "stopped"
                if player state is playing then set ps to "playing"
                if player state is paused then set ps to "paused"
                set sh to "false"
                try
                    if shuffle enabled then set sh to "true"
                end try
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
                set trackPosition to player position
                return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & "" & "|||" & trackDuration & "|||" & trackPosition & "|||" & ps & "|||" & sh
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
    }
}
