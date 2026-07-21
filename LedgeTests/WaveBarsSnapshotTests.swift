import XCTest
import SwiftUI
@testable import Ledge

/// Renders `WaveBarsView` offscreen — every style, plus the wide spectrum-only
/// variant — and writes PNGs to `/tmp/notchmate-wavebars/`. Primarily a visual
/// harness: the wave only exists animated on a live notch, and this is the one
/// way to look at a frozen frame of it (and to let a review judge colour
/// choices) without pointing a camera at the screen. The assertions just pin
/// that every style renders at all.
@MainActor
final class WaveBarsSnapshotTests: XCTestCase {

    private static let outputDirectory = URL(fileURLWithPath: "/tmp/notchmate-wavebars", isDirectory: true)

    /// A frozen "mid-song" frame: uneven, with a couple of peaks.
    private let bands: [CGFloat] = [
        0.35, 0.55, 0.80, 1.00, 0.70, 0.45, 0.60, 0.90,
        0.50, 0.30, 0.65, 0.85, 0.40, 0.75, 0.55, 0.25,
    ]

    func testEveryStyleRendersAndWritesASnapshot() throws {
        let settings = UserSettings.shared
        let originalStyle = settings.spectrumStyle
        let originalSource = settings.spectrumColorSource
        defer {
            settings.spectrumStyle = originalStyle
            settings.spectrumColorSource = originalSource
        }
        settings.spectrumColorSource = .cover

        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)

        // A warm red sleeve with teal and amber families — the three-stop case.
        let tint = Color(hue: 0.97, saturation: 0.75, brightness: 0.85)
        let secondary = Color(hue: 0.50, saturation: 0.65, brightness: 0.75)
        let tertiary = Color(hue: 0.10, saturation: 0.80, brightness: 0.90)

        for style in UserSettings.SpectrumStyle.allCases {
            settings.spectrumStyle = style

            // The wide spectrum-only pill layout (16 bars, 48×20 frame).
            let wave = WaveBarsView(
                isActive: true,
                tint: tint,
                secondaryTint: secondary,
                tertiaryTint: tertiary,
                bands: bands,
                count: NotchLayout.collapsedWideWaveBarCount,
                maxHeight: NotchLayout.collapsedWideWaveMaxHeight,
                barWidth: NotchLayout.collapsedWaveBarWidth,
                spacing: NotchLayout.collapsedWaveSpacing
            )
            .frame(width: NotchLayout.collapsedWideWavesWidth, height: NotchLayout.collapsedWideWaveFrameHeight)
            .padding(14)
            .background(Color.black)

            let renderer = ImageRenderer(content: wave)
            renderer.scale = 8   // 2pt bars are unjudgeable at 1:1
            let image = try XCTUnwrap(renderer.cgImage, "style \(style.rawValue) failed to render")

            let rep = NSBitmapImageRep(cgImage: image)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: Self.outputDirectory.appendingPathComponent("wave-\(style.rawValue).png"))
        }
    }
}
