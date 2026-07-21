import XCTest
import SwiftUI
@testable import NotchMate

/// End-to-end motion check: synthesizes two seconds of "music" (bass line,
/// a kick every half second, hi-hat noise), runs it through the analyzer's
/// real FFT + beat mapping, samples the band levels along the way and renders
/// the frames as one contact sheet under `/tmp/notchmate-wavebars/`. The
/// still-image harness answers "are the colours right"; this one answers
/// "does the wave actually *move* on music" — the thing that regressed
/// invisibly before, because a single frame of a dead wave looks identical
/// to a single frame of a living one.
@MainActor
final class WaveMotionContactSheetTests: XCTestCase {

    private let sampleRate = 48_000.0
    private let blockSize = 1024

    /// One audio block of the synthetic track. A 95 Hz bass line that pumps
    /// with the beat, a kick thump in the first ~80 ms of every half-second,
    /// and a little broadband noise as hi-hats.
    private func musicBlock(blockIndex: Int, phase: inout Double) -> [Float] {
        let step = 2.0 * Double.pi * 95.0 / sampleRate
        let blockTime = Double(blockIndex) * Double(blockSize) / sampleRate
        var rng = SystemRandomNumberGenerator()
        return (0..<blockSize).map { i in
            let t = blockTime + Double(i) / sampleRate
            let beatPhase = t.truncatingRemainder(dividingBy: 0.5)
            let kick: Float = beatPhase < 0.08 ? Float(1.0 - beatPhase / 0.08) : 0
            let bass = Float(sin(phase)) * (0.06 + 0.14 * kick)
            phase += step
            let hat = Float.random(in: -1...1, using: &rng) * 0.008
            return bass + hat
        }
    }

    func testMusicMovesTheWaveAcrossFrames() throws {
        let analyzer = SpectrumAnalyzer(bandCount: 16)
        var phase = 0.0
        var frames: [[CGFloat]] = []

        // ~2 seconds of audio; keep a frame every 7 blocks (~150 ms) after a
        // short warm-up for the running averages.
        var levels: [Float] = []
        for block in 0..<94 {
            levels = analyzer.ingestForTesting(musicBlock(blockIndex: block, phase: &phase))
            if block > 10, block % 7 == 0 {
                frames.append(levels.map { CGFloat($0) })
            }
        }

        // The point of the exercise: consecutive frames must differ visibly.
        let motion = zip(frames, frames.dropFirst()).map { a, b in
            zip(a, b).map { abs($0 - $1) }.max() ?? 0
        }
        XCTAssertGreaterThanOrEqual(motion.max() ?? 0, 0.25,
            "the wave should visibly move between frames (per-frame max deltas: \(motion))")

        // Render the frames as a film strip for eyes-on review.
        UserSettings.shared.spectrumColorSource = .cover
        let originalStyle = UserSettings.shared.spectrumStyle
        defer { UserSettings.shared.spectrumStyle = originalStyle }
        UserSettings.shared.spectrumStyle = .gradient

        let tint = Color(hue: 0.97, saturation: 0.75, brightness: 0.85)
        let secondary = Color(hue: 0.50, saturation: 0.65, brightness: 0.75)

        let sheet = VStack(spacing: 6) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, bands in
                WaveBarsView(
                    isActive: true,
                    tint: tint,
                    secondaryTint: secondary,
                    bands: bands,
                    count: NotchLayout.collapsedWideWaveBarCount,
                    maxHeight: NotchLayout.collapsedWideWaveMaxHeight,
                    barWidth: NotchLayout.collapsedWaveBarWidth,
                    spacing: NotchLayout.collapsedWaveSpacing
                )
                .frame(width: NotchLayout.collapsedWideWavesWidth, height: NotchLayout.collapsedWideWaveFrameHeight)
            }
        }
        .padding(12)
        .background(Color.black)

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 6
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: "/tmp/notchmate-wavebars", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("wave-motion-sheet.png"))
    }
}
