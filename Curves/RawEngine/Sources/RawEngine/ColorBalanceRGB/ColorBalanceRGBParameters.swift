import Foundation

/// Parameters for the color balance RGB module ("the wheels"), ported from darktable's
/// `colorbalancergb` module (`src/iop/colorbalancergb.c`, tag `release-5.6.0`). Field names and
/// defaults mirror `dt_iop_colorbalancergb_params_t` exactly.
///
/// Scope note: this port covers the 4-way color wheels (global/shadows/midtones/highlights
/// lift, in Y/chroma/hue), the luminance-based zone opacity masks, hue rotation, linear
/// chroma boost + vibrance, and fulcrumed contrast — the visually dominant, most-used part of
/// the module. It deliberately does **not** implement the separate perceptual
/// saturation/brilliance stage, which branches on a "saturation formula" (JzAzBz or
/// darktable's own newer "UCS 22" colorspace) and needs its own gamut-mapping LUT — that's a
/// distinct scoping decision the user made explicitly for this phase, not an oversight. At this
/// port's defaults (`saturation*`/`brilliance*` = 0), that stage is a no-op in darktable's own
/// source too, so skipping it changes nothing until those controls are exposed in a later pass.
///
/// Also out of scope, consistent with `FilmicRGBParameters`: darktable's D50 ICC-profile
/// pipeline and the CAT16 D50↔D65 chromatic-adaptation step it requires. This port assumes the
/// incoming pipeline RGB is already linear sRGB/Rec709 primaries at the D65 white point — the
/// working space `CIRAWFilter`'s output is treated as — and converts directly to CIE XYZ D65,
/// skipping the D50 round-trip. See `ColorBalanceRGBMath.swift`.
public struct ColorBalanceRGBParameters: Equatable, Sendable {
    public var shadowsY: Double
    public var shadowsC: Double
    public var shadowsH: Double
    public var midtonesY: Double
    public var midtonesC: Double
    public var midtonesH: Double
    public var highlightsY: Double
    public var highlightsC: Double
    public var highlightsH: Double
    public var globalY: Double
    public var globalC: Double
    public var globalH: Double
    /// Shadows fall-off — how far the shadow zone's opacity mask extends. darktable default 1.0.
    public var shadowsWeight: Double
    /// Log2 exposure offset of the pivot used by the midtones power/gamma stage. darktable default 0.
    public var whiteFulcrum: Double
    /// Highlights fall-off. darktable default 1.0.
    public var highlightsWeight: Double
    public var chromaShadows: Double
    public var chromaHighlights: Double
    public var chromaGlobal: Double
    public var chromaMidtones: Double
    /// Hue shift, in degrees. darktable default 0.
    public var hueAngle: Double
    /// Middle-grey fulcrum used by the opacity masks, as a fraction. darktable default 0.1845.
    public var maskGreyFulcrum: Double
    /// Global vibrance (saturation boost weighted down as chroma approaches its max). darktable default 0.
    public var vibrance: Double
    /// Middle-grey pivot for the contrast stage. darktable default 0.1845.
    public var greyFulcrum: Double
    /// Contrast around `greyFulcrum`. darktable default 0.
    public var contrast: Double

    public init(
        shadowsY: Double = 0, shadowsC: Double = 0, shadowsH: Double = 0,
        midtonesY: Double = 0, midtonesC: Double = 0, midtonesH: Double = 0,
        highlightsY: Double = 0, highlightsC: Double = 0, highlightsH: Double = 0,
        globalY: Double = 0, globalC: Double = 0, globalH: Double = 0,
        shadowsWeight: Double = 1.0,
        whiteFulcrum: Double = 0.0,
        highlightsWeight: Double = 1.0,
        chromaShadows: Double = 0, chromaHighlights: Double = 0,
        chromaGlobal: Double = 0, chromaMidtones: Double = 0,
        hueAngle: Double = 0,
        maskGreyFulcrum: Double = 0.1845,
        vibrance: Double = 0,
        greyFulcrum: Double = 0.1845,
        contrast: Double = 0
    ) {
        self.shadowsY = shadowsY; self.shadowsC = shadowsC; self.shadowsH = shadowsH
        self.midtonesY = midtonesY; self.midtonesC = midtonesC; self.midtonesH = midtonesH
        self.highlightsY = highlightsY; self.highlightsC = highlightsC; self.highlightsH = highlightsH
        self.globalY = globalY; self.globalC = globalC; self.globalH = globalH
        self.shadowsWeight = shadowsWeight
        self.whiteFulcrum = whiteFulcrum
        self.highlightsWeight = highlightsWeight
        self.chromaShadows = chromaShadows; self.chromaHighlights = chromaHighlights
        self.chromaGlobal = chromaGlobal; self.chromaMidtones = chromaMidtones
        self.hueAngle = hueAngle
        self.maskGreyFulcrum = maskGreyFulcrum
        self.vibrance = vibrance
        self.greyFulcrum = greyFulcrum
        self.contrast = contrast
    }

    /// darktable's shipped defaults — all 4 wheels neutral, i.e. a no-op until the user drags
    /// something.
    public static let darktableDefault = ColorBalanceRGBParameters()
}
