import CoreGraphics
import Foundation

/// Histogram computation for curve-editor backdrops (RGB Curve's luminance histogram, Color
/// Zones' per-hue histogram). Not a darktable port — there's no single module this corresponds
/// to; darktable's own curve/colorzones GUIs draw comparable backdrops, but each computes it
/// inline in C rather than through a shared reusable path, so this is an original small system
/// built to the same end.
///
/// Pixel sampling is subsampled to a fixed budget (`maxSamples`) regardless of image size, so
/// this stays fast enough to recompute on every settled render (a few ms) rather than needing
/// its own separate debounce — a 24MP preview and a 400px thumbnail cost about the same.
public enum Histogram {
    /// Bin counts normalized so the tallest bin is 1.0, suitable for drawing bar heights
    /// directly. Empty array if the image couldn't be read.
    public static func luminance(from image: CGImage, bins: Int = 64, maxSamples: Int = 40_000) -> [Float] {
        guard let pixels = sampledRGBA(from: image, maxSamples: maxSamples) else { return [] }
        var counts = [Float](repeating: 0, count: bins)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Float(pixels[i]) / 255
            let g = Float(pixels[i + 1]) / 255
            let b = Float(pixels[i + 2]) / 255
            // Same Rec.709 weights used throughout this engine (FilmicRGBKernel, RGBCurveKernel).
            let lum = 0.2225045 * r + 0.7168786 * g + 0.0606169 * b
            let bin = min(bins - 1, max(0, Int(lum * Float(bins))))
            counts[bin] += 1
        }
        return normalized(counts)
    }

    /// Distribution of pixel hues (CIE Lab a/b angle, matching `ColorZonesMath`/
    /// `ColorZonesKernel`'s own hue decomposition exactly, so the backdrop lines up with what
    /// the curve actually indexes into). Near-neutral pixels (chroma < 2, where hue is
    /// numerically unstable — a 1-unit noise wobble in a/b swings hue wildly when their
    /// magnitude is tiny) are excluded rather than dumped into an arbitrary bin.
    public static func hue(from image: CGImage, bins: Int = 64, maxSamples: Int = 40_000) -> [Float] {
        guard let pixels = sampledRGBA(from: image, maxSamples: maxSamples) else { return [] }
        var counts = [Float](repeating: 0, count: bins)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            let lab = ColorZonesMath.rgbToLab(Triplet(x: r, y: g, z: b))
            let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            guard chroma > 2 else { continue }
            var hue = atan2(lab.z, lab.y) / (2 * .pi)
            if hue < 0 { hue += 1 }
            let bin = min(bins - 1, max(0, Int(hue * Double(bins))))
            counts[bin] += 1
        }
        return normalized(counts)
    }

    private static func normalized(_ counts: [Float]) -> [Float] {
        guard let maxCount = counts.max(), maxCount > 0 else { return counts }
        return counts.map { $0 / maxCount }
    }

    /// Draws `image` into an RGBA8 buffer at (roughly) `maxSamples` total pixels — downscaling
    /// via the draw itself rather than decoding at full resolution and skipping pixels, so cost
    /// stays proportional to the sample budget, not the source image size.
    private static func sampledRGBA(from image: CGImage, maxSamples: Int) -> [UInt8]? {
        let sourcePixels = image.width * image.height
        guard sourcePixels > 0 else { return nil }
        let scale = min(1.0, (Double(maxSamples) / Double(sourcePixels)).squareRoot())
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}
