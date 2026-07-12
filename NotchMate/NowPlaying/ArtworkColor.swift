import AppKit
import CoreImage
import SwiftUI

/// Derives a single vibrant accent colour from album artwork — used to tint the
/// now-playing wave visualizer so it matches the cover.
///
/// A plain pixel average (`CIAreaAverage`) blends *all* regions of the cover
/// into one value, which reads as a muddy brown/olive whenever the artwork has
/// two or more distinct saturated regions (say, a red logo on a green
/// background) — averaging red and green lands roughly on brown/yellow, which
/// looks like neither. Instead this buckets pixels by hue and picks whichever
/// saturated hue actually dominates the cover, so a mostly-red-and-green image
/// comes out red or green (whichever has more weight) rather than their
/// blended midpoint.
///
/// A tiny splash of colour (a hand, a logo, a sliver of coloured spine on an
/// otherwise black-and-white cover) is deliberately *not* enough to win: the
/// winning hue bucket must account for a real share of the whole image
/// (`minimumDominantShare`). When nothing clears that bar — a genuinely
/// grayscale/monochrome cover — this returns white rather than an unrelated
/// default colour, since white is the neutral "no real colour here" answer.
enum ArtworkColor {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])
    private static var cache: [URL: Color] = [:]
    private static var iconCache: [String: Color] = [:]

    /// Loads `url` off the main thread and calls back on the main thread with a
    /// tint, or nil if it couldn't be derived. Results are cached per URL.
    static func fetch(from url: URL, completion: @escaping (Color?) -> Void) {
        if let cached = cache[url] {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let color = data(for: url).flatMap(dominantColor(from:))
            DispatchQueue.main.async {
                if let color { cache[url] = color }
                completion(color)
            }
        }
    }

    /// Same idea as `fetch(from:completion:)`, but for an in-memory app icon
    /// (the collapsed pill's generic-audio fallback, e.g. Safari) rather than a
    /// remote/file artwork URL — used to tint that wave the same way a track's
    /// cover tints it, instead of leaving it flat white. Cached by `cacheKey`
    /// (the source app's bundle ID) since an `NSImage` isn't itself hashable.
    static func fetch(from image: NSImage, cacheKey: String, completion: @escaping (Color?) -> Void) {
        if let cached = iconCache[cacheKey] {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let color = pngData(from: image).flatMap(dominantColor(from:))
            DispatchQueue.main.async {
                if let color { iconCache[cacheKey] = color }
                completion(color)
            }
        }
    }

    private static func data(for url: URL) -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }
        return try? Data(contentsOf: url)   // artwork URLs are small remote JPEGs
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A winning hue bucket must contain at least this fraction of all sampled
    /// pixels to count as "dominant" — otherwise it's just a small coloured
    /// detail on an essentially monochrome cover, not a real accent.
    private static let minimumDominantShare: Double = 0.10

    /// Downscales to a small grid, buckets pixels by hue (skipping washed-out
    /// near-gray/near-black/near-white ones, which carry no real colour
    /// information), and picks the bucket with the most saturation-weighted
    /// mass — i.e. the hue that actually dominates the artwork. Falls back to
    /// white if no bucket reaches `minimumDominantShare` of the image, and to
    /// nil (caller decides its own default) only when the image couldn't be
    /// read/decoded at all.
    private static func dominantColor(from data: Data) -> Color? {
        guard let image = CIImage(data: data) else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let side: CGFloat = 32
        let scale = side / max(extent.width, extent.height)
        guard let scaleFilter = CIFilter(name: "CILanczosScaleTransform", parameters: [
            kCIInputImageKey: image,
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0,
        ]), let scaled = scaleFilter.outputImage else { return nil }

        let width = Int(scaled.extent.width.rounded(.down))
        let height = Int(scaled.extent.height.rounded(.down))
        guard width > 0, height > 0 else { return nil }

        var bitmap = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            scaled, toBitmap: &bitmap, rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let bucketCount = 24
        var bucketWeight = [CGFloat](repeating: 0, count: bucketCount)
        var bucketR = [CGFloat](repeating: 0, count: bucketCount)
        var bucketG = [CGFloat](repeating: 0, count: bucketCount)
        var bucketB = [CGFloat](repeating: 0, count: bucketCount)
        var bucketPixelCount = [Int](repeating: 0, count: bucketCount)
        let totalPixelCount = width * height

        for i in stride(from: 0, to: bitmap.count, by: 4) {
            let r = CGFloat(bitmap[i]) / 255
            let g = CGFloat(bitmap[i + 1]) / 255
            let b = CGFloat(bitmap[i + 2]) / 255
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            NSColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            // Skip only genuinely gray/black/white pixels: they don't belong to
            // any real hue and would otherwise dilute every bucket evenly. Kept
            // deliberately loose — the s*s weighting below already lets truly
            // pastel pixels fade out on their own; a strict cutoff here was
            // throwing out most of a typical (slightly muted, JPEG-compressed)
            // cover.
            guard s > 0.06, v > 0.05, v < 0.98 else { continue }
            let bucket = min(bucketCount - 1, Int(h * CGFloat(bucketCount)))
            // s² alone let a large area of dark-but-saturated shadow/background
            // (a deep teal-black gradient, say) outvote a smaller, brighter,
            // obviously-the-accent region — dark colours can be just as
            // colorimetrically saturated as bright ones, but read as "shadow"
            // rather than "the cover's colour". The extra v² factor makes
            // brightness pull its own weight alongside saturation, so a bright
            // vivid patch reliably beats a dim one of similar hue-purity even
            // when the dim one covers more pixels. Verified against a
            // magenta-swirl-on-dark-teal cover (Linkin Park, "Over Each
            // Other") that was picking the teal background before this.
            let weight = s * s * v * v
            bucketWeight[bucket] += weight
            bucketR[bucket] += r * weight
            bucketG[bucket] += g * weight
            bucketB[bucket] += b * weight
            bucketPixelCount[bucket] += 1
        }

        guard let winner = bucketWeight.indices.max(by: { bucketWeight[$0] < bucketWeight[$1] }),
              bucketWeight[winner] > 0,
              Double(bucketPixelCount[winner]) / Double(totalPixelCount) >= minimumDominantShare
        else { return .white }

        return vibrant((
            r: bucketR[winner] / bucketWeight[winner],
            g: bucketG[winner] / bucketWeight[winner],
            b: bucketB[winner] / bucketWeight[winner]
        ))
    }

    /// Boost the muddy average into something that reads as the cover's accent.
    private static func vibrant(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Color {
        let ns = NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).usingColorSpace(.deviceRGB)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let saturation = min(1, max(0.65, s * 2.0))
        let brightness = min(1, max(0.8, b * 1.3))
        return Color(hue: h, saturation: saturation, brightness: brightness)
    }
}
