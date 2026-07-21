import AppKit
import CoreImage
import SwiftUI

/// The taste-dependent half of the bar-palette computation, read from
/// `UserSettings` on the main thread and handed to `ArtworkColor` so the
/// background work never touches the settings object. Equatable so a changed
/// value can invalidate the cache.
struct CoverBarTuning: Equatable {
    var paletteSize: Int
    var brightnessLevels: Int
    var saturation: CGFloat
    var brightness: CGFloat

    init(settings: UserSettings = .shared) {
        paletteSize = max(1, min(5, settings.coverPaletteSize))
        brightnessLevels = max(1, min(4, settings.coverBrightnessLevels))
        saturation = CGFloat(settings.coverBarSaturation)
        brightness = CGFloat(settings.coverBarBrightness)
    }
}

/// Quantised cover colours for the `.coverImage` spectrum style: one colour per
/// bar, taken from the vertical slice of cover that bar sits over (left bar =
/// left of cover), split into the slice's top and bottom half so a bar keeps a
/// faint cover-derived gradient.
///
/// Precomputed per bar count rather than per fixed column: which colour wins a
/// slice depends on how wide the slice is, so five bars are not just six bars
/// resampled. The collapsed pill and the expanded wave draw different counts,
/// hence a small table.
/// The accents a cover actually contains: the dominant hue, plus — when the
/// artwork really has them — up to two more colour families (secondary at
/// least 60° from the winner, tertiary at least 45° from both). They feed the
/// `gradient`/`alternating` styles in "Vom Cover" mode, so the wave runs
/// through colours the sleeve actually contains instead of synthetic shifts.
struct ArtworkAccents: Equatable {
    let primary: Color
    let secondary: Color?
    let tertiary: Color?

    init(primary: Color, secondary: Color? = nil, tertiary: Color? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
    }
}

struct CoverBarPalette: Equatable {
    struct Bar: Equatable {
        let top: Color
        let bottom: Color
    }

    /// Bar counts the table is built for — the pill's (5, or 16 in
    /// spectrum-only mode) and the music tab's (6).
    static let supportedBarCounts = [3, 4, 5, 6, 7, 8, 16]

    let bars: [Int: [Bar]]

    func pair(forBarAt index: Int, total: Int) -> (top: Color, bottom: Color)? {
        // Fall back to the nearest count we did compute rather than drawing
        // nothing, if a caller ever asks for an unsupported bar count.
        let row = bars[total] ?? bars[Self.supportedBarCounts.min {
            abs($0 - total) < abs($1 - total)
        } ?? 5]
        guard let row, index >= 0, !row.isEmpty else { return nil }
        let bar = row[min(index, row.count - 1)]
        return (bar.top, bar.bottom)
    }
}

/// Derives a single vibrant accent colour from album artwork — used to tint the
/// now-playing wave visualizer so it matches the cover — and the quantised
/// per-column palette the `.coverImage` bar style draws with.
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
    private static var cache: [URL: ArtworkAccents] = [:]
    private static var iconCache: [String: Color] = [:]
    private static var barPaletteCache: [URL: CoverBarPalette] = [:]
    private static var cachedTuning = CoverBarTuning()

    /// Loads `url` off the main thread and calls back on the main thread with
    /// the cover's accents, or nil if they couldn't be derived. Results are
    /// cached per URL.
    static func fetch(from url: URL, completion: @escaping (ArtworkAccents?) -> Void) {
        if let cached = cache[url] {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let result = data(for: url).flatMap(accents(from:))
            DispatchQueue.main.async {
                if let result { cache[url] = result }
                completion(result)
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
            let color = pngData(from: image).flatMap { accents(from: $0)?.primary }
            DispatchQueue.main.async {
                if let color { iconCache[cacheKey] = color }
                completion(color)
            }
        }
    }

    /// Quantised per-column cover colours for the `.coverImage` spectrum style.
    /// Results are cached per URL.
    static func fetchBarPalette(from url: URL, tuning: CoverBarTuning, completion: @escaping (CoverBarPalette?) -> Void) {
        // The cache holds colours computed for one particular tuning, so a
        // changed slider has to throw it away rather than serve stale values.
        if tuning != cachedTuning {
            cachedTuning = tuning
            barPaletteCache.removeAll()
        }
        if let cached = barPaletteCache[url] {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let palette = data(for: url).flatMap { barPalette(from: $0, tuning: tuning) }
            DispatchQueue.main.async {
                if let palette { barPaletteCache[url] = palette }
                completion(palette)
            }
        }
    }

    /// The most recently loaded cover, kept so re-deriving the palette (which
    /// happens on every tuning change, i.e. on every step of a slider drag)
    /// doesn't re-download the JPEG each time. One entry is enough: only the
    /// current track's cover is ever recomputed.
    private static var lastImageData: (url: URL, data: Data)?
    private static let imageDataLock = NSLock()

    private static func data(for url: URL) -> Data? {
        imageDataLock.lock()
        let cached = lastImageData
        imageDataLock.unlock()
        if let cached, cached.url == url { return cached.data }

        guard let data = try? Data(contentsOf: url) else { return nil }
        imageDataLock.lock()
        lastImageData = (url, data)
        imageDataLock.unlock()
        return data
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A winning hue bucket must contain at least this fraction of all sampled
    /// pixels to count as "dominant" — otherwise it's just a small coloured
    /// detail on an essentially monochrome cover, not a real accent.
    private static let minimumDominantShare: Double = 0.10

    /// One hue bucket's saturation-weighted average colour plus how much of the
    /// image it covers, as produced by `hueBuckets(from:)`.
    private struct HueBucket {
        var rgb: (r: CGFloat, g: CGFloat, b: CGFloat)
        var share: Double
    }

    /// What `hueBuckets(from:)` found: the hue buckets themselves plus how much
    /// of the cover carries no hue at all (the black/white/grey pixels the
    /// buckets deliberately ignore). The bar palette needs that neutral share —
    /// a cover that's half white lettering on red shouldn't have its white half
    /// snapped onto the red.
    private struct HueAnalysis {
        var buckets: [HueBucket]
        var neutralShare: Double
        /// Average brightness of those neutral pixels (0…1).
        var neutralLuma: CGFloat
    }

    /// Renders `data` into an RGBA8 grid of at most `side` × `side` pixels.
    private static func sample(_ data: Data, side: CGFloat) -> (bitmap: [UInt8], width: Int, height: Int)? {
        guard let image = CIImage(data: data) else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

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
        return (bitmap, width, height)
    }

    /// Buckets the cover's pixels by hue (skipping washed-out
    /// near-gray/near-black/near-white ones, which carry no real colour
    /// information) and returns the non-empty buckets ordered by
    /// saturation-weighted mass — i.e. the hues that actually dominate the
    /// artwork, strongest first. nil only when the image couldn't be
    /// read/decoded at all.
    private static func hueBuckets(from data: Data) -> HueAnalysis? {
        guard let (bitmap, width, height) = sample(data, side: 32) else { return nil }

        let bucketCount = 24
        var bucketWeight = [CGFloat](repeating: 0, count: bucketCount)
        var bucketR = [CGFloat](repeating: 0, count: bucketCount)
        var bucketG = [CGFloat](repeating: 0, count: bucketCount)
        var bucketB = [CGFloat](repeating: 0, count: bucketCount)
        var bucketPixelCount = [Int](repeating: 0, count: bucketCount)
        var neutralPixelCount = 0
        var neutralLumaSum: CGFloat = 0
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
            guard s > 0.06, v > 0.05, v < 0.98 else {
                neutralPixelCount += 1
                neutralLumaSum += v
                continue
            }
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

        let buckets = bucketWeight.indices
            .filter { bucketWeight[$0] > 0 }
            .sorted { bucketWeight[$0] > bucketWeight[$1] }
            .map { i in
                HueBucket(
                    rgb: (bucketR[i] / bucketWeight[i], bucketG[i] / bucketWeight[i], bucketB[i] / bucketWeight[i]),
                    share: Double(bucketPixelCount[i]) / Double(totalPixelCount)
                )
            }
        return HueAnalysis(
            buckets: buckets,
            neutralShare: Double(neutralPixelCount) / Double(totalPixelCount),
            neutralLuma: neutralPixelCount > 0 ? neutralLumaSum / CGFloat(neutralPixelCount) : 1
        )
    }

    /// A bucket below `minimumDominantShare` but at or above this still tints
    /// the accent: a black-and-white cover with a faint colour cast gets a
    /// desaturated version of that cast (the way the iPhone tints slightly
    /// coloured monochrome sleeves) instead of snapping to plain white. Only
    /// genuinely hue-free covers stay white.
    private static let minimumMutedShare: Double = 0.03

    /// A second accent must cover at least this much of the image and sit at
    /// least `minimumSecondaryHueDistance` away from the winner's hue —
    /// otherwise it's the same colour family and no real second accent exists.
    private static let minimumSecondaryShare: Double = 0.05
    /// 60° on the hue circle (distances measured as `min(d, 1-d)`, 0…0.5).
    private static let minimumSecondaryHueDistance: CGFloat = 1.0 / 6.0
    /// The third accent can be smaller and closer (45°) — by the time a cover
    /// has three real colour families, the third is usually an accent stripe,
    /// not a region.
    private static let minimumTertiaryShare: Double = 0.04
    private static let minimumTertiaryHueDistance: CGFloat = 0.125

    /// The accents that dominate the artwork. `primary` falls back to a muted
    /// tint (near-monochrome cover) or white (no hue at all); nil only when
    /// the image couldn't be read/decoded. Internal rather than private so the
    /// unit tests can feed synthetic covers through the real pipeline.
    static func accents(from data: Data) -> ArtworkAccents? {
        guard let analysis = hueBuckets(from: data) else { return nil }
        guard let winner = analysis.buckets.first else {
            return ArtworkAccents(primary: .white, secondary: nil)
        }
        guard winner.share >= minimumDominantShare else {
            let primary = winner.share >= minimumMutedShare ? mutedTint(winner.rgb) : .white
            return ArtworkAccents(primary: primary, secondary: nil)
        }
        let winnerHue = hue(of: winner.rgb)
        func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let d = abs(a - b)
            return min(d, 1 - d)
        }
        let secondary = analysis.buckets.dropFirst().first { bucket in
            bucket.share >= minimumSecondaryShare
                && hueDistance(hue(of: bucket.rgb), winnerHue) >= minimumSecondaryHueDistance
        }
        let secondaryHue = secondary.map { hue(of: $0.rgb) }
        let tertiary = secondary == nil ? nil : analysis.buckets.dropFirst().first { bucket in
            guard bucket.share >= minimumTertiaryShare else { return false }
            let h = hue(of: bucket.rgb)
            return hueDistance(h, winnerHue) >= minimumTertiaryHueDistance
                && hueDistance(h, secondaryHue ?? 0) >= minimumTertiaryHueDistance
        }
        return ArtworkAccents(
            primary: vibrant(winner.rgb),
            secondary: secondary.map { vibrant($0.rgb) },
            tertiary: tertiary.map { vibrant($0.rgb) }
        )
    }

    /// The accent for an essentially monochrome cover with a faint colour
    /// cast: keep the cast's hue but stay deliberately washed out — boosting
    /// it to full vibrancy would invent a colour the sleeve doesn't have.
    private static func mutedTint(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Color {
        let ns = NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).usingColorSpace(.deviceRGB)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(0.35, s * 0.8), brightness: max(0.85, b))
    }

    // MARK: Bar palette (`.coverImage` spectrum style)

    /// Resolution the cover is sampled at. Each bar's slice has to hold enough
    /// pixels for the per-slice vote to mean something — at eight bars and a
    /// 12 % border inset this still leaves roughly 4 × 36 pixels per slice.
    private static let barSampleSide: CGFloat = 48

    /// Fraction of the cover ignored on every edge before it is split into
    /// columns. The outermost columns otherwise sit right on the sleeve's
    /// border — a frame, a vignette, the darkened edge of a photo — so the
    /// first and last bar would take their colour from the one part of the
    /// artwork that says nothing about it, and visibly break rank.
    private static let barSampleInset: Double = 0.12

    /// A hue must cover at least this share of the cover to earn a slot in the
    /// palette — lower than `minimumDominantShare`, since a secondary colour
    /// legitimately covers less ground than the dominant one.
    private static let minimumPaletteShare: Double = 0.035

    /// Minimum hue distance (0…0.5, i.e. up to 180°) between two palette
    /// entries. Measured on hue rather than RGB because that is what decides
    /// whether two entries read as *different colours*: a light and a dark blue
    /// sit far apart in RGB but should still collapse into one bar colour,
    /// while blue and green sit closer in RGB yet clearly deserve two slots.
    private static let minimumPaletteHueSeparation: CGFloat = 0.05

    /// Black/white/grey regions get their own palette slot once they cover this
    /// much of the cover, instead of being snapped onto the nearest hue — white
    /// lettering across a red sleeve should stay white, not turn pink.
    private static let minimumNeutralShare: Double = 0.25

    /// Saturation the neutral slot is drawn with when the cover has a hue to
    /// borrow. Not zero: a pure-white bar beside coloured ones reads as a
    /// different *thing*, and since the neutral regions are usually the cover's
    /// background, that lands on the outermost bars and makes the wave look
    /// broken at both ends. A washed-out version of the cover's own hue keeps
    /// every bar in one family while still reading as "no colour here".
    private static let neutralTintSaturation: CGFloat = 0.22

    /// The region of the sampled grid the bars are cut from, with the border
    /// inset already taken off (see `barSampleInset`).
    private struct SampleGeometry {
        let x0: Int, x1: Int, y0: Int, y1: Int
        var usableX: Int { x1 - x0 }
        var usableY: Int { y1 - y0 }

        init(width: Int, height: Int) {
            let insetX = Int(Double(width) * barSampleInset)
            let insetY = Int(Double(height) * barSampleInset)
            x0 = insetX
            x1 = width - insetX
            y0 = insetY
            y1 = height - insetY
        }
    }

    /// How dark the darkest brightness step draws, as a fraction of the palette
    /// colour's own brightness. Not lower: these bars sit on a black notch, and
    /// a genuinely dark one just looks like it is missing.
    private static let barDarkestLevel: CGFloat = 0.68

    /// The cell's brightness, snapped to `levels` steps and returned as 0…1.
    /// A single level means "flat colour" and always returns the top step.
    private static func brightnessLevel(of rgb: (r: CGFloat, g: CGFloat, b: CGFloat), levels: Int) -> CGFloat {
        guard levels > 1 else { return 1 }
        let v = max(rgb.r, max(rgb.g, rgb.b))
        let step = min(CGFloat(levels - 1), (v * CGFloat(levels)).rounded(.down))
        return step / CGFloat(levels - 1)
    }

    /// Two-stage quantisation, which is what makes the bars read as the cover
    /// rather than as a smear of it:
    ///
    /// 1. **Globally**, the whole cover is reduced to at most
    ///    `tuning.paletteSize` colours (plus a neutral slot where the sleeve
    ///    has a large black/white/grey area). Every pixel is assigned to one.
    /// 2. **Per bar**, the cover is cut into as many vertical slices as there
    ///    are bars, and each slice elects the colour that covers the most of
    ///    it. Top and bottom half vote separately, which is where the bar's
    ///    faint gradient comes from.
    ///
    /// The election is the point. Averaging a slice first — what this used to
    /// do — invents colours the sleeve doesn't contain (red lettering on white
    /// averages to pink) and washes out exactly the covers with the most
    /// character.
    private static func barPalette(from data: Data, tuning: CoverBarTuning) -> CoverBarPalette? {
        guard let (bitmap, width, height) = sample(data, side: barSampleSide),
              width > 2, height > 3
        else { return nil }

        let geometry = SampleGeometry(width: width, height: height)

        // A palette entry matches on the *raw* cover colour and draws as the
        // vibrancy-boosted one — matching against the boosted version would
        // measure the boost rather than the artwork.
        let analysis = hueBuckets(from: data)
        var palette: [(match: (r: CGFloat, g: CGFloat, b: CGFloat), color: Color)] = []
        for bucket in (analysis?.buckets ?? []) where bucket.share >= minimumPaletteShare {
            guard palette.count < tuning.paletteSize else { break }
            // Neighbouring hue buckets often describe the same colour region
            // (two shades of the same blue). Spending a palette slot on each
            // would split bars that should read as one colour, so a new entry
            // has to be visibly different from the ones already taken.
            let hue = hue(of: bucket.rgb)
            let tooClose = palette.contains { entry in
                let d = abs(hue - self.hue(of: entry.match))
                return min(d, 1 - d) < minimumPaletteHueSeparation
            }
            if tooClose { continue }
            palette.append((bucket.rgb, barVibrant(bucket.rgb, tuning: tuning)))
        }
        if let analysis, analysis.neutralShare >= minimumNeutralShare {
            let luma = analysis.neutralLuma
            // Drawn brighter than measured — a mid-grey bar on the black notch
            // reads as missing rather than as part of the wave — and tinted
            // towards the cover's dominant hue where there is one.
            let brightness = clamped(min(0.88, max(0.7, luma * 1.4)) * tuning.brightness)
            let color = palette.first.map {
                Color(hue: hue(of: $0.match), saturation: clamped(neutralTintSaturation * tuning.saturation), brightness: brightness)
            } ?? Color(white: brightness)
            palette.append(((luma, luma, luma), color))
        }

        // Stage one, global: every pixel of the cover is assigned to the palette
        // entry it is closest to. From here on the cover *is* those few colours.
        guard !palette.isEmpty else { return grayscaleBarPalette(bitmap: bitmap, width: width, geometry: geometry, tuning: tuning) }
        var indexOf = [Int](repeating: 0, count: width * height)
        var brightnessOf = [CGFloat](repeating: 0, count: width * height)
        for y in geometry.y0..<geometry.y1 {
            for x in geometry.x0..<geometry.x1 {
                let i = (y * width + x) * 4
                let rgb = (
                    r: CGFloat(bitmap[i]) / 255,
                    g: CGFloat(bitmap[i + 1]) / 255,
                    b: CGFloat(bitmap[i + 2]) / 255
                )
                var best = 0
                var bestDistance = CGFloat.greatestFiniteMagnitude
                for (index, entry) in palette.enumerated() {
                    let d = (entry.match.r - rgb.r) * (entry.match.r - rgb.r)
                        + (entry.match.g - rgb.g) * (entry.match.g - rgb.g)
                        + (entry.match.b - rgb.b) * (entry.match.b - rgb.b)
                    if d < bestDistance { bestDistance = d; best = index }
                }
                indexOf[y * width + x] = best
                brightnessOf[y * width + x] = max(rgb.r, max(rgb.g, rgb.b))
            }
        }

        // Stage two, per bar: each bar owns a vertical slice of the cover and
        // takes the colour that covers the most ground *within that slice* —
        // a vote, not an average. Averaging was the flaw in the earlier
        // version: a slice of red lettering on white averages to pink, which
        // is a colour that appears nowhere on the sleeve. The winner here is
        // always a colour the cover actually has, in the place the bar sits.
        func barColor(x0: Int, x1: Int, y0: Int, y1: Int) -> Color {
            var votes = [Int](repeating: 0, count: palette.count)
            var brightnessSum = [CGFloat](repeating: 0, count: palette.count)
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let index = indexOf[y * width + x]
                    votes[index] += 1
                    brightnessSum[index] += brightnessOf[y * width + x]
                }
            }
            guard let winner = votes.indices.max(by: { votes[$0] < votes[$1] }), votes[winner] > 0 else {
                return palette[0].color
            }
            // Brightness comes from the winning colour's own pixels in this
            // slice, so a bar over a shaded part of one flat colour still reads
            // darker than a bar over its lit part.
            let mean = brightnessSum[winner] / CGFloat(votes[winner])
            let level = brightnessLevel(of: (mean, mean, mean), levels: tuning.brightnessLevels)
            return shadedStep(palette[winner].color, level: level)
        }

        // Image rows run top-down, and so do the bars, so row 0 is the bar's top.
        var bars: [Int: [CoverBarPalette.Bar]] = [:]
        for count in CoverBarPalette.supportedBarCounts {
            bars[count] = (0..<count).map { index in
                let x0 = geometry.x0 + index * geometry.usableX / count
                let x1 = max(x0 + 1, geometry.x0 + (index + 1) * geometry.usableX / count)
                let midY = geometry.y0 + geometry.usableY / 2
                return CoverBarPalette.Bar(
                    top: barColor(x0: x0, x1: min(x1, geometry.x1), y0: geometry.y0, y1: max(geometry.y0 + 1, midY)),
                    bottom: barColor(x0: x0, x1: min(x1, geometry.x1), y0: midY, y1: geometry.y1)
                )
            }
        }
        return CoverBarPalette(bars: bars)
    }

    /// The palette colour at one of `brightnessLevels` steps — same hue and
    /// saturation, only the light changes, so bars sharing a colour still read
    /// as one family.
    private static func shadedStep(_ color: Color, level: CGFloat) -> Color {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: s, brightness: b * (barDarkestLevel + (1 - barDarkestLevel) * level))
    }

    /// Fallback for a cover with no dominant hue and no large neutral area:
    /// the same per-slice vote, but over brightness steps alone, so the bars
    /// go grey rather than borrowing a hue that isn't there.
    private static func grayscaleBarPalette(
        bitmap: [UInt8], width: Int, geometry: SampleGeometry, tuning: CoverBarTuning
    ) -> CoverBarPalette {
        func barColor(x0: Int, x1: Int, y0: Int, y1: Int) -> Color {
            var sum: CGFloat = 0, n: CGFloat = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * width + x) * 4
                    sum += 0.299 * CGFloat(bitmap[i]) / 255
                        + 0.587 * CGFloat(bitmap[i + 1]) / 255
                        + 0.114 * CGFloat(bitmap[i + 2]) / 255
                    n += 1
                }
            }
            let mean = n > 0 ? sum / n : 1
            let level = brightnessLevel(of: (mean, mean, mean), levels: tuning.brightnessLevels)
            return Color(white: clamped((0.55 + 0.4 * level) * tuning.brightness))
        }

        var bars: [Int: [CoverBarPalette.Bar]] = [:]
        for count in CoverBarPalette.supportedBarCounts {
            bars[count] = (0..<count).map { index in
                let x0 = geometry.x0 + index * geometry.usableX / count
                let x1 = max(x0 + 1, geometry.x0 + (index + 1) * geometry.usableX / count)
                let midY = geometry.y0 + geometry.usableY / 2
                return CoverBarPalette.Bar(
                    top: barColor(x0: x0, x1: min(x1, geometry.x1), y0: geometry.y0, y1: max(geometry.y0 + 1, midY)),
                    bottom: barColor(x0: x0, x1: min(x1, geometry.x1), y0: midY, y1: geometry.y1)
                )
            }
        }
        return CoverBarPalette(bars: bars)
    }

    private static func hue(of rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return h
    }

    /// `vibrant` with a harder push, for the spectrum bars specifically: they
    /// are a couple of points wide on a black notch, where the tint's own
    /// brightness floor still comes out looking dim and glassy. Saturation stops
    /// short of the maximum so the result stays a colour, not a neon.
    private static func barVibrant(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat), tuning: CoverBarTuning) -> Color {
        let ns = NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).usingColorSpace(.deviceRGB)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Tone-mapped like `vibrant()` (see there for why), with a slightly
        // harder push and higher floors: these bars are two points wide on a
        // black notch, and legibility needs a bit more than the big accent.
        let saturation = clamped(min(0.90, max(0.40, s * 1.35)) * tuning.saturation)
        let brightness = clamped(min(0.96, max(0.72, b * 1.25)) * tuning.brightness)
        return Color(hue: h, saturation: saturation, brightness: brightness)
    }

    private static func clamped(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

    /// Boost the bucket's average into something that reads as the cover's
    /// accent — tone-mapped, not floored. The old hard floors (saturation
    /// ≥ 0.65, brightness ≥ 0.8) turned *every* cover neon and erased exactly
    /// the quality that distinguishes sleeves from one another; the iPhone's
    /// tints keep a muted cover recognizably muted. A gentle multiplier with a
    /// wide clamp lifts dull colours into legibility while leaving vivid ones
    /// nearly untouched.
    private static func vibrant(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Color {
        let ns = NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).usingColorSpace(.deviceRGB)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let saturation = min(0.92, max(0.30, s * 1.25))
        let brightness = min(0.96, max(0.68, b * 1.18))
        return Color(hue: h, saturation: saturation, brightness: brightness)
    }
}
