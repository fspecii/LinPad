import CoreGraphics
import Foundation
import ImageIO

// MARK: - OKLab

/// A colour in Björn Ottosson's OKLab: perceptually even, so Euclidean distance is a usable
/// ΔE and lightness/chroma/hue edits keep the colour's character.
struct OKLab: Equatable, Hashable, Sendable {
    var l: Double
    var a: Double
    var b: Double

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// From lightness, chroma and hue in degrees (OKLCh).
    init(l: Double, chroma: Double, hue: Double) {
        let radians = hue * .pi / 180
        self.init(l: l, a: chroma * cos(radians), b: chroma * sin(radians))
    }

    init(_ rgb: RGB) {
        self.init(linearRed: OKLab.linear(rgb.red), green: OKLab.linear(rgb.green), blue: OKLab.linear(rgb.blue))
    }

    init(linearRed r: Double, green g: Double, blue b: Double) {
        let lms = (cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b),
                   cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b),
                   cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b))
        l = 0.2104542553 * lms.0 + 0.7936177850 * lms.1 - 0.0040720468 * lms.2
        a = 1.9779984951 * lms.0 - 2.4285922050 * lms.1 + 0.4505937099 * lms.2
        self.b = 0.0259040371 * lms.0 + 0.7827717662 * lms.1 - 0.8086757660 * lms.2
    }

    var chroma: Double { (a * a + b * b).squareRoot() }

    /// Hue in degrees, 0 ..< 360.
    var hue: Double {
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    func distance(to other: OKLab) -> Double {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    func mix(_ other: OKLab, _ amount: Double) -> OKLab {
        OKLab(l: l + (other.l - l) * amount, a: a + (other.a - a) * amount, b: b + (other.b - b) * amount)
    }

    func with(l newL: Double) -> OKLab { OKLab(l: newL, chroma: chroma, hue: hue) }

    /// Linear sRGB, possibly outside 0…1.
    private var linearRGB: (Double, Double, Double) {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (l3, m3, s3) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        return (4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }

    var isInGamut: Bool {
        let (r, g, b) = linearRGB
        let epsilon = 1e-4
        return r >= -epsilon && r <= 1 + epsilon && g >= -epsilon && g <= 1 + epsilon && b >= -epsilon && b <= 1 + epsilon
    }

    /// The sRGB colour, brought into gamut by lowering chroma at the same lightness and hue
    /// (so a clipped accent stays the same hue instead of skewing as per-channel clamping does).
    var rgb: RGB {
        var mapped = self
        if !isInGamut {
            mapped.l = min(max(l, 0), 1)
            var low = 0.0, high = chroma
            let hue = self.hue
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if OKLab(l: mapped.l, chroma: mid, hue: hue).isInGamut { low = mid } else { high = mid }
            }
            mapped = OKLab(l: mapped.l, chroma: low, hue: hue)
        }
        let (r, g, b) = mapped.linearRGB
        return RGB(red: OKLab.gamma(r), green: OKLab.gamma(g), blue: OKLab.gamma(b))
    }

    static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func gamma(_ c: Double) -> Double {
        let clamped = min(max(c, 0), 1)
        return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    /// Circular distance between two hues in degrees (0…180).
    static func hueDistance(_ x: Double, _ y: Double) -> Double {
        let d = abs(x - y).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }
}

// MARK: - Analysis

/// What a wallpaper looks like to the matcher: its main colours by area and a few measures
/// of character (how light, how colourful, how smooth). Pure data, Sendable, made off the
/// main thread by `WallpaperAnalyzer`.
struct WallpaperAnalysis: Equatable, Sendable {
    struct Cluster: Equatable, Sendable {
        var color: OKLab
        /// Fraction of the image's area, 0…1.
        var share: Double
    }

    /// Sorted by share, largest first.
    var clusters: [Cluster]
    /// Area-weighted mean OKLab lightness.
    var meanLightness: Double
    /// Standard deviation of lightness: high for high-contrast images.
    var lightnessSpread: Double
    /// Area-weighted mean chroma: ~0 for grey images, 0.1+ for vivid ones.
    var colorfulness: Double
    /// Mean lightness step between neighbouring pixels of the downscaled image: ~0.005 for
    /// soft gradients, 0.03+ for detailed photos and pixel art.
    var edgeDensity: Double
    /// Fraction of pixels within ΔE 0.03 of their cluster: high for flat, posterised art.
    var flatness: Double

    /// Dark when the image is darker than mid grey (OKLab L 0.6 ≈ sRGB #808080 is 0.6).
    static let darkThreshold = 0.6
    /// Below this mean chroma an image counts as near-monochrome.
    static let monochromeChroma = 0.035

    var prefersDark: Bool { meanLightness < Self.darkThreshold }
    var isNearMonochrome: Bool { colorfulness < Self.monochromeChroma }
    var dominant: Cluster { clusters.first ?? Cluster(color: OKLab(l: meanLightness, a: 0, b: 0), share: 1) }

    /// Colours an accent can come from: chromatic, neither near-black nor near-white.
    var accentCandidates: [Cluster] {
        clusters.filter { $0.color.chroma >= 0.04 && $0.color.l >= 0.25 && $0.color.l <= 0.93 && $0.share >= 0.004 }
    }

    /// The most salient chromatic colour: chroma first, then area, then a mid lightness.
    var salientAccent: OKLab? {
        accentCandidates.max { saliency($0) < saliency($1) }?.color
    }

    private func saliency(_ cluster: Cluster) -> Double {
        cluster.color.chroma * cluster.share.squareRoot() * (1 - abs(cluster.color.l - 0.65))
    }

    /// Share of the image whose colour falls in a hue range (chromatic pixels only).
    func share(hues range: ClosedRange<Double>, minimumChroma: Double = 0.04) -> Double {
        clusters.filter { $0.color.chroma >= minimumChroma && range.contains($0.color.hue) }.reduce(0) { $0 + $1.share }
    }
}

/// Downscale, convert to OKLab, quantise (median cut seeded, k-means refined) and measure.
/// Deterministic: the same image always gives the same analysis.
enum WallpaperAnalyzer {
    /// Long edge of the analysed bitmap; 4K images are decoded straight to this size.
    static let sampleEdge = 96
    static let clusterCount = 12
    static let iterations = 8

    /// Decodes `url` with ImageIO's thumbnailer (JPEG/HEIC decode at reduced size, so a 4K
    /// original costs a few ms) and analyses it.
    static func analyze(url: URL) -> WallpaperAnalysis? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: sampleEdge * 3,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return analyze(image: image)
    }

    static func analyze(image: CGImage) -> WallpaperAnalysis? {
        let scale = Double(sampleEdge) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * min(scale, 1)).rounded()))
        let height = max(1, Int((Double(image.height) * min(scale, 1)).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let table = (0..<256).map { OKLab.linear(Double($0) / 255) }
        var pixels: [OKLab] = []
        pixels.reserveCapacity(width * height)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            pixels.append(OKLab(linearRed: table[Int(bytes[index])], green: table[Int(bytes[index + 1])],
                                blue: table[Int(bytes[index + 2])]))
        }
        return analyze(pixels: pixels, width: width, height: height)
    }

    /// The core, on OKLab pixels in row-major order.
    static func analyze(pixels: [OKLab], width: Int, height: Int) -> WallpaperAnalysis? {
        guard !pixels.isEmpty, pixels.count == width * height else { return nil }
        let count = Double(pixels.count)
        let meanL = pixels.reduce(0) { $0 + $1.l } / count
        let spread = (pixels.reduce(0) { $0 + ($1.l - meanL) * ($1.l - meanL) } / count).squareRoot()
        let colorfulness = pixels.reduce(0) { $0 + $1.chroma } / count

        var edgeSum = 0.0, edgeCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let here = pixels[y * width + x].l
                if x + 1 < width { edgeSum += abs(pixels[y * width + x + 1].l - here); edgeCount += 1 }
                if y + 1 < height { edgeSum += abs(pixels[(y + 1) * width + x].l - here); edgeCount += 1 }
            }
        }

        var centroids = medianCut(pixels, boxes: clusterCount)
        for _ in 0..<iterations {
            var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: centroids.count)
            for pixel in pixels {
                let nearest = nearestIndex(pixel, centroids)
                sums[nearest].0 += pixel.l
                sums[nearest].1 += pixel.a
                sums[nearest].2 += pixel.b
                sums[nearest].3 += 1
            }
            for index in centroids.indices where sums[index].3 > 0 {
                let n = Double(sums[index].3)
                centroids[index] = OKLab(l: sums[index].0 / n, a: sums[index].1 / n, b: sums[index].2 / n)
            }
        }
        var counts = [Int](repeating: 0, count: centroids.count)
        var flat = 0
        for pixel in pixels {
            let nearest = nearestIndex(pixel, centroids)
            counts[nearest] += 1
            if pixel.distance(to: centroids[nearest]) < 0.03 { flat += 1 }
        }
        let clusters = centroids.indices
            .filter { counts[$0] > 0 }
            .map { WallpaperAnalysis.Cluster(color: centroids[$0], share: Double(counts[$0]) / count) }
            .sorted { $0.share != $1.share ? $0.share > $1.share : $0.color.l < $1.color.l }
        return WallpaperAnalysis(clusters: clusters, meanLightness: meanL, lightnessSpread: spread,
                                 colorfulness: colorfulness, edgeDensity: edgeCount > 0 ? edgeSum / Double(edgeCount) : 0,
                                 flatness: Double(flat) / count)
    }

    private static func nearestIndex(_ pixel: OKLab, _ centroids: [OKLab]) -> Int {
        var best = 0, bestDistance = Double.infinity
        for (index, centroid) in centroids.enumerated() {
            let dl = pixel.l - centroid.l, da = pixel.a - centroid.a, db = pixel.b - centroid.b
            let distance = dl * dl + da * da + db * db
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Splits the box with the widest axis (scaled by its population) at the median until
    /// there are `boxes` boxes; their means seed k-means.
    private static func medianCut(_ pixels: [OKLab], boxes: Int) -> [OKLab] {
        func axisValue(_ pixel: OKLab, _ axis: Int) -> Double { axis == 0 ? pixel.l : (axis == 1 ? pixel.a : pixel.b) }
        func widest(_ box: [OKLab]) -> (axis: Int, range: Double) {
            (0..<3).map { axis -> (Int, Double) in
                let values = box.map { axisValue($0, axis) }
                return (axis, (values.max() ?? 0) - (values.min() ?? 0))
            }
            .max { $0.1 < $1.1 } ?? (0, 0)
        }
        var queue = [pixels]
        while queue.count < boxes {
            guard let index = queue.enumerated()
                .filter({ $0.element.count > 1 })
                .map({ ($0.offset, widest($0.element).range * Double($0.element.count).squareRoot()) })
                .max(by: { $0.1 < $1.1 })?.0 else { break }
            let box = queue.remove(at: index)
            let axis = widest(box).axis
            let sorted = box.sorted { axisValue($0, axis) < axisValue($1, axis) }
            let middle = sorted.count / 2
            queue.insert(Array(sorted[middle...]), at: index)
            queue.insert(Array(sorted[..<middle]), at: index)
        }
        return queue.map { box in
            let n = Double(box.count)
            return OKLab(l: box.reduce(0) { $0 + $1.l } / n, a: box.reduce(0) { $0 + $1.a } / n,
                         b: box.reduce(0) { $0 + $1.b } / n)
        }
    }
}

// MARK: - Palette

/// Turns an analysis into a full colour theme in the colors.toml schema
/// (themes/omarchy/CONTRACT-COLORS.md), so ish-apply-colors renders it for foot, GTK, Qt,
/// btop, VS Code and Firefox like any user theme.
///
/// Rules:
/// - light or dark: the image's mean lightness (`WallpaperAnalysis.darkThreshold`);
/// - background: the darkest (lightest, for light) sizeable colour's lightness clamped to
///   0.16…0.25 (0.93…0.97), tinted with a little of the dominant colour's hue;
/// - accent: the most salient chromatic colour (chroma × √area, mid lightness preferred),
///   near-black, near-white and grey colours ignored; a quiet hue for grey images;
/// - ANSI red…cyan: each canonical hue pulled up to 20° toward a nearby image colour, with
///   the image's own chroma; bright variants a step lighter (darker on light themes);
/// - every text colour (foreground, accent, ANSI 1–6 and 9–15) reaches WCAG 4.5:1 on the
///   background, muted 3:1, and the foreground 4.5:1 on the selection, by moving lightness
///   only, so hues survive.
enum WallpaperPalette {
    static let textContrast = 4.5
    static let mutedContrast = 3.0

    /// Canonical OKLCh hues of the six ANSI colours, in ANSI order (red … cyan).
    static let ansiHues: [Double] = [25, 142, 95, 262, 330, 200]

    static func theme(from analysis: WallpaperAnalysis, id: String, name: String, iconTheme: String? = nil) -> ColorTheme {
        let dark = analysis.prefersDark
        let dominant = analysis.dominant.color
        let sizeable = analysis.clusters.filter { $0.share >= 0.05 }
        let pool = sizeable.isEmpty ? analysis.clusters : sizeable
        let tintHue = dominant.chroma >= 0.01 ? dominant.hue : (analysis.salientAccent?.hue ?? 250)

        let background: OKLab
        if dark {
            let darkest = pool.map(\.color.l).min() ?? 0.2
            background = OKLab(l: min(max(darkest, 0.16), 0.25), chroma: min(dominant.chroma * 0.5, 0.04), hue: tintHue)
        } else {
            let lightest = pool.map(\.color.l).max() ?? 0.95
            background = OKLab(l: min(max(lightest, 0.93), 0.97), chroma: min(dominant.chroma * 0.3, 0.025), hue: tintHue)
        }
        let bgRGB = background.rgb

        let foreground = ensureContrast(OKLab(l: dark ? 0.9 : 0.27, chroma: min(background.chroma, 0.02), hue: tintHue),
                                        against: bgRGB, minimum: 7, dark: dark)
        let brightForeground = ensureContrast(foreground.with(l: dark ? min(foreground.l + 0.06, 0.99) : max(foreground.l - 0.08, 0.05)),
                                              against: bgRGB, minimum: textContrast, dark: dark)

        let accentSource = analysis.salientAccent
            ?? OKLab(l: 0.68, chroma: analysis.isNearMonochrome ? 0.06 : 0.1, hue: tintHue)
        let accentChroma = min(max(accentSource.chroma * 1.15, analysis.isNearMonochrome ? 0.05 : 0.08), 0.22)
        let accent = ensureContrast(OKLab(l: dark ? max(accentSource.l, 0.68) : min(accentSource.l, 0.55),
                                          chroma: accentChroma, hue: accentSource.hue),
                                    against: bgRGB, minimum: textContrast, dark: dark)

        let muted = ensureContrast(background.mix(foreground, 0.4), against: bgRGB, minimum: mutedContrast, dark: dark)

        var selectionAmount = 0.3
        var selection = background.mix(accent, selectionAmount)
        while ColorContrast.ratio(RGB(hex: foreground.rgb.hex)!, RGB(hex: selection.rgb.hex)!) < textContrast,
              selectionAmount > 0.08 {
            selectionAmount -= 0.04
            selection = background.mix(accent, selectionAmount)
        }

        let chromatic = analysis.clusters.filter { $0.color.chroma >= 0.035 }.map(\.color.chroma).sorted()
        let baseChroma = chromatic.isEmpty ? 0.07 : min(max(chromatic[chromatic.count / 2] * 1.1, 0.07), 0.15)
        var normal: [OKLab] = [], bright: [OKLab] = []
        for hue in ansiHues {
            let nearby = analysis.clusters
                .filter { $0.color.chroma >= 0.04 && OKLab.hueDistance($0.color.hue, hue) < 30 && $0.share >= 0.004 }
                .max { $0.color.chroma * $0.share.squareRoot() < $1.color.chroma * $1.share.squareRoot() }
            var mappedHue = hue, chroma = baseChroma
            if let nearby {
                var delta = nearby.color.hue - hue
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                mappedHue = (hue + min(max(delta, -20), 20) + 360).truncatingRemainder(dividingBy: 360)
                chroma = min(max(nearby.color.chroma, 0.09), 0.2)
            }
            normal.append(ensureContrast(OKLab(l: dark ? 0.72 : 0.54, chroma: chroma, hue: mappedHue),
                                         against: bgRGB, minimum: textContrast, dark: dark))
            bright.append(ensureContrast(OKLab(l: dark ? 0.8 : 0.47, chroma: min(chroma * 1.1, 0.22), hue: mappedHue),
                                         against: bgRGB, minimum: textContrast, dark: dark))
        }

        let lighter = background.with(l: background.l + (dark ? 0.05 : -0.04))
        let darkerStep = dark ? -0.03 : 0.015
        let ansi = [background] + normal + [foreground, muted] + bright + [brightForeground]
        return ColorTheme(
            id: id, name: name, source: "user", appearance: dark ? "dark" : "light",
            accent: accent.rgb.hex, background: bgRGB.hex, foreground: foreground.rgb.hex,
            selection: selection.rgb.hex, selectionForeground: foreground.rgb.hex, cursor: brightForeground.rgb.hex,
            muted: muted.rgb.hex, darkBackground: background.with(l: background.l + darkerStep).rgb.hex,
            darkerBackground: background.with(l: background.l + darkerStep * 2).rgb.hex,
            lighterBackground: lighter.rgb.hex, brightForeground: brightForeground.rgb.hex, red: normal[0].rgb.hex,
            ansi: ansi.map(\.rgb.hex), iconTheme: iconTheme, vscode: nil, wallhaven: nil)
    }

    /// Moves `color`'s lightness away from the background until the WCAG ratio is met on the
    /// written `#rrggbb` values (always reachable: the background is clamped to a dark or
    /// light band).
    static func ensureContrast(_ color: OKLab, against background: RGB, minimum: Double, dark: Bool) -> OKLab {
        var candidate = color
        var steps = 0
        func quantized(_ color: OKLab) -> RGB { RGB(hex: color.rgb.hex) ?? color.rgb }
        let target = RGB(hex: background.hex) ?? background
        while ColorContrast.ratio(quantized(candidate), target) < minimum, steps < 120 {
            candidate.l = min(max(candidate.l + (dark ? 0.01 : -0.01), 0), 1)
            steps += 1
        }
        return candidate
    }
}
