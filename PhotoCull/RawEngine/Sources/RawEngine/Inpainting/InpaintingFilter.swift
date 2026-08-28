import CoreML
import CoreImage
import CoreGraphics
import Foundation

/// Runs the vendored LaMa Core ML model (`RawEngine/Vendor/LaMa.mlpackage`) to synthesize fill
/// content for a masked region — the "AI remove" half of the Remove Object tool. The other half,
/// selecting *what* to mask, is Vision-based and lives in the app target (`ObjectSelectionMask
/// .swift`) since interactive tap-to-select is a UI concern, not an image-processing one.
///
/// Expensive — real Core ML inference, not a Core Image pass — so callers must only invoke this
/// from an explicit, user-triggered action (`RemoveObjectEditorOverlay`'s "Remove"/"Refresh Fill"
/// buttons). It never runs from `RawImageRenderer`'s normal render path, which only ever composites
/// an already-baked result via `ObjectRemovalKernel`.
public enum InpaintingFilter {
    /// The model's fixed input/output size on every side — the LaMa Core ML conversion doesn't
    /// support flexible input shapes (see `CoreMLaMa/convert_lama.py`'s own comment on this), so
    /// every call resizes into and back out of exactly this square. Callers are responsible for
    /// cropping a *square* region before calling `fill` — `MLFeatureValue`'s own constraint-driven
    /// resize (below) would otherwise letterbox/distort a non-square crop rather than reject it.
    public static let modelInputSize = 800

    public enum InpaintingError: Error {
        case modelNotBundled
        case missingImageConstraint
        case predictionProducedNoImage
    }

    /// Loaded once, lazily — same pattern as `RawImageRenderer`'s own `CIContext`, just for a much
    /// heavier resource. `nil` (rather than crashing) whenever the model hasn't been vendored yet,
    /// so the rest of this feature's Swift/UI code can be built, compiled, and exercised (mask
    /// selection, storage, the cheap composite path) independent of whether `LaMa.mlpackage` has
    /// landed in `RawEngine/Vendor/` yet — `fill` just throws `.modelNotBundled` until it has.
    private static let model: MLModel? = {
        guard let url = Bundle.module.url(forResource: "LaMa", withExtension: "mlmodelc")
            ?? Bundle.module.url(forResource: "LaMa", withExtension: "mlpackage") else { return nil }
        return try? MLModel(contentsOf: url)
    }()

    /// `image`/`mask` should already be cropped to the same square region (see `modelInputSize`'s
    /// doc comment) — `MLFeatureValue(cgImage:constraint:options:)` handles the resize into the
    /// model's exact 800x800 declared shape, using the shape/pixel-format CoreML itself reports
    /// (`MLImageConstraint`) rather than a hardcoded assumption, so this keeps working even if a
    /// future model revision changes `modelInputSize`.
    public static func fill(image: CGImage, mask: CGImage) throws -> CGImage {
        guard let model else { throw InpaintingError.modelNotBundled }
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let imageConstraint = inputs["image"]?.imageConstraint,
              let maskConstraint = inputs["mask"]?.imageConstraint else {
            throw InpaintingError.missingImageConstraint
        }
        let imageValue = try MLFeatureValue(cgImage: image, constraint: imageConstraint, options: nil)
        let maskValue = try MLFeatureValue(cgImage: mask, constraint: maskConstraint, options: nil)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": imageValue, "mask": maskValue])
        let output = try model.prediction(from: input)
        guard let pixelBuffer = output.featureValue(for: "output")?.imageBufferValue else {
            throw InpaintingError.predictionProducedNoImage
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let result = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw InpaintingError.predictionProducedNoImage
        }
        return result
    }
}
