import AppKit
import CoreImage
import SwiftUI

/// Derives a single vibrant accent colour from album artwork — used to tint the
/// now-playing wave visualizer so it matches the cover. Downscales via
/// `CIAreaAverage` (cheap, one 1×1 render) and then pushes saturation/brightness
/// up, since a raw average of a busy cover is usually a muddy grey.
enum ArtworkColor {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])
    private static var cache: [URL: Color] = [:]

    /// Loads `url` off the main thread and calls back on the main thread with a
    /// tint, or nil if it couldn't be derived. Results are cached per URL.
    static func fetch(from url: URL, completion: @escaping (Color?) -> Void) {
        if let cached = cache[url] {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let color = data(for: url).flatMap(average(of:)).map(vibrant(_:))
            DispatchQueue.main.async {
                if let color { cache[url] = color }
                completion(color)
            }
        }
    }

    private static func data(for url: URL) -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }
        return try? Data(contentsOf: url)   // artwork URLs are small remote JPEGs
    }

    /// Average colour of the image as RGB in 0...1.
    private static func average(of data: Data) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let image = CIImage(data: data) else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ]), let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (CGFloat(bitmap[0]) / 255, CGFloat(bitmap[1]) / 255, CGFloat(bitmap[2]) / 255)
    }

    /// Boost the muddy average into something that reads as the cover's accent.
    private static func vibrant(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Color {
        let ns = NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).usingColorSpace(.deviceRGB)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let saturation = min(1, max(0.55, s * 1.8))
        let brightness = min(1, max(0.7, b * 1.25))
        return Color(hue: h, saturation: saturation, brightness: brightness)
    }
}
