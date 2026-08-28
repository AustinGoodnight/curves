import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Applies a stack of `SpotRemoval` patches to `image` — each one translates a same-radius
/// circular patch from `source` onto `target` and blends it in through a soft-edged circular mask,
/// covering whatever was at `target` with a copy of what's at `source`. Composited sequentially,
/// each spot's output feeding the next as its base image, same "real sequential composite" shape as
/// `RawImageRenderer.applyStage`'s module chain — later spots can safely sample a region an earlier
/// spot just repaired.
public enum SpotRemovalKernel {
    public static func apply(to image: CIImage, params: SpotRemovalParameters) -> CIImage {
        guard !params.isEmpty else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        var output = image
        for spot in params.spots {
            output = apply(spot, to: output, extent: extent)
        }
        return output
    }

    /// `target`/`source` convert from this module's normalized, top-left-origin convention (see
    /// `SpotRemoval`'s doc comment) into `CIImage`'s own bottom-left-origin point space — flipping
    /// `y` is the only conversion needed since both share the same normalized-to-pixel scale.
    private static func apply(_ spot: SpotRemoval, to image: CIImage, extent: CGRect) -> CIImage {
        let radiusPixels = max(1, spot.radius * extent.width)
        let target = CGPoint(
            x: extent.minX + spot.targetX * extent.width,
            y: extent.minY + (1 - spot.targetY) * extent.height
        )
        let source = CGPoint(
            x: extent.minX + spot.sourceX * extent.width,
            y: extent.minY + (1 - spot.sourceY) * extent.height
        )
        guard target != source else { return image }

        // `clampedToExtent` before the translate so the sampled patch has real (edge-extended)
        // content everywhere under the mask below, even when `source` sits close enough to the
        // image's border that a plain translate would otherwise expose the transform's implicit
        // transparent-black outside `image`'s original extent.
        let translation = CGAffineTransform(translationX: target.x - source.x, y: target.y - source.y)
        let translated = image.clampedToExtent().transformed(by: translation)

        // Soft circular falloff: fully opaque out to 65% of the radius, feathering to fully
        // transparent at the radius itself — the same "solid core, feathered edge" shape as
        // `GradientMaskCanvas.drawRadialGradient`'s mask, just built directly as a `CIImage` here
        // instead of baked into a stored PNG, since this mask never needs to persist.
        let feather = radiusPixels * 0.35
        let gradient = CIFilter.radialGradient()
        gradient.center = target
        gradient.radius0 = Float(max(0, radiusPixels - feather))
        gradient.radius1 = Float(radiusPixels)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        guard let maskImage = gradient.outputImage?.cropped(to: extent) else { return image }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = translated
        blend.backgroundImage = image
        blend.maskImage = maskImage
        return blend.outputImage?.cropped(to: extent) ?? image
    }
}
