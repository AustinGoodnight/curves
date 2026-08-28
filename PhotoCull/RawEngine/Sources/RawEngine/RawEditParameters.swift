import Foundation

/// Native `CIRAWFilter` inputs — applied once, during RAW decode, before any stage's kernel
/// passes run. Every field is optional — `nil` means "use the filter's as-shot/vendor default for
/// this image", not zero. Unlike `StageParameters`, there is no per-stage version of these: a RAW
/// file is only demosaiced once per render, so exposure/white-balance/sharpness can't be stacked
/// the way the four kernel modules can (see `StageParameters`'s doc comment).
public struct RawBaseParameters: Equatable, Sendable {
    public var exposure: Double?
    public var boostAmount: Double?
    public var neutralTemperature: Double?
    public var neutralTint: Double?
    public var sharpnessAmount: Double?
    /// `nil` means "no denoise". Applied immediately after RAW decode, ahead of lens correction —
    /// denoising before the geometric warp keeps noise statistics spatially uniform going in,
    /// rather than running OIDN on already-resampled pixels (see `DenoiseFilter`'s doc comment).
    public var denoise: DenoiseParameters?
    /// `nil` means "no lens correction" — either no lens matched the shot's EXIF in
    /// `LensCorrectionDatabase`, or the user turned it off. Lives here, not on `StageParameters`,
    /// for the same reason as every other field on this struct — see `LensCorrectionParameters`'s
    /// doc comment.
    public var lensCorrection: LensCorrectionParameters?
    /// `nil` means "no spots to heal/clone". Applied after the stage stack but still ahead of
    /// `crop` — see `SpotRemoval`'s doc comment for why its coordinates are defined in this,
    /// pre-crop frame, and `RawImageRenderer`'s render methods for exactly where this runs.
    public var spotRemoval: SpotRemovalParameters?
    /// `nil` means "no AI-removed objects". Applied immediately after `spotRemoval` (same pre-crop
    /// frame, same reasoning) — see `ObjectRemovalKernel`'s doc comment for why this is cheap
    /// despite the fill itself (`InpaintingFilter`) being expensive to produce.
    public var objectRemovals: ObjectRemovalParameters?
    /// `nil` means "no straighten/crop" (full, unrotated frame). Unlike every other field on this
    /// struct, `RawImageRenderer` applies this dead last, after the stage stack — see
    /// `CropParameters`'s doc comment for why.
    public var crop: CropParameters?

    public init(
        exposure: Double? = nil,
        boostAmount: Double? = nil,
        neutralTemperature: Double? = nil,
        neutralTint: Double? = nil,
        sharpnessAmount: Double? = nil,
        denoise: DenoiseParameters? = nil,
        lensCorrection: LensCorrectionParameters? = nil,
        spotRemoval: SpotRemovalParameters? = nil,
        objectRemovals: ObjectRemovalParameters? = nil,
        crop: CropParameters? = nil
    ) {
        self.exposure = exposure
        self.boostAmount = boostAmount
        self.neutralTemperature = neutralTemperature
        self.neutralTint = neutralTint
        self.sharpnessAmount = sharpnessAmount
        self.denoise = denoise
        self.lensCorrection = lensCorrection
        self.spotRemoval = spotRemoval
        self.objectRemovals = objectRemovals
        self.crop = crop
    }

    public static let none = RawBaseParameters()
}

/// One stage's worth of the five *stackable* `CIColorKernel` modules. `RawImageRenderer` runs one
/// of these per active stage (Scene, then Single, then Custom stages in order), each feeding its
/// output forward as the next stage's input — a real sequential composite, not a merged parameter
/// set. That's a deliberate choice, not just the simplest option: these modules are nonlinear
/// (tone curves and Filmic's tone mapping compose as `f2(f1(x))`, not by adding control points),
/// so there's no parameter-level shortcut that reproduces true stacking, and future per-stage
/// masking needs the sequential form anyway — a masked stage limits which pixels its pass touches,
/// which has no meaning as a merged parameter set.
public struct StageParameters: Equatable, Sendable {
    /// `nil` means "no dehaze". Applied first, ahead of every creative-grading module — haze
    /// removal is a basic-panel correction, not a grade (see `DehazeParameters`).
    public var dehaze: DehazeParameters?
    /// `nil` means "no filmic tone curve" — the Phase 2 passthrough behavior. Set to enable the
    /// filmic RGB module (see `FilmicRGBParameters`).
    public var filmicRGB: FilmicRGBParameters?
    /// `nil` means "no color balance wheels". Applied after `filmicRGB` — darktable's default
    /// scene-referred pipeline grades color on the already-tonemapped result (see
    /// `ColorBalanceRGBParameters`).
    public var colorBalanceRGB: ColorBalanceRGBParameters?
    /// `nil` means "no color zones EQ". Applied after `colorBalanceRGB` — grouped with it as the
    /// two hue-driven grading tools, both ahead of the final tone curve (see
    /// `ColorZonesParameters`).
    public var colorZones: ColorZonesParameters?
    /// `nil` means "no RGB curve". Applied after `colorZones` — the final tonal shaping pass,
    /// matching where a Lightroom-style tone curve sits in most editors (see
    /// `RGBCurveParameters`).
    public var rgbCurve: RGBCurveParameters?
    /// `nil` means "no 3D LUT". Applied last, after every other grading pass — a "film
    /// simulation"/creative-look grade layered on top of the already-graded image, matching how
    /// LUT packs from VSCO/RNI/etc. are meant to be used (see `LUT3DParameters`).
    public var lut3D: LUT3DParameters?
    /// A grayscale mask PNG (white = fully affected, black = unaffected) limiting which pixels
    /// this stage's kernel passes touch — `nil` means the stage applies to the whole image. See
    /// `RawImageRenderer.applyStage(_:to:)` for how it's composited.
    public var maskData: Data?

    public init(
        dehaze: DehazeParameters? = nil,
        filmicRGB: FilmicRGBParameters? = nil,
        colorBalanceRGB: ColorBalanceRGBParameters? = nil,
        colorZones: ColorZonesParameters? = nil,
        rgbCurve: RGBCurveParameters? = nil,
        lut3D: LUT3DParameters? = nil,
        maskData: Data? = nil
    ) {
        self.dehaze = dehaze
        self.filmicRGB = filmicRGB
        self.colorBalanceRGB = colorBalanceRGB
        self.colorZones = colorZones
        self.rgbCurve = rgbCurve
        self.lut3D = lut3D
        self.maskData = maskData
    }

    /// True when this stage contributes no kernel passes at all — the render loop can skip it
    /// entirely rather than running through the no-op checks.
    public var isEmpty: Bool {
        dehaze == nil && filmicRGB == nil && colorBalanceRGB == nil && colorZones == nil && rgbCurve == nil && lut3D == nil
    }

    public static let none = StageParameters()
}
