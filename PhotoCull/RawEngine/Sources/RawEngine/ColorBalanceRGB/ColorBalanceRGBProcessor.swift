import Foundation

/// The zone opacity masks (shadow/midtone/highlight), evaluated from a pixel's (transformed)
/// luminance. Direct port of `opacity_masks()`.
struct ZoneOpacities: Equatable {
    var shadow: Double
    var midtone: Double
    var highlight: Double

    var complement: ZoneOpacities {
        ZoneOpacities(shadow: 1 - shadow, midtone: 1 - midtone, highlight: 1 - highlight)
    }
}

/// Per-zone grading-RGB multipliers/offsets derived once per parameter change — the equivalent
/// of `dt_iop_colorbalancergb_data_t`'s color-balance fields. Everything related to the
/// perceptual saturation/brilliance stage is intentionally absent (see
/// `ColorBalanceRGBParameters`'s scope note).
struct ColorBalanceRGBDerived: Equatable {
    var global = Triplet.zero
    var shadows = Triplet.zero
    var highlights = Triplet.zero
    var midtones = Triplet.zero
    var midtonesY = 1.0

    var shadowsWeight = 0.0
    var highlightsWeight = 0.0
    var midtonesWeight = 0.0
    var maskGreyFulcrum = 0.0
    var whiteFulcrum = 1.0
    var greyFulcrum = 0.1845
    var contrast = 1.0

    var chromaGlobal = 0.0
    var chromaShadows = 0.0
    var chromaMidtones = 0.0
    var chromaHighlights = 0.0
    var vibrance = 0.0
    var hueAngle = 0.0
}

enum ColorBalanceRGBProcessor {
    /// Exponent used to re-weight luminance before feeding it to the opacity masks and to
    /// `mask_grey_fulcrum` — transcribed verbatim from `colorbalancergb.c` (unexplained in
    /// darktable's own source beyond "center middle grey in 50%").
    private static let maskLumaExponent = 0.4101205819200422

    /// Port of `commit_params()`'s color-balance derivation (the parts this scope implements).
    static func compute(_ p: ColorBalanceRGBParameters) -> ColorBalanceRGBDerived {
        var d = ColorBalanceRGBDerived()

        d.vibrance = p.vibrance
        d.contrast = 1.0 + p.contrast
        d.greyFulcrum = p.greyFulcrum
        d.chromaGlobal = p.chromaGlobal
        d.chromaShadows = p.chromaShadows
        d.chromaMidtones = p.chromaMidtones
        d.chromaHighlights = p.chromaHighlights
        d.hueAngle = p.hueAngle * .pi / 180.0

        let whiteReferenceRGB = ColorBalanceMath.ychToGradingRGB(Ych(Y: 1, c: 0, cosH: 1, sinH: 0))

        func wheelRGB(chroma: Double, hueDegrees: Double) -> Triplet {
            let hue = (hueDegrees - 30.0) * .pi / 180.0 // CONVENTIONAL_DEG_TO_YRG_RAD
            let ych = ColorBalanceMath.makeYch(Y: 1, c: chroma, h: hue)
            return ColorBalanceMath.ychToGradingRGB(ych)
        }

        let globalRGB = wheelRGB(chroma: p.globalC, hueDegrees: p.globalH)
        d.global = Triplet(
            x: (globalRGB.x - whiteReferenceRGB.x) + whiteReferenceRGB.x * p.globalY,
            y: (globalRGB.y - whiteReferenceRGB.y) + whiteReferenceRGB.y * p.globalY,
            z: (globalRGB.z - whiteReferenceRGB.z) + whiteReferenceRGB.z * p.globalY
        )

        let shadowsRGB = wheelRGB(chroma: p.shadowsC, hueDegrees: p.shadowsH)
        d.shadows = Triplet(
            x: 1 + (shadowsRGB.x - whiteReferenceRGB.x) + p.shadowsY,
            y: 1 + (shadowsRGB.y - whiteReferenceRGB.y) + p.shadowsY,
            z: 1 + (shadowsRGB.z - whiteReferenceRGB.z) + p.shadowsY
        )
        d.shadowsWeight = 2.0 + p.shadowsWeight * 2.0

        let highlightsRGB = wheelRGB(chroma: p.highlightsC, hueDegrees: p.highlightsH)
        d.highlights = Triplet(
            x: 1 + (highlightsRGB.x - whiteReferenceRGB.x) + p.highlightsY,
            y: 1 + (highlightsRGB.y - whiteReferenceRGB.y) + p.highlightsY,
            z: 1 + (highlightsRGB.z - whiteReferenceRGB.z) + p.highlightsY
        )
        d.highlightsWeight = 2.0 + p.highlightsWeight * 2.0

        let midtonesRGB = wheelRGB(chroma: p.midtonesC, hueDegrees: p.midtonesH)
        d.midtones = Triplet(
            x: 1 / (1 + (midtonesRGB.x - whiteReferenceRGB.x)),
            y: 1 / (1 + (midtonesRGB.y - whiteReferenceRGB.y)),
            z: 1 / (1 + (midtonesRGB.z - whiteReferenceRGB.z))
        )
        d.midtonesY = 1 / (1 + p.midtonesY)
        d.whiteFulcrum = exp2(p.whiteFulcrum)
        d.midtonesWeight = sq(d.shadowsWeight) * sq(d.highlightsWeight)
            / (sq(d.shadowsWeight) + sq(d.highlightsWeight))
        d.maskGreyFulcrum = pow(p.maskGreyFulcrum, maskLumaExponent)

        return d
    }

    static func opacityMasks(_ x: Double, _ d: ColorBalanceRGBDerived) -> ZoneOpacities {
        let xOffset = x - d.maskGreyFulcrum
        let xOffsetNorm = xOffset / d.maskGreyFulcrum
        let alpha = 1.0 / (1.0 + exp(xOffsetNorm * d.shadowsWeight))
        let beta = 1.0 / (1.0 + exp(-xOffsetNorm * d.highlightsWeight))
        let alphaComp = 1.0 - alpha
        let betaComp = 1.0 - beta
        let gamma = exp(-sq(xOffset) * d.midtonesWeight / 4.0) * sq(alphaComp) * sq(betaComp) * 8.0
        return ZoneOpacities(shadow: alpha, midtone: gamma, highlight: beta)
    }

    /// Port of `process()`'s per-pixel color-balance path, with the perceptual
    /// saturation/brilliance stage omitted (see `ColorBalanceRGBParameters`'s scope note) and
    /// the D50 ICC round-trip skipped in favor of direct linear-sRGB(D65)↔XYZ(D65) — this is
    /// the reference used both by tests and to write `ColorBalanceRGBKernel`'s CIKL source.
    static func apply(_ rgbIn: Triplet, _ d: ColorBalanceRGBDerived) -> Triplet {
        let clippedRGB = Triplet(x: max(rgbIn.x, 0), y: max(rgbIn.y, 0), z: max(rgbIn.z, 0))

        var ych = ColorBalanceMath.yrgToYch(ColorBalanceMath.lmsToYrg(ColorBalanceMath.xyzToLMS(ColorBalanceMath.rgbToXYZ(clippedRGB))))
        ych.Y = max(ych.Y, 0)

        let opacities = opacityMasks(pow(ych.Y, maskLumaExponent), d)
        let opacitiesComp = opacities.complement

        // Hue rotation.
        let cosA = cos(d.hueAngle), sinA = sin(d.hueAngle)
        let cosH = ych.cosH, sinH = ych.sinH
        ych.cosH = cosA * cosH - sinA * sinH
        ych.sinH = sinA * cosH + cosA * sinH

        // Linear chroma boost + vibrance, then gamut clip.
        let chromaBoost = d.chromaGlobal
            + opacities.shadow * d.chromaShadows
            + opacities.midtone * d.chromaMidtones
            + opacities.highlight * d.chromaHighlights
        let vibranceTerm = d.vibrance * (1.0 - pow(ych.c, abs(d.vibrance)))
        let chromaFactor = max(1.0 + chromaBoost + vibranceTerm, 0)
        ych.c *= chromaFactor
        ych = ColorBalanceMath.gamutCheckYrg(ych)

        var rgb = ColorBalanceMath.lmsToGradingRGB(ColorBalanceMath.yrgToLMS(ColorBalanceMath.ychToYrg(ych)))

        // Color balance: global offset, then shadows/highlights slopes blended by opacity.
        rgb = Triplet(x: rgb.x + d.global.x, y: rgb.y + d.global.y, z: rgb.z + d.global.z)
        func balanceChannel(_ c: Double, _ shadow: Double, _ highlight: Double) -> Double {
            c * (opacitiesComp.highlight * (opacitiesComp.shadow + opacities.shadow * shadow)
                + opacities.highlight * highlight)
        }
        rgb = Triplet(
            x: balanceChannel(rgb.x, d.shadows.x, d.highlights.x),
            y: balanceChannel(rgb.y, d.shadows.y, d.highlights.y),
            z: balanceChannel(rgb.z, d.shadows.z, d.highlights.z)
        )

        // Midtones power (per channel), signed to tolerate negative grading-RGB values.
        func midtonesPower(_ c: Double, _ exponent: Double) -> Double {
            let sign: Double = c < 0 ? -1 : 1
            let scaled = abs(c) / d.whiteFulcrum
            return pow(scaled, exponent) * sign * d.whiteFulcrum
        }
        rgb = Triplet(
            x: midtonesPower(rgb.x, d.midtones.x),
            y: midtonesPower(rgb.y, d.midtones.y),
            z: midtonesPower(rgb.z, d.midtones.z)
        )

        // Recompute Yrg — the per-channel ops above don't preserve color, so redo luminance ops
        // from the resulting grading RGB.
        var yrg = ColorBalanceMath.lmsToYrg(ColorBalanceMath.gradingRGBToLMS(rgb))

        // Y midtones gamma, then fulcrumed contrast.
        yrg.x = pow(max(yrg.x / d.whiteFulcrum, 0), d.midtonesY) * d.whiteFulcrum
        yrg.x = d.greyFulcrum * pow(yrg.x / d.greyFulcrum, d.contrast)

        let xyzOut = ColorBalanceMath.lmsToXYZ(ColorBalanceMath.yrgToLMS(yrg))
        let rgbOut = ColorBalanceMath.xyzToRGB(xyzOut)
        return Triplet(x: max(rgbOut.x, 0), y: max(rgbOut.y, 0), z: max(rgbOut.z, 0))
    }
}

private func sq(_ x: Double) -> Double { x * x }
