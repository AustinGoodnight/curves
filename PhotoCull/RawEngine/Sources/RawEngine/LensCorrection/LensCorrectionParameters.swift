import Foundation

/// One of lensfun's geometric distortion models — `poly3`/`poly5`/`ptlens` are the only three
/// present anywhere in the bundled `LensCorrectionDatabase` (lensfun's own `acm` model exists in
/// the format but no calibration in this database's 1500+ lenses uses it). See
/// `LensCorrectionKernel`'s doc comment for the exact per-model formula, ported from lensfun's
/// `mod-coord.cpp`.
public enum LensDistortionModel: Equatable, Sendable {
    case poly3(k1: Double)
    case poly5(k1: Double, k2: Double)
    case ptlens(a: Double, b: Double, c: Double)
}

/// lensfun's "pa" vignetting model — the only one present in the bundled database (`acm` isn't).
/// `C_corrected = C_source / (1 + k1·r² + k2·r⁴ + k3·r⁶)`, `r` in the same lens-centered normalized
/// coordinate system `LensDistortionModel` uses. See `mod-color.cpp`'s `ModifyColor_DeVignetting_PA`.
public struct LensVignettingTerms: Equatable, Sendable {
    public var k1: Double
    public var k2: Double
    public var k3: Double

    public init(k1: Double, k2: Double, k3: Double) {
        self.k1 = k1
        self.k2 = k2
        self.k3 = k3
    }
}

/// Transverse chromatic aberration — a per-channel (red/blue; green stays the reference channel)
/// radial rescale applied on top of whatever `LensDistortionModel` already computed. See
/// `mod-subpix.cpp`'s `ModifyCoord_TCA_Linear`/`ModifyCoord_TCA_Poly3`.
public enum LensTCAModel: Equatable, Sendable {
    case linear(kr: Double, kb: Double)
    case poly3(vr: Double, vb: Double, cr: Double, cb: Double, br: Double, bb: Double)
}

/// Everything `LensCorrectionKernel` needs to undo one render's lens-specific geometric distortion,
/// vignetting, and transverse chromatic aberration — resolved once per render (not per pixel) by
/// `LensCorrectionDatabase.profile(cameraModel:lensModel:focalLength:aperture:)` from the shot's own
/// EXIF readouts (`PhotoAsset.cameraModel`/`lensModel`/`focalLength`/`aperture`, captured at import
/// — see `PhotoAsset`'s doc comment).
///
/// Lives on `RawBaseParameters`, not `StageParameters` — same "applied once, not stackable"
/// reasoning as exposure/white-balance/sharpness (see `RawBaseParameters`'s doc comment): lens
/// distortion/vignetting/CA are fixed properties of the physical lens that took the shot, not a
/// creative, per-region choice a mask could meaningfully limit — there's exactly one correct
/// correction per photo, and running it twice or letting a user "add another lens correction stage"
/// would be meaningless.
public struct LensCorrectionParameters: Equatable, Sendable {
    public var distortion: LensDistortionModel?
    public var vignetting: LensVignettingTerms?
    public var tca: LensTCAModel?
    /// Real (not nominal) focal length in mm — defaults to the shot's nominal EXIF focal length,
    /// which is what the bundled database's calibration entries almost always assume too (lensfun's
    /// own `RealFocal` attribute, when the XML doesn't specify one — see `lensfun.h.in`'s doc
    /// comment on it — defaults the same way, mostly relevant for fisheyes, which this app doesn't
    /// attempt to distinguish).
    public var realFocalLength: Double
    /// The matched LENS calibration's own crop factor/aspect ratio — distinct from `cameraCropFactor`
    /// below — needed to rescale the raw Hugin/PTLens-coordinate polynomial coefficients into this
    /// render's own normalized coordinate system. See `rescale_polynomial_coefficients` in lensfun's
    /// `mod-coord.cpp`/`mod-color.cpp`/`mod-subpix.cpp`, ported into `LensCorrectionKernel`.
    public var calibrationCropFactor: Double
    public var calibrationAspectRatio: Double
    /// The camera body's own sensor crop factor — matched separately from the lens, since EXIF
    /// gives both a camera and a lens model string — feeding `NormScale`, the pixel-to-normalized-
    /// radius conversion. Falls back to `calibrationCropFactor` when the camera body isn't found in
    /// the database (see `LensCorrectionDatabase.profile`).
    public var cameraCropFactor: Double
    /// 0...1 blend between untouched (0) and the full calculated correction (1) — a user-facing
    /// "Amount" dial layered on top of lensfun's own model, not part of it.
    public var intensity: Double

    public init(
        distortion: LensDistortionModel? = nil,
        vignetting: LensVignettingTerms? = nil,
        tca: LensTCAModel? = nil,
        realFocalLength: Double,
        calibrationCropFactor: Double,
        calibrationAspectRatio: Double,
        cameraCropFactor: Double,
        intensity: Double = 1
    ) {
        self.distortion = distortion
        self.vignetting = vignetting
        self.tca = tca
        self.realFocalLength = realFocalLength
        self.calibrationCropFactor = calibrationCropFactor
        self.calibrationAspectRatio = calibrationAspectRatio
        self.cameraCropFactor = cameraCropFactor
        self.intensity = intensity
    }

    /// True when there's no calibration data to apply at all — `LensCorrectionKernel.apply` skips
    /// the GPU pass entirely rather than running a no-op kernel, matching every other module's
    /// "nil/empty means skip" convention in this codebase.
    public var isEmpty: Bool { distortion == nil && vignetting == nil && tca == nil }
}
