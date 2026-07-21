import XCTest
import AppKit
import SwiftUI
@testable import Ledge

/// Feeds synthetic covers through the real accent pipeline
/// (`ArtworkColor.accents(from:)`) and checks the three behaviours that make
/// the tints read like the iPhone's: a vivid cover keeps its hue, a
/// near-monochrome cover gets a *muted* tint of its cast (not white, not
/// neon), and a two-colour cover yields a real secondary instead of a mud
/// average.
final class ArtworkColorTests: XCTestCase {

    // MARK: Synthetic covers

    /// Renders `draw` into a `side`×`side` bitmap and returns it as PNG data,
    /// the same shape real artwork arrives in.
    private func pngCover(side: Int = 64, draw: (CGContext) -> Void) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        draw(context)
        let image = try XCTUnwrap(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func hsb(_ color: Color) throws -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let ns = try XCTUnwrap(NSColor(color).usingColorSpace(.deviceRGB))
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }

    // MARK: Tests

    func testSolidRedCoverYieldsARedAccent() throws {
        let data = try pngCover { ctx in
            ctx.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let accents = try XCTUnwrap(ArtworkColor.accents(from: data))
        let (hue, saturation, _) = try hsb(accents.primary)
        // Red sits at the hue circle's seam.
        XCTAssertTrue(hue < 0.08 || hue > 0.92, "expected a red hue, got \(hue)")
        XCTAssertGreaterThanOrEqual(saturation, 0.30, "a vivid cover must keep a clearly visible saturation")
    }

    func testNearMonochromeCoverGetsAMutedTintNotWhite() throws {
        // 95% gray with a small vivid blue patch — the patch is too small to
        // count as dominant (< 10%) but big enough (> 3%) to tint the accent.
        let data = try pngCover { ctx in
            ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.95, alpha: 1))
            ctx.fill(CGRect(x: 24, y: 24, width: 17, height: 17))
        }
        let accents = try XCTUnwrap(ArtworkColor.accents(from: data))
        let (hue, saturation, brightness) = try hsb(accents.primary)
        XCTAssertLessThan(saturation, 0.40, "the tint must stay washed out, not boosted to vivid")
        XCTAssertGreaterThan(saturation, 0.0, "but it must not collapse to plain white either")
        XCTAssertGreaterThanOrEqual(brightness, 0.85)
        XCTAssertEqual(hue, 0.63, accuracy: 0.12, "the tint should keep the blue cast's hue, got \(hue)")
    }

    func testAFaceOnAWhiteSleeveYieldsSilverNotSkinOrange() throws {
        // Mostly white/grey with a large pale skin-tone region — the layout of
        // countless portrait covers. Pure hue voting picks the skin (grey
        // can't vote) and stage-vivids it into orange; the honest accent for
        // this sleeve is neutral.
        let data = try pngCover { ctx in
            ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            ctx.setFillColor(CGColor(red: 0.85, green: 0.66, blue: 0.55, alpha: 1))
            ctx.fill(CGRect(x: 18, y: 14, width: 30, height: 36))
        }
        let accents = try XCTUnwrap(ArtworkColor.accents(from: data))
        let (_, saturation, brightness) = try hsb(accents.primary)
        XCTAssertLessThanOrEqual(saturation, 0.05, "a pale face must not become the accent (saturation \(saturation))")
        XCTAssertGreaterThanOrEqual(brightness, 0.85)
    }

    func testAVividLogoOnAWhiteSleeveStillWins() throws {
        // The counter-case the neutral contest must not break: a saturated red
        // mark on white is a deliberate accent and should tint the wave.
        let data = try pngCover { ctx in
            ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            ctx.setFillColor(CGColor(red: 0.85, green: 0.08, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 26, height: 26))
        }
        let accents = try XCTUnwrap(ArtworkColor.accents(from: data))
        let (hue, saturation, _) = try hsb(accents.primary)
        XCTAssertTrue(hue < 0.08 || hue > 0.92, "the red mark should win (hue \(hue))")
        XCTAssertGreaterThanOrEqual(saturation, 0.30)
    }

    func testTwoColourCoverYieldsBothAccentsAndNeverBrown() throws {
        // Half red, half green — the failure mode of averaging is brown.
        let data = try pngCover { ctx in
            ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
            ctx.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.15, alpha: 1))
            ctx.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        }
        let accents = try XCTUnwrap(ArtworkColor.accents(from: data))
        let (hue, saturation, _) = try hsb(accents.primary)
        let isRed = hue < 0.08 || hue > 0.92
        let isGreen = abs(hue - 1.0 / 3.0) < 0.10
        XCTAssertTrue(isRed || isGreen, "primary must be one of the cover's colours, not a brown average (hue \(hue))")
        XCTAssertGreaterThanOrEqual(saturation, 0.30)

        let secondary = try XCTUnwrap(accents.secondary, "a genuinely two-colour cover must yield a secondary accent")
        let (secondaryHue, _, _) = try hsb(secondary)
        let d = abs(secondaryHue - hue)
        XCTAssertGreaterThanOrEqual(min(d, 1 - d), 1.0 / 6.0, "the secondary must be a different colour family")
    }
}
