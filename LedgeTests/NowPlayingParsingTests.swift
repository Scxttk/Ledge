import XCTest
@testable import Ledge

final class NowPlayingParsingTests: XCTestCase {

    func testSpotifyParsesPipeDelimitedOutputWithMillisecondDuration() {
        let output = "Song|||Artist|||Album|||https://art|||240000|||30|||playing|||true"
        let state = SpotifySource().parse(output)
        XCTAssertTrue(state.isRunning)
        XCTAssertTrue(state.isPlaying)
        XCTAssertTrue(state.isShuffling)
        XCTAssertEqual(state.track?.name, "Song")
        XCTAssertEqual(state.track?.artist, "Artist")
        // Spotify reports ms → divided by 1000 into seconds.
        XCTAssertEqual(state.track?.duration ?? 0, 240, accuracy: 0.001)
        XCTAssertEqual(state.position, 30, accuracy: 0.001)
        XCTAssertEqual(state.track?.artworkURL?.absoluteString, "https://art")
    }

    func testAppleMusicParsesSecondsDurationAndLocaleComma() {
        let output = "Lied|||Künstler|||Album||||||215,5|||10,0|||paused|||false"
        let state = AppleMusicSource().parse(output)
        XCTAssertTrue(state.isRunning)
        XCTAssertFalse(state.isPlaying)
        XCTAssertFalse(state.isShuffling)
        // Apple Music reports seconds already (divisor 1); comma decimal tolerated.
        XCTAssertEqual(state.track?.duration ?? 0, 215.5, accuracy: 0.001)
        XCTAssertEqual(state.position, 10.0, accuracy: 0.001)
        XCTAssertNil(state.track?.artworkURL) // empty artwork field
    }

    func testNotRunningSentinel() {
        let state = SpotifySource().parse("NOT_RUNNING")
        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.track)
    }

    func testStoppedSentinelMarksRunningButNoTrack() {
        let state = AppleMusicSource().parse("STOPPED")
        XCTAssertTrue(state.isRunning)
        XCTAssertFalse(state.isPlaying)
        XCTAssertNil(state.track)
    }

    func testMalformedOutputYieldsEmptyState() {
        let state = SpotifySource().parse("only|||three|||fields")
        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.track)
    }
}
