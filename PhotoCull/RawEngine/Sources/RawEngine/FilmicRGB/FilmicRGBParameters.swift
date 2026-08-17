import Foundation

/// Parameters for the filmic RGB tone curve, ported from darktable's `filmicrgb` module
/// (`src/iop/filmicrgb.c`, tag `release-5.6.0`). Field names and defaults mirror
/// `dt_iop_filmicrgb_params_t` exactly so this stays checkable against the real source.
///
/// Scope note: darktable's module has five chrominance-preservation methods and five
/// generations of "color science" formulas, selectable per-edit. This port implements one
/// coherent, real (non-default, but user-selectable in darktable) combination —
/// `preserve_color = none` (per-channel "split" processing) with the "v4/v5 (2020/2021)"
/// color science formulas — because it's the path documented in `filmic_split_v2_v3()` and
/// avoids a divide-by-zero in the desaturation formula that the actual default
/// ("RGB power norm" + "v7 (2023)") hits at `saturation == 0`. The RGB power-norm path and
/// later color-science versions are not ported; that's a scoping decision for this phase, not
/// an oversight.
public struct FilmicRGBParameters: Equatable, Sendable {
    /// Scene-referred middle grey, as % of white. darktable default 18.45.
    public var greyPointSource: Double
    /// Black relative exposure, in EV below middle grey. darktable default -8.0.
    public var blackPointSource: Double
    /// White relative exposure, in EV above middle grey. darktable default 4.0.
    public var whitePointSource: Double
    /// Target middle grey on the display, as %. darktable default 18.45.
    public var greyPointTarget: Double
    /// Target black luminance on the display, as %. darktable default 0.01517634.
    public var blackPointTarget: Double
    /// Target white luminance on the display, as %. darktable default 100.
    public var whitePointTarget: Double
    /// "Hardness" — the display transfer function power. darktable default 4.0.
    public var outputPower: Double
    /// Width of the linear (unclipped) latitude region, as % of the source dynamic range.
    /// darktable default 0.01.
    public var latitude: Double
    /// Contrast of the linear region. darktable default 1.0.
    public var contrast: Double
    /// Saturation adjustment applied via desaturation blending toward luminance, in %.
    /// darktable default 0.
    public var saturation: Double
    /// Shadows/highlights balance shift, in %. darktable default 0.
    public var balance: Double
    public var shadowsCurve: FilmicCurveType
    public var highlightsCurve: FilmicCurveType

    public init(
        greyPointSource: Double = 18.45,
        blackPointSource: Double = -8.0,
        whitePointSource: Double = 4.0,
        greyPointTarget: Double = 18.45,
        blackPointTarget: Double = 0.01517634,
        whitePointTarget: Double = 100,
        outputPower: Double = 4.0,
        latitude: Double = 0.01,
        contrast: Double = 1.0,
        saturation: Double = 0,
        balance: Double = 0,
        shadowsCurve: FilmicCurveType = .poly4,
        highlightsCurve: FilmicCurveType = .poly4
    ) {
        self.greyPointSource = greyPointSource
        self.blackPointSource = blackPointSource
        self.whitePointSource = whitePointSource
        self.greyPointTarget = greyPointTarget
        self.blackPointTarget = blackPointTarget
        self.whitePointTarget = whitePointTarget
        self.outputPower = outputPower
        self.latitude = latitude
        self.contrast = contrast
        self.saturation = saturation
        self.balance = balance
        self.shadowsCurve = shadowsCurve
        self.highlightsCurve = highlightsCurve
    }

    /// darktable's shipped defaults — a strong global-contrast S-curve, matching what a fresh
    /// instance of the module looks like before any user adjustment or auto-tuning.
    public static let darktableDefault = FilmicRGBParameters()
}

/// Mirrors `dt_iop_filmicrgb_curve_type_t`. Controls how the toe/shoulder segments are fit:
/// a 4th-order polynomial ("hard"), 3rd-order ("soft"), or a rational function ("safe", never
/// overshoots).
public enum FilmicCurveType: Int, Equatable, Sendable {
    case poly4 = 0
    case poly3 = 1
    case rational = 2
}
