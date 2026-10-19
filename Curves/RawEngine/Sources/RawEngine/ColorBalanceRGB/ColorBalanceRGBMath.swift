import Foundation

/// A plain RGB-shaped triplet, reused for XYZ/LMS/Yrg/gradingRGB — matching how darktable's
/// `dt_aligned_pixel_t` is reused across all of these spaces.
struct Triplet: Equatable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Triplet(x: 0, y: 0, z: 0)
}

/// Ych: luminance + polar chroma/hue, stored as (Y, chroma, cos h, sin h) to avoid repeated
/// trig, exactly mirroring darktable's `Yrg_to_Ych`/`Ych_to_Yrg` convention.
struct Ych: Equatable {
    var Y: Double
    var c: Double
    var cosH: Double
    var sinH: Double
}

/// Colorspace conversions ported from `colorspaces_inline_conversions.h` (release-5.6.0).
/// Matrices are transcribed as darktable's own *non-transposed* form (i.e. already flipped
/// from the `_trans` arrays some of these were declared as in the C source — verified by
/// working through `dt_apply_transposed_color_matrix`'s indexing, which applies the transpose
/// of whatever's passed to it) so a plain row-major matrix-vector product is correct here.
enum ColorBalanceMath {
    // MARK: RGB (linear sRGB/Rec709, D65) <-> XYZ (D65)
    //
    // darktable normally goes pipeline-RGB -> XYZ D50 (its ICC profile's matrix) -> XYZ D65
    // (CAT16 adaptation) before this module's math starts. This port skips that: it assumes the
    // incoming RGB is already linear sRGB/Rec709 at D65 (this engine's working space, per
    // `FilmicRGBParameters`'s equivalent scope note) and uses the standard, un-adapted sRGB
    // primaries matrix directly — see `ColorBalanceRGBParameters` for the full rationale.

    static func rgbToXYZ(_ rgb: Triplet) -> Triplet {
        Triplet(
            x: 0.4124564 * rgb.x + 0.3575761 * rgb.y + 0.1804375 * rgb.z,
            y: 0.2126729 * rgb.x + 0.7151522 * rgb.y + 0.0721750 * rgb.z,
            z: 0.0193339 * rgb.x + 0.1191920 * rgb.y + 0.9503041 * rgb.z
        )
    }

    static func xyzToRGB(_ xyz: Triplet) -> Triplet {
        Triplet(
            x: 3.2404542 * xyz.x - 1.5371385 * xyz.y - 0.4985314 * xyz.z,
            y: -0.9692660 * xyz.x + 1.8760108 * xyz.y + 0.0415560 * xyz.z,
            z: 0.0556434 * xyz.x - 0.2040259 * xyz.y + 1.0572252 * xyz.z
        )
    }

    // MARK: XYZ (D65) <-> LMS (CIE 2006, D65)
    // Richard A. Kirk's approximation, transcribed from `XYZ_D65_to_LMS_2006_D65` /
    // `LMS_2006_D65_to_XYZ_D65` in colorspaces_inline_conversions.h (already non-transposed).

    static func xyzToLMS(_ xyz: Triplet) -> Triplet {
        Triplet(
            x: 0.257085 * xyz.x + 0.859943 * xyz.y - 0.031061 * xyz.z,
            y: -0.394427 * xyz.x + 1.175800 * xyz.y + 0.106423 * xyz.z,
            z: 0.064856 * xyz.x - 0.076250 * xyz.y + 0.559067 * xyz.z
        )
    }

    static func lmsToXYZ(_ lms: Triplet) -> Triplet {
        Triplet(
            x: 1.80794659 * lms.x - 1.29971660 * lms.y + 0.34785879 * lms.z,
            y: 0.61783960 * lms.x + 0.39595453 * lms.y - 0.04104687 * lms.z,
            z: -0.12546960 * lms.x + 0.20478038 * lms.y + 1.74274183 * lms.z
        )
    }

    // MARK: LMS <-> Filmlight "grading RGB"
    // Transposed from `filmlightRGB_D65_to_LMS_D65_trans` / `LMS_D65_to_filmlightRGB_D65_trans`
    // (colorspaces_inline_conversions.h) per `dt_apply_transposed_color_matrix`'s semantics.

    static func gradingRGBToLMS(_ rgb: Triplet) -> Triplet {
        Triplet(
            x: 0.95 * rgb.x + 0.38 * rgb.y,
            y: 0.05 * rgb.x + 0.62 * rgb.y + 0.03 * rgb.z,
            z: 0.97 * rgb.z
        )
    }

    static func lmsToGradingRGB(_ lms: Triplet) -> Triplet {
        Triplet(
            x: 1.08771930 * lms.x - 0.66666667 * lms.y + 0.02061856 * lms.z,
            y: -0.0877193 * lms.x + 1.66666667 * lms.y - 0.05154639 * lms.z,
            z: 1.03092784 * lms.z
        )
    }

    // MARK: LMS <-> Yrg, Yrg <-> Ych
    // Direct transcription of `LMS_to_Yrg`/`Yrg_to_LMS`/`Yrg_to_Ych`/`Ych_to_Yrg`/`make_Ych`.

    static func lmsToYrg(_ lms: Triplet) -> Triplet {
        let Y = 0.68990272 * lms.x + 0.34832189 * lms.y
        let a = lms.x + lms.y + lms.z
        let normalized = a == 0 ? Triplet.zero : Triplet(x: lms.x / a, y: lms.y / a, z: lms.z / a)
        let rgb = lmsToGradingRGB(normalized)
        return Triplet(x: Y, y: rgb.x, z: rgb.y)
    }

    static func yrgToLMS(_ yrg: Triplet) -> Triplet {
        let Y = yrg.x
        let r = yrg.y
        let g = yrg.z
        let b = 1.0 - r - g
        let lms = gradingRGBToLMS(Triplet(x: r, y: g, z: b))
        let denom = 0.68990272 * lms.x + 0.34832189 * lms.y
        let a = denom == 0 ? 0 : Y / denom
        return Triplet(x: lms.x * a, y: lms.y * a, z: lms.z * a)
    }

    private static let d65R = 0.21902143
    private static let d65G = 0.54371398

    static func yrgToYch(_ yrg: Triplet) -> Ych {
        let Y = yrg.x
        let r = yrg.y - d65R
        let g = yrg.z - d65G
        let c = (g * g + r * r).squareRoot()
        let cosH = c != 0 ? r / c : 1.0
        let sinH = c != 0 ? g / c : 0.0
        return Ych(Y: Y, c: c, cosH: cosH, sinH: sinH)
    }

    static func ychToYrg(_ ych: Ych) -> Triplet {
        Triplet(x: ych.Y, y: ych.c * ych.cosH + d65R, z: ych.c * ych.sinH + d65G)
    }

    static func makeYch(Y: Double, c: Double, h: Double) -> Ych {
        Ych(Y: Y, c: c, cosH: cos(h), sinH: sin(h))
    }

    static func ychToGradingRGB(_ ych: Ych) -> Triplet {
        lmsToGradingRGB(yrgToLMS(ychToYrg(ych)))
    }

    /// Clips chroma at constant hue/luminance so the resulting Yrg triplet stays within the
    /// (r,g) >= 0, r+g <= 1 gamut boundary. Direct port of `gamut_check_Yrg`.
    static func gamutCheckYrg(_ ych: Ych) -> Ych {
        var result = ych
        let yrg = ychToYrg(ych)
        var maxC = ych.c
        if yrg.y < 0 { maxC = min(-d65R / ych.cosH, maxC) }
        if yrg.z < 0 { maxC = min(-d65G / ych.sinH, maxC) }
        if yrg.y + yrg.z > 1 { maxC = min((1 - d65R - d65G) / (ych.cosH + ych.sinH), maxC) }
        result.c = maxC
        return result
    }
}
