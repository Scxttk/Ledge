import Foundation

/// A single now-playing track, shared across media sources (Spotify, Apple Music).
struct NowPlayingTrack: Equatable {
    var name: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var duration: TimeInterval   // seconds
    /// Deep link to the track in its app (e.g. `spotify:track:…`), for opening
    /// the song from the artwork. nil when the source exposes no such link
    /// (Apple Music — we just bring the app forward instead).
    var url: URL?
}
