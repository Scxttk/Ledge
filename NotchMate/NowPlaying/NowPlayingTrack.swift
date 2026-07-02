import Foundation

/// A single now-playing track, shared across media sources (Spotify, Apple Music).
struct NowPlayingTrack: Equatable {
    var name: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var duration: TimeInterval   // seconds
}
