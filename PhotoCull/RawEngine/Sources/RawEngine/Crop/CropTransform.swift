import CoreImage
import Foundation

/// Applies `CropParameters`' straighten rotation and crop rectangle to a rendered image — a plain
/// affine rotation plus `CIImage.cropped(to:)`, not a custom kernel (unlike `LensCorrectionKernel`,
/// there's no per-pixel math here Core Image doesn't already do natively).
public enum CropTransform {
    public static func apply(to image: CIImage, params: CropParameters) -> CIImage {
        guard !params.isIdentity else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let rotated: CIImage
        if params.angleDegrees == 0 {
            rotated = image
        } else {
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let radians = params.angleDegrees * .pi / 180
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: radians)
                .translatedBy(x: -center.x, y: -center.y)
            rotated = image.transformed(by: transform)
        }

        let rotatedExtent = rotated.extent
        guard rotatedExtent.width > 0, rotatedExtent.height > 0 else { return image }

        let pixelRect = CGRect(
            x: rotatedExtent.minX + params.rect.minX * rotatedExtent.width,
            y: rotatedExtent.minY + params.rect.minY * rotatedExtent.height,
            width: params.rect.width * rotatedExtent.width,
            height: params.rect.height * rotatedExtent.height
        ).intersection(rotatedExtent)
        guard pixelRect.width > 0, pixelRect.height > 0 else { return rotated }

        return rotated.cropped(to: pixelRect)
    }

    /// The largest rectangle of `aspect` (width / height), centered on the image, that fits
    /// entirely inside `originalSize` once rotated by `angleDegrees` — i.e. the biggest crop that
    /// shows no blank corners. Returned as a normalized `(0...1)` rect centered at `(0.5, 0.5)`,
    /// directly usable as `CropParameters.rect`. `CropEditorOverlay` calls this every time the
    /// straighten angle or aspect-ratio lock changes, so the crop box the user is dragging never
    /// lets them select a region that would sample outside the original photo — the same "auto-
    /// scale to hide the blank border" reasoning as `LensCorrectionKernel`'s `autoScaleFactor`, just
    /// for a plain rotation instead of a lens distortion polynomial.
    ///
    /// Finds the answer by bisecting on overall size rather than the rotated-rectangle inscribed-
    /// rect closed-form trig identity — simpler to get right, and the safety test itself (rotate a
    /// corner back by `-angleDegrees`, check it lands within the original bounds) is exact regardless
    /// of how the search finds it.
    public static func maxCenteredCropRect(angleDegrees: Double, aspect: Double, originalSize: CGSize) -> CGRect {
        guard originalSize.width > 0, originalSize.height > 0, aspect > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let radians = angleDegrees * .pi / 180
        let halfOrigW = originalSize.width / 2
        let halfOrigH = originalSize.height / 2

        func isSafe(scale: Double) -> Bool {
            let halfW = scale * aspect / 2
            let halfH = scale / 2
            let cosA = cos(-radians), sinA = sin(-radians)
            for corner in [(halfW, halfH), (-halfW, halfH), (-halfW, -halfH), (halfW, -halfH)] {
                let rx = corner.0 * cosA - corner.1 * sinA
                let ry = corner.0 * sinA + corner.1 * cosA
                if abs(rx) > halfOrigW + 0.001 || abs(ry) > halfOrigH + 0.001 { return false }
            }
            return true
        }

        var lo = 0.0
        var hi = 2 * max(originalSize.width, originalSize.height) / max(aspect, 1 / aspect)
        // Growing hi until it's provably unsafe keeps the bisection's upper bound valid regardless
        // of how extreme `aspect` is, rather than guessing a single fixed multiple that might
        // already be safe (and so silently cap the result) for a very elongated aspect ratio.
        while isSafe(scale: hi) { hi *= 2 }
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if isSafe(scale: mid) { lo = mid } else { hi = mid }
        }

        let cropSize = CGSize(width: lo * aspect, height: lo)
        let rotatedSize = CGSize(
            width: originalSize.width * abs(cos(radians)) + originalSize.height * abs(sin(radians)),
            height: originalSize.width * abs(sin(radians)) + originalSize.height * abs(cos(radians))
        )
        guard rotatedSize.width > 0, rotatedSize.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        let normWidth = min(1, cropSize.width / rotatedSize.width)
        let normHeight = min(1, cropSize.height / rotatedSize.height)
        return CGRect(x: (1 - normWidth) / 2, y: (1 - normHeight) / 2, width: normWidth, height: normHeight)
    }
}
