import XCTest
@testable import Ledge

final class TimerPresetTests: XCTestCase {
    func testDecodingWithoutIsFocusKeyDefaultsToTrue() throws {
        // Mirrors presets persisted before `isFocus` existed.
        let json = """
        {"id":"9B1DE1B1-0000-4B0A-8B0A-000000000000","name":"Fokus","minutes":25}
        """
        let preset = try JSONDecoder().decode(TimerPreset.self, from: Data(json.utf8))
        XCTAssertTrue(preset.isFocus)
    }

    func testDecodingRoundTripsIsFocus() throws {
        let preset = TimerPreset(name: "Pause", minutes: 5, isFocus: false)
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(TimerPreset.self, from: data)
        XCTAssertFalse(decoded.isFocus)
    }
}
