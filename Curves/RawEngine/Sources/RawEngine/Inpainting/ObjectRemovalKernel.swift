import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Composites each `ObjectRemoval`'s already-baked `previewPatchData` into `image` through its
/// mask — the *only* thing this does at render time is a mask-scale plus `CIBlendWithMask`, the
/// same cheap shape as `RawImageRenderer.applyMask`/`SpotRemovalKernel`. Producing the fill itself
/// (`InpaintingFilter`, a multi-second Core ML call) never happens here — only once, up front, from
/// `RemoveObjectEditorOverlay`'s explicit "Remove"/"Refresh Fill" actions — so a render triggered by
/// an unrelated slider drag pays only this cheap compositing cost, same as every other stage.
public enum ObjectRemovalKernel {
    public static func apply(to image: CIImage, params: ObjectRemovalParameters) -> CIImage {
        guard !params.isEmpty else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        var output = image
        for removal in params.removals {
            output = apply(removal, to: output, extent: extent)
        }
        return output
    }

    private static func apply(_ removal: ObjectRemoval, to image: CIImage, extent: CGRect) -> CIImage {
        guard let maskImage = CIImage(data: removal.maskData), let patchImage = CIImage(data: removal.previewPatchData) else {
            return image
        }
        let maskExtent = maskImage.extent
        guard maskExtent.width > 0, maskExtent.height > 0, patchImage.extent.width > 0, patchImage.extent.height > 0 else {
            return image
        }
        let maskScale = CGAffineTransform(scaleX: extent.width / maskExtent.width, y: extent.height / maskExtent.height)
        let scaledMask = maskImage.transformed(by: maskScale)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))

        // Same top-left-origin -> CIImage bottom-left-origin flip as `SpotRemoval`'s target/source
        // points, just applied to a rect: the rect's normalized *bottom* edge (`cropY + cropHeight`,
        // the larger top-down value) becomes the CIImage-space rect's *minimum* y.
        let cropRect = CGRect(
            x: extent.minX + removal.cropX * extent.width,
            y: extent.minY + (1 - removal.cropY - removal.cropHeight) * extent.height,
            width: removal.cropWidth * extent.width,
            height: removal.cropHeight * extent.height
        )
        let patchScale = CGAffineTransform(
            scaleX: cropRect.width / patchImage.extent.width, y: cropRect.height / patchImage.extent.height
        )
        let positionedPatch = patchImage.transformed(by: patchScale)
            .transformed(by: CGAffineTransform(translationX: cropRect.minX, y: cropRect.minY))

        let blend = CIFilter.blendWithMask()
        blend.inputImage = positionedPatch
        blend.backgroundImage = image
        blend.maskImage = scaledMask
        return blend.outputImage?.cropped(to: extent) ?? image
    }
}
