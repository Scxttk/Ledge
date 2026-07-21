import XCTest
@testable import NotchMate

/// Feeds synthetic "compressed music" through the analyzer's real FFT path
/// and measures whether the bars move. This is the regression that motivated
/// the beat-emphasis mapping: a loudness-normalized master moves only a few
/// dB short-term, and the old purely absolute window let the bars find their
/// static positions and stand there — visually dead on Spotify while a
/// dynamic YouTube video danced.
final class SpectrumBeatTests: XCTestCase {

    private let sampleRate = 48_000.0
    private let blockSize = 1024

    /// One block of a 100 Hz tone (bass band) at `amplitude`, phase-continuous
    /// across blocks via `phase`.
    private func toneBlock(amplitude: Float, phase: inout Double) -> [Float] {
        let step = 2.0 * Double.pi * 100.0 / sampleRate
        return (0..<blockSize).map { _ in
            let s = Float(sin(phase)) * amplitude
            phase += step
            return s
        }
    }

    func testAFiveDecibelKickVisiblyMovesTheBassBar() {
        let analyzer = SpectrumAnalyzer(bandCount: 16)
        var phase = 0.0

        // Settle on the steady base level — a compressed master's "floor".
        let base: Float = 0.1
        var levels: [Float] = []
        for _ in 0..<40 {
            levels = analyzer.ingestForTesting(toneBlock(amplitude: base, phase: &phase))
        }
        // The 100 Hz tone lands in the lowest bands; track the strongest one.
        let bassBand = levels.indices.min(by: { levels[$0] > levels[$1] }).flatMap { _ in
            levels.firstIndex(of: levels.max() ?? 0)
        } ?? 0
        let settled = levels[bassBand]

        // A kick: +5 dB for a few blocks — all the short-term movement a
        // heavily compressed master gives you.
        let kick = base * powf(10, 5.0 / 20.0)
        var peak = settled
        for _ in 0..<6 {
            let out = analyzer.ingestForTesting(toneBlock(amplitude: kick, phase: &phase))
            peak = max(peak, out[bassBand])
        }

        // Back to base; let the decay run.
        var trough = peak
        for _ in 0..<30 {
            let out = analyzer.ingestForTesting(toneBlock(amplitude: base, phase: &phase))
            trough = min(trough, out[bassBand])
        }

        // The visible swing a 5 dB kick produces. Under the old absolute
        // mapping this was ~5/26 ≈ 0.19 of the bar at best — bars that barely
        // twitch. The beat-emphasis mapping must at least double that.
        print("SpectrumBeatTests swing: peak \(peak), trough \(trough), swing \(peak - trough)")
        // 0.45 is the honest figure with audio-time-driven averages (the
        // trough is the designed resting point, not zero); the old absolute
        // mapping managed ~0.19.
        XCTAssertGreaterThanOrEqual(peak - trough, 0.45,
            "a 5 dB kick should visibly move the bar (peak \(peak), trough \(trough))")
    }

    func testSilenceProducesNoPhantomBars() {
        let analyzer = SpectrumAnalyzer(bandCount: 16)
        var levels: [Float] = []
        let silence = [Float](repeating: 0, count: blockSize)
        for _ in 0..<40 {
            levels = analyzer.ingestForTesting(silence)
        }
        // The beat term reads "exactly at its own average" as a mid-level bar;
        // without the audibility gate, silence would render a healthy wave and
        // hold the pill open forever.
        XCTAssertLessThanOrEqual(levels.max() ?? 0, 0.05,
            "silent input must not produce visible bars (got \(levels))")
    }
}
