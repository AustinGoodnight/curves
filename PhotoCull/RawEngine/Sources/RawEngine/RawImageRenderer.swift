import CoreImage
import CoreGraphics
import Foundation

/// Wraps a single `CIRAWFilter` instance for one image. Core Image caches the expensive
/// decode/demosaic step in its compute graph and only recomputes what's downstream of a
/// changed input — so the fast incremental re-renders this exists for only happen when the
/// *same* filter instance is reused across parameter changes. Create a new renderer per image,
/// not per render.
public final class RawImageRenderer {
    private var filter: CIRAWFilter?
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

    /// Loads the RAW file and captures its as-shot defaults. Returns false if the file couldn't
    /// be decoded. Safe to call from a background thread — the initial full decode is the ~1.5s
    /// operation validated for this pipeline, so callers should not do this on the main thread.
    @discardableResult
    public func load(url: URL) -> Bool {
        if loadedURL == url, filter != nil { return true }
        guard let newFilter = CIRAWFilter(imageURL: url) else { return false }
        filter = newFilter
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

    /// Runs one stage's four kernel passes (Filmic → ColorBalance → ColorZones → RGBCurve, each
    /// skipped when `nil`) on top of `image`. Called once per active stage, in stack order, with
    /// each call's result feeding the next — a real sequential composite, not a merged parameter
    /// set (see `StageParameters`'s doc comment for why).
    private func applyStage(_ params: StageParameters, to image: CIImage) -> CIImage {
        var output = image
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
        return output
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
        guard let filter else { return nil }
        apply(baseParams)
        let longestNative = max(nativeSize.width, nativeSize.height)
        filter.scaleFactor = longestNative > 0 ? Float(min(1, maxPixelSize / longestNative)) : 1
        filter.isDraftModeEnabled = draft
        guard var output = filter.outputImage else { return nil }
        for stage in stageStack where !stage.isEmpty {
            output = applyStage(stage, to: output)
        }
        let extent = output.extent
        let longestSide = max(extent.width, extent.height)
        let scale = longestSide > maxPixelSize ? maxPixelSize / longestSide : 1
        let scaled = scale < 1 ? output.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : output
        return context.createCGImage(scaled, from: scaled.extent)
    }

    /// Renders at full native resolution, for export.
    public func renderFullResolution(baseParams: RawBaseParameters, stageStack: [StageParameters]) -> CGImage? {
        guard let filter else { return nil }
        apply(baseParams)
        filter.scaleFactor = 1
        filter.isDraftModeEnabled = false
        guard var output = filter.outputImage else { return nil }
        for stage in stageStack where !stage.isEmpty {
            output = applyStage(stage, to: output)
        }
        return context.createCGImage(output, from: output.extent)
    }
}
