import CoreGraphics
import Foundation

/// Image-shaped "scopes" for the editor's data panel — rendered here as small `CGImage`s rather
/// than handed to SwiftUI as raw bin counts, since each is a dense 2D density plot (thousands of
/// cells) that SwiftUI would otherwise have to draw cell by cell on every render. Computed off the
/// main thread from the same kind of subsampled pixels as `Histogram`, once per settled render.
public enum PhotoScopes {
    /// Where each scope's colors come from: the *average actual color* of the pixels that land in
    /// a cell, brightened to full intensity, then dimmed by how many pixels landed there (log
    /// scale, so a thin scatter of saturated pixels is still visible next to a dense mass).
    ///
    /// **Vectorscope**: every pixel plotted by its CIELAB chroma — a* to the right (toward red/
    /// magenta), b* upward (toward yellow) — so the center is neutral grey and distance from it is
    /// color intensity. `maxChroma` is the plot's edge; strongly saturated pixels beyond it pile up
    /// at the rim. Pixels are linearized (2.2) before conversion, since `ColorZonesMath` expects
    /// linear RGB.
    public static func vectorscope(from image: CGImage, size: Int = 160, maxChroma: Double = 60, maxSamples: Int = 60_000) -> CGImage? {
        guard let sample = sampledPixels(from: image, maxSamples: maxSamples) else { return nil }
        let cells = size * size
        var counts = [Float](repeating: 0, count: cells)
        var sums = [Float](repeating: 0, count: cells * 3)
        let half = Double(size) / 2
        let pixels = sample.pixels
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let lab = ColorZonesMath.rgbToLab(Triplet(x: pow(r, 2.2), y: pow(g, 2.2), z: pow(b, 2.2)))
            var x = lab.y / maxChroma, y = lab.z / maxChroma
            let radius = (x * x + y * y).squareRoot()
            if radius > 0.98 { x *= 0.98 / radius; y *= 0.98 / radius }
            let col = min(size - 1, max(0, Int(half + x * half)))
            let row = min(size - 1, max(0, Int(half - y * half)))
            let cell = row * size + col
            counts[cell] += 1
            sums[cell * 3] += Float(r)
            sums[cell * 3 + 1] += Float(g)
            sums[cell * 3 + 2] += Float(b)
        }
        return densityImage(width: size, height: size, counts: counts, colorSums: sums)
    }

    /// **RGB waveform**: x is horizontal position in the frame, y is value (black at the bottom,
    /// white at the top), drawn separately for R, G and B and added together — where the channels
    /// agree (neutral tones) the trace is white; where they split, the photo has a color cast in
    /// that part of the frame. Shows *where* highlights clip or shadows crush, which a histogram
    /// can't.
    public static func waveform(from image: CGImage, columns: Int = 180, levels: Int = 100) -> CGImage? {
        // Sampled at exactly `columns` pixels wide, so each scope column is one sample column —
        // any other ratio bins unevenly and shows up as vertical striping.
        guard image.width > 0 else { return nil }
        let sampleHeight = max(1, Int(Double(columns) * Double(image.height) / Double(image.width)))
        guard let sample = sampledPixels(from: image, width: columns, height: sampleHeight) else { return nil }
        var channelCounts = [[Float]](repeating: [Float](repeating: 0, count: columns * levels), count: 3)
        let pixels = sample.pixels
        for y in 0..<sample.height {
            for x in 0..<sample.width {
                let i = (y * sample.width + x) * 4
                let col = min(columns - 1, x)
                for c in 0..<3 {
                    let level = min(levels - 1, Int(pixels[i + c]) * levels / 256)
                    channelCounts[c][(levels - 1 - level) * columns + col] += 1
                }
            }
        }
        // Brightness per channel: a soft power curve against a high percentile rather than the
        // single busiest cell (one dense patch would otherwise dim everything else), and no floor —
        // a lone stray sample stays faint instead of speckling the trace. Then each cell's color is
        // pulled 75% toward its own grey, so agreeing channels read as a calm white trace and a
        // real cast shows as a gentle tint rather than rainbow fringing.
        let nonzero = channelCounts.flatMap { $0 }.filter { $0 > 0 }.sorted()
        guard !nonzero.isEmpty else { return nil }
        let reference = nonzero[min(nonzero.count - 1, Int(Double(nonzero.count) * 0.98))]
        var rgba = [UInt8](repeating: 0, count: columns * levels * 4)
        for cell in 0..<(columns * levels) {
            var channel = [Float](repeating: 0, count: 3)
            for c in 0..<3 {
                channel[c] = min(1, pow(channelCounts[c][cell] / reference, 0.55))
            }
            let grey = (channel[0] + channel[1] + channel[2]) / 3
            for c in 0..<3 {
                let value = (grey + (channel[c] - grey) * 0.25) * 0.92
                rgba[cell * 4 + c] = UInt8(min(255, max(0, value * 255)))
            }
            rgba[cell * 4 + 3] = max(rgba[cell * 4], rgba[cell * 4 + 1], rgba[cell * 4 + 2])
        }
        return makeImage(rgba, width: columns, height: levels)
    }

    // MARK: - Helpers

    private static func densityImage(width: Int, height: Int, counts: [Float], colorSums: [Float]) -> CGImage? {
        let peak = counts.max() ?? 0
        guard peak > 0 else { return nil }
        let logPeak = log(1 + peak)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for cell in 0..<(width * height) {
            let n = counts[cell]
            guard n > 0 else { continue }
            var r = colorSums[cell * 3] / n, g = colorSums[cell * 3 + 1] / n, b = colorSums[cell * 3 + 2] / n
            // Brighten the average color to full intensity so the hue reads, then let density set
            // how bright the cell actually glows.
            let top = max(r, g, b, 0.001)
            r /= top; g /= top; b /= top
            let intensity = 0.25 + 0.75 * log(1 + n) / logPeak
            rgba[cell * 4] = UInt8(min(255, r * intensity * 255))
            rgba[cell * 4 + 1] = UInt8(min(255, g * intensity * 255))
            rgba[cell * 4 + 2] = UInt8(min(255, b * intensity * 255))
            rgba[cell * 4 + 3] = UInt8(min(255, intensity * 255))
        }
        return makeImage(rgba, width: width, height: height)
    }

    /// Premultiplied RGBA8 → `CGImage` (the values above are already premultiplied by `intensity`).
    private static func makeImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        var bytes = rgba
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }

    /// Same downscaled-draw sampling as `Histogram`'s, but keeping the sample's dimensions (the
    /// waveform needs each pixel's x position).
    private static func sampledPixels(from image: CGImage, maxSamples: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        let sourcePixels = image.width * image.height
        guard sourcePixels > 0 else { return nil }
        let scale = min(1.0, (Double(maxSamples) / Double(sourcePixels)).squareRoot())
        return sampledPixels(
            from: image,
            width: max(1, Int(Double(image.width) * scale)),
            height: max(1, Int(Double(image.height) * scale))
        )
    }

    private static func sampledPixels(from image: CGImage, width: Int, height: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }

    /// Reference targets for the vectorscope graticule: where fully saturated sRGB primaries and
    /// secondaries sit, as (label, angle in radians with 0 = +a* and counterclockwise toward +b*,
    /// radius as a fraction of the plot edge — capped just inside it since real primaries exceed
    /// `maxChroma`). Computed with the same conversion the plot uses, so they line up exactly.
    public static func vectorscopeTargets(maxChroma: Double = 60) -> [(label: String, angle: Double, radius: Double)] {
        let colors: [(String, Double, Double, Double)] = [
            ("R", 1, 0, 0), ("Y", 1, 1, 0), ("G", 0, 1, 0), ("C", 0, 1, 1), ("B", 0, 0, 1), ("M", 1, 0, 1),
        ]
        return colors.map { label, r, g, b in
            let lab = ColorZonesMath.rgbToLab(Triplet(x: r, y: g, z: b))
            let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            return (label, atan2(lab.z, lab.y), min(chroma / maxChroma, 0.9))
        }
    }

    /// The skin-tone line's angle (same convention as `vectorscopeTargets`) — the hue most human
    /// skin sits along regardless of ethnicity, the classic vectorscope "flesh line". Measured
    /// from a representative mid skin tone (sRGB ≈ 0.78, 0.57, 0.47).
    public static func skinToneAngle() -> Double {
        let lab = ColorZonesMath.rgbToLab(Triplet(x: pow(0.78, 2.2), y: pow(0.57, 2.2), z: pow(0.47, 2.2)))
        return atan2(lab.z, lab.y)
    }
}
