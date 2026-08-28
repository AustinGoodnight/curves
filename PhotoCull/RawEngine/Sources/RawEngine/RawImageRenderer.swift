import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Wraps a single `CIRAWFilter` instance for one image. Core Image caches the expensive
/// decode/demosaic step in its compute graph and only recomputes what's downstream of a
/// changed input — so the fast incremental re-renders this exists for only happen when the
/// *same* filter instance is reused across parameter changes. Create a new renderer per image,
/// not per render.
public final class RawImageRenderer {
    private var filter: CIRAWFilter?
    /// Decoded source for a non-RAW asset (JPEG/PNG/HEIC/TIFF) — set instead of `filter` whenever
    /// `CIRAWFilter` can't open the file. There's no as-shot exposure/white-balance/sharpness
    /// metadata to read back for these formats, so `apply(_:)` (which only ever touches `filter`)
    /// is a no-op on this path and those base params stay at their neutral defaults below.
    private var standardImage: CIImage?
    private var loadedURL: URL?
    private let context: CIContext

    public private(set) var nativeSize: CGSize = .zero
    public private(set) var defaultExposure: Double = 0
    public private(set) var defaultBoostAmount: Double = 1
    public private(set) var defaultNeutralTemperature: Double = 6500
    public private(set) var defaultNeutralTint: Double = 0
    public private(set) var defaultSharpnessAmount: Double = 0
    public private(set) var isSharpnessSupported: Bool = false

    public init() {
        context = CIContext()
    }

    /// Loads the image and captures its as-shot defaults. Tries `CIRAWFilter` first (the RAW
    /// decode path); if the file isn't a RAW format `CIRAWFilter` recognizes, falls back to a
    /// plain `CIImage(contentsOf:)` decode so standard formats (JPEG/PNG/HEIC/TIFF) still load.
    /// Returns false if neither decode succeeds. Safe to call from a background thread — the
    /// initial full RAW decode is the ~1.5s operation validated for this pipeline, so callers
    /// should not do this on the main thread.
    @discardableResult
    public func load(url: URL) -> Bool {
        if loadedURL == url, filter != nil || standardImage != nil { return true }
        if let newFilter = CIRAWFilter(imageURL: url) {
            filter = newFilter
            standardImage = nil
            loadedURL = url
            nativeSize = newFilter.nativeSize
            defaultExposure = Double(newFilter.exposure)
            defaultBoostAmount = Double(newFilter.boostAmount)
            defaultNeutralTemperature = Double(newFilter.neutralTemperature)
            defaultNeutralTint = Double(newFilter.neutralTint)
            isSharpnessSupported = newFilter.isSharpnessSupported
            defaultSharpnessAmount = Double(newFilter.sharpnessAmount)
            return true
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return false }
        filter = nil
        standardImage = image
        loadedURL = url
        nativeSize = image.extent.size
        defaultExposure = 0
        defaultBoostAmount = 1
        defaultNeutralTemperature = 6500
        defaultNeutralTint = 0
        isSharpnessSupported = false
        defaultSharpnessAmount = 0
        return true
    }

    private func apply(_ params: RawBaseParameters) {
        guard let filter else { return }
        filter.exposure = Float(params.exposure ?? defaultExposure)
        filter.boostAmount = Float(params.boostAmount ?? defaultBoostAmount)
        filter.neutralTemperature = Float(params.neutralTemperature ?? defaultNeutralTemperature)
        filter.neutralTint = Float(params.neutralTint ?? defaultNeutralTint)
        if isSharpnessSupported {
            filter.sharpnessAmount = Float(params.sharpnessAmount ?? defaultSharpnessAmount)
        }
    }

    /// Runs one stage's six kernel passes (Dehaze → Filmic → ColorBalance → ColorZones →
    /// RGBCurve → LUT3D, each skipped when `nil`) on top of `image`. Called once per active
    /// stage, in stack order, with each call's result feeding the next — a real sequential
    /// composite, not a merged parameter set (see `StageParameters`'s doc comment for why).
    private func applyStage(_ params: StageParameters, to image: CIImage) -> CIImage {
        var output = image
        if let dehaze = params.dehaze {
            output = DehazeKernel.apply(to: output, params: dehaze)
        }
        if let filmicRGB = params.filmicRGB {
            output = FilmicRGBKernel.apply(to: output, params: filmicRGB)
        }
        if let colorBalanceRGB = params.colorBalanceRGB {
            output = ColorBalanceRGBKernel.apply(to: output, params: colorBalanceRGB)
        }
        if let colorZones = params.colorZones {
            output = ColorZonesKernel.apply(to: output, params: colorZones)
        }
        if let rgbCurve = params.rgbCurve {
            output = RGBCurveKernel.apply(to: output, params: rgbCurve)
        }
        if let lut3D = params.lut3D {
            output = LUT3DFilter.apply(to: output, params: lut3D)
        }
        if let maskData = params.maskData, let masked = applyMask(maskData, blending: output, over: image) {
            output = masked
        }
        return output
    }

    /// Decodes a stage's grayscale mask PNG, rescales it to `image`'s extent, and blends `output`
    /// over `image` through it. `CIBlendWithMask` reads a mask image's *grayscale value* directly
    /// (unlike `CIBlendWithAlphaMask`, which reads alpha instead) — the plain decoded grayscale
    /// mask is exactly what it wants, no alpha conversion needed.
    private func applyMask(_ maskData: Data, blending output: CIImage, over image: CIImage) -> CIImage? {
        guard let maskImage = CIImage(data: maskData) else { return nil }
        let maskExtent = maskImage.extent
        guard maskExtent.width > 0, maskExtent.height > 0 else { return nil }
        let scale = CGAffineTransform(
            scaleX: image.extent.width / maskExtent.width,
            y: image.extent.height / maskExtent.height
        )
        let scaledMask = maskImage.transformed(by: scale)
            .transformed(by: CGAffineTransform(translationX: image.extent.origin.x, y: image.extent.origin.y))

        let blend = CIFilter.blendWithMask()
        blend.inputImage = output
        blend.backgroundImage = image
        blend.maskImage = scaledMask
        return blend.outputImage?.cropped(to: image.extent)
    }

    /// Runs the format-specific decode step shared by `renderPreview`/`renderFullResolution`:
    /// applies `baseParams` to `filter` (a no-op on the `standardImage` path — see its doc
    /// comment) and returns the resulting `CIImage`, downscaling `CIRAWFilter`'s demosaic itself
    /// via `scaleFactor` when `maxPixelSize` is given (see `renderPreview`'s doc comment for why
    /// that only makes sense on the RAW path — a decoded JPEG/PNG is already close to display
    /// size, so it's scaled at the tail end like every other format instead).
    private func decodedImage(baseParams: RawBaseParameters, maxPixelSize: CGFloat?, draft: Bool) -> CIImage? {
        guard filter != nil || standardImage != nil else { return nil }
        apply(baseParams)
        if let filter {
            if let maxPixelSize {
                let longestNative = max(nativeSize.width, nativeSize.height)
                filter.scaleFactor = longestNative > 0 ? Float(min(1, maxPixelSize / longestNative)) : 1
            } else {
                filter.scaleFactor = 1
            }
            filter.isDraftModeEnabled = draft
            return filter.outputImage
        }
        return standardImage
    }

    /// Renders a preview downscaled to fit within `maxPixelSize` on its longest side.
    ///
    /// Sets `CIRAWFilter.scaleFactor` so the demosaic itself runs at roughly preview resolution
    /// instead of the RAW's full native size — on a 40-60MP sensor that's the difference between
    /// decoding ~1600px and ~8000px on the long side, and every downstream kernel inherits the
    /// same reduction since they all run after this. `draft` additionally trades a bit of demosaic
    /// quality for speed — pass `true` while the user is actively dragging a control, `false` once
    /// input has settled for a crisper pass.
    public func renderPreview(baseParams: RawBaseParameters, stageStack: [StageParameters], maxPixelSize: CGFloat, draft: Bool = false) -> CGImage? {
        guard var output = decodedImage(baseParams: baseParams, maxPixelSize: maxPixelSize, draft: draft) else { return nil }
        if let denoise = baseParams.denoise {
            output = DenoiseFilter.apply(to: output, params: denoise, draft: draft)
        }
        if let lensCorrection = baseParams.lensCorrection {
            output = LensCorrectionKernel.apply(to: output, params: lensCorrection)
        }
        for stage in stageStack where !stage.isEmpty {
            output = applyStage(stage, to: output)
        }
        if let spotRemoval = baseParams.spotRemoval {
            output = SpotRemovalKernel.apply(to: output, params: spotRemoval)
        }
        if let objectRemovals = baseParams.objectRemovals {
            output = ObjectRemovalKernel.apply(to: output, params: objectRemovals)
        }
        if let crop = baseParams.crop {
            output = CropTransform.apply(to: output, params: crop)
        }
        let extent = output.extent
        let longestSide = max(extent.width, extent.height)
        let scale = longestSide > maxPixelSize ? maxPixelSize / longestSide : 1
        let scaled = scale < 1 ? output.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : output
        return context.createCGImage(scaled, from: scaled.extent)
    }

    /// Renders at full native resolution, for export. `maxLongEdge`, when given, downscales the
    /// final composited image to fit that many pixels on its longer side — same tail-end scaling
    /// `renderPreview` does, just applied after the full-resolution demosaic/stage stack rather
    /// than before it, so a resized export still benefits from filtering/grading computed at full
    /// detail instead of at the smaller output size.
    public func renderFullResolution(baseParams: RawBaseParameters, stageStack: [StageParameters], maxLongEdge: CGFloat? = nil) -> CGImage? {
        guard var output = decodedImage(baseParams: baseParams, maxPixelSize: nil, draft: false) else { return nil }
        if let denoise = baseParams.denoise {
            output = DenoiseFilter.apply(to: output, params: denoise, draft: false)
        }
        if let lensCorrection = baseParams.lensCorrection {
            output = LensCorrectionKernel.apply(to: output, params: lensCorrection)
        }
        for stage in stageStack where !stage.isEmpty {
            output = applyStage(stage, to: output)
        }
        if let spotRemoval = baseParams.spotRemoval {
            output = SpotRemovalKernel.apply(to: output, params: spotRemoval)
        }
        if let objectRemovals = baseParams.objectRemovals {
            output = ObjectRemovalKernel.apply(to: output, params: objectRemovals)
        }
        if let crop = baseParams.crop {
            output = CropTransform.apply(to: output, params: crop)
        }
        if let maxLongEdge {
            let extent = output.extent
            let longestSide = max(extent.width, extent.height)
            if longestSide > maxLongEdge {
                let scale = maxLongEdge / longestSide
                output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        return context.createCGImage(output, from: output.extent)
    }
}
