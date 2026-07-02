import AppKit

/// Immutable snapshot of a source's playback state.
struct NowPlayingState: Equatable {
    var isRunning = false
    var isPlaying = false
    var track: NowPlayingTrack?
    var position: TimeInterval = 0
    var isShuffling = false
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
    private let queue: DispatchQueue

    init(id: UserSettings.MediaSource, appName: String, durationDivisor: Double, changeNotification: Notification.Name?) {
        self.id = id
        self.appName = appName
        self.durationDivisor = durationDivisor
        self.changeNotification = changeNotification
        self.queue = DispatchQueue(label: "com.scott.notchmate.source.\(appName)")
    }

    // MARK: Transport

    func playPause() { run("tell application \"\(appName)\" to playpause") }
    func nextTrack() { run("tell application \"\(appName)\" to next track") }
    func previousTrack() { run("tell application \"\(appName)\" to previous track") }

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
            case .failure:
                // Treat a scripting error as "not running" rather than desyncing.
                newState = NowPlayingState()
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
        guard parts.count == 8 else { return NowPlayingState() }
        let artwork = parts[3].isEmpty ? nil : URL(string: parts[3])
        return NowPlayingState(
            isRunning: true,
            isPlaying: parts[6] == "playing",
            track: NowPlayingTrack(
                name: parts[0],
                artist: parts[1],
                album: parts[2],
                artworkURL: artwork,
                duration: Self.parseNumber(parts[4]) / durationDivisor
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
            return .failure(NSError(domain: "NotchMate", code: -1))
        }
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            NSLog("NotchMate: \(appName) AppleScript error: \(error)")
            return .failure(NSError(domain: "NotchMate", code: -2))
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
                return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackArt & "|||" & trackDuration & "|||" & trackPosition & "|||" & ps & "|||" & sh
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
