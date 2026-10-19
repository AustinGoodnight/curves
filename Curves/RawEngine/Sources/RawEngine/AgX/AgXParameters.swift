import Foundation

/// Parameters for the AgX tone mapper, ported from darktable's `agx` module
/// (`src/iop/agx.c`). Field names/defaults mirror `dt_iop_agx_params_t`'s "scene-referred
/// default" preset (`_set_scene_referred_default_params` = `_set_default_curve_and_look_params`
/// + `_set_blenderlike_primaries`) — the configuration darktable itself auto-applies to a fresh
/// instance of the module.
///
/// Scope note: darktable's module also exposes a user-selectable "base primaries" profile
/// (export/working/Rec2020/DisplayP3/AdobeRGB/sRGB) and full inset/rotation/outset/unrotation
/// controls per channel, because it has to accommodate an arbitrary runtime ICC working profile.
/// This engine's working space is fixed (linear sRGB/Rec709, D65 — see `ColorBalanceRGBMath`'s
/// doc comment), so with the primaries fixed at darktable's own "blenderlike" default, every one
/// of AgX's colorimetry matrices collapses to a compile-time constant (see `AgXColorMatrices`) —
/// there is nothing left to expose. `toePower`/`shoulderPower`/`curveGamma`/`targetBlackRatio`/
/// `targetWhiteRatio` are kept as fields (for fidelity with the darktable struct) but are not
/// wired to any UI control, matching `FilmicRGBParameters`'s own precedent of implementing one
/// coherent, real darktable configuration rather than every exposed knob.
public struct AgXParameters: Equatable, Sendable {
    /// Pre-curve lift (shadow offset). darktable default 0.
    public var lookLift: Double
    /// Pre-curve slope (gain). darktable default 1.
    public var lookSlope: Double
    /// Post-curve brightness; darktable stores this as a UI-facing "brightness" (0 = darkest) that
    /// converts to an algorithmic power via `brightness < 1 ? 1/sqrt(brightness) : 1/brightness`.
    /// darktable default 1.
    public var lookBrightness: Double
    /// Post-curve saturation, applied as a luminance-blend in the rendering primaries. darktable
    /// default 1.
    public var lookSaturation: Double
    /// How much of the pre-curve hue to restore after the look/curve (0 = none, 1 = fully
    /// restored). darktable default 0.6.
    public var lookHueMixRatio: Double

    /// Black relative exposure, in EV below middle grey (0.18). darktable default -10.
    public var blackRelativeEV: Double
    /// White relative exposure, in EV above middle grey. darktable default 6.5.
    public var whiteRelativeEV: Double

    /// Contrast of the curve around the pivot. darktable default 3.0
    /// (`curve_contrast_around_pivot`).
    public var contrast: Double

    /// Toe power. Fixed at darktable's default; not exposed (see scope note above).
    public var toePower: Double
    /// Shoulder power. Fixed at darktable's default; not exposed.
    public var shoulderPower: Double
    /// Curve output gamma. Fixed at darktable's default; not exposed.
    public var curveGamma: Double
    /// Target display black, as a ratio of full scale. Fixed at darktable's default; not exposed.
    public var targetBlackRatio: Double
    /// Target display white, as a ratio of full scale. Fixed at darktable's default; not exposed.
    public var targetWhiteRatio: Double

    public init(
        lookLift: Double = 0,
        lookSlope: Double = 1,
        lookBrightness: Double = 1,
        lookSaturation: Double = 1,
        lookHueMixRatio: Double = 0.6,
        blackRelativeEV: Double = -10,
        whiteRelativeEV: Double = 6.5,
        contrast: Double = 3.0,
        toePower: Double = 1.5,
        shoulderPower: Double = 3.3,
        curveGamma: Double = 2.2,
        targetBlackRatio: Double = 0,
        targetWhiteRatio: Double = 1
    ) {
        self.lookLift = lookLift
        self.lookSlope = lookSlope
        self.lookBrightness = lookBrightness
        self.lookSaturation = lookSaturation
        self.lookHueMixRatio = lookHueMixRatio
        self.blackRelativeEV = blackRelativeEV
        self.whiteRelativeEV = whiteRelativeEV
        self.contrast = contrast
        self.toePower = toePower
        self.shoulderPower = shoulderPower
        self.curveGamma = curveGamma
        self.targetBlackRatio = targetBlackRatio
        self.targetWhiteRatio = targetWhiteRatio
    }

    /// darktable's auto-applied "scene-referred default" preset.
    public static let darktableDefault = AgXParameters()
}
