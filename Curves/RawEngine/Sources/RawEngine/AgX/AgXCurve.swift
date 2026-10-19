import Foundation

private let agxEpsilon = 1e-6
private let agxDefaultGamma = 2.2

/// Coefficients for the fitted toe / linear / shoulder AgX curve, derived once per parameter
/// change — mirrors `tone_mapping_params_t` from `agx.c`. The linear segment has zero width at
/// darktable's own defaults (`curve_linear_ratio_below/above_pivot == 0`, not exposed here — see
/// `AgXParameters`'s scope note), so `toeTransitionX == shoulderTransitionX == pivotX` in
/// practice; the three-branch shape is kept anyway for exact fidelity with the source formula.
struct AgXCurveCoefficients: Equatable {
    var slope = 0.0
    var intercept = 0.0

    var pivotX = 0.0
    var pivotY = 0.0
    var targetBlack = 0.0
    var targetWhite = 0.0

    var toePower = 0.0
    var toeTransitionX = 0.0
    var toeTransitionY = 0.0
    var toeScale = 0.0
    var needConvexToe = false
    var toeFallbackCoefficient = 0.0
    var toeFallbackPower = 0.0

    var shoulderPower = 0.0
    var shoulderTransitionX = 0.0
    var shoulderTransitionY = 0.0
    var shoulderScale = 0.0
    var needConcaveShoulder = false
    var shoulderFallbackCoefficient = 0.0
    var shoulderFallbackPower = 0.0

    var curveGamma = 0.0
    var rangeInEV = 0.0
    var blackRelativeEV = 0.0

    // Look
    var lookLift = 0.0
    var lookSlope = 0.0
    var lookPower = 0.0
    var lookSaturation = 0.0
    var lookHueMixRatio = 0.0
    var lookTuned = false
    var restoreHue = false
}

enum AgXCurve {
    /// `s_t`/`s_s` at https://www.desmos.com/calculator/yrysofmx8h — the scale factor that makes
    /// the sigmoid asymptote hit `(limitX, limitY)` while leaving the curve at `slope` at
    /// `(transitionX, transitionY)`. Port of `_scale`.
    private static func scale(limitX: Double, limitY: Double, transitionX: Double, transitionY: Double, slope: Double, power: Double) -> Double {
        let projectedRise = slope * max(agxEpsilon, limitX - transitionX)
        let actualRise = max(agxEpsilon, limitY - transitionY)
        let transformedProjectedRise = pow(projectedRise, -power)
        let transformedActualRise = pow(actualRise, -power)
        let base = max(agxEpsilon, transformedActualRise - transformedProjectedRise)
        return min(1e9, pow(base, -1.0 / power))
    }

    /// See https://www.desmos.com/calculator/gijzff3wlv. Port of `_calculate_slope_matching_power`.
    private static func slopeMatchingPower(slope: Double, dxTransitionToLimit: Double, dyTransitionToLimit: Double) -> Double {
        slope * dxTransitionToLimit / dyTransitionToLimit
    }

    /// Port of `_calculate_fallback_curve_coefficient`.
    private static func fallbackCurveCoefficient(dxTransitionToLimit: Double, dyTransitionToLimit: Double, exponent: Double) -> Double {
        dyTransitionToLimit / pow(dxTransitionToLimit, exponent)
    }

    /// Port of `_calculate_pivot_y_at_gamma` (with `auto_gamma` always false, see `AgXParameters`'s
    /// scope note — `curvePivotYLinearOutput` is fixed at darktable's 0.18 mid-gray default).
    private static func pivotY(atGamma gamma: Double, targetBlackRatio: Double, targetWhiteRatio: Double) -> Double {
        let curvePivotYLinearOutput = 0.18
        let clamped = min(max(curvePivotYLinearOutput, targetBlackRatio), targetWhiteRatio)
        return pow(clamped, 1.0 / gamma)
    }

    /// Port of `_calculate_slope_gamma_compensation` — keeps contrast around the pivot visually
    /// constant across different `curveGamma` values by compensating relative to gamma 2.2.
    private static func slopeGammaCompensation(gamma: Double, pivotY: Double, targetBlackRatio: Double, targetWhiteRatio: Double) -> Double {
        let pivotYAtDefaultGamma = Self.pivotY(atGamma: agxDefaultGamma, targetBlackRatio: targetBlackRatio, targetWhiteRatio: targetWhiteRatio)
        let derivativeAtCurrentGamma = gamma * pow(max(agxEpsilon, pivotY), gamma - 1.0)
        let derivativeAtDefaultGamma = agxDefaultGamma * pow(max(agxEpsilon, pivotYAtDefaultGamma), agxDefaultGamma - 1.0)
        return derivativeAtCurrentGamma / derivativeAtDefaultGamma
    }

    /// Port of `_calculate_tone_mapping_params`, restricted to darktable's own fixed defaults for
    /// the fields `AgXParameters` doesn't expose (`auto_gamma = false`,
    /// `curve_linear_ratio_below/above_pivot = 0`) — see `AgXParameters`'s scope note.
    static func compute(_ p: AgXParameters) -> AgXCurveCoefficients {
        var c = AgXCurveCoefficients()

        // Look
        c.lookLift = p.lookLift
        c.lookSlope = p.lookSlope
        c.lookSaturation = p.lookSaturation
        let brightness = p.lookBrightness
        c.lookPower = brightness < 1 ? 1.0 / sqrt(max(brightness, agxEpsilon)) : 1.0 / brightness
        c.lookHueMixRatio = p.lookHueMixRatio
        c.lookTuned = p.lookSlope != 1 || p.lookBrightness != 1 || p.lookLift != 0 || p.lookSaturation != 1
        c.restoreHue = p.lookHueMixRatio != 0

        // Log mapping
        c.blackRelativeEV = p.blackRelativeEV
        c.rangeInEV = p.whiteRelativeEV - p.blackRelativeEV

        // Pivot — darktable's `curve_pivot_x` default is `-black_relative_ev / range_in_ev` (mid-gray's
        // position in the log range); not independently adjustable here, see `AgXParameters`'s scope note.
        let rawPivotX = -p.blackRelativeEV / c.rangeInEV
        c.pivotX = min(max(rawPivotX, agxEpsilon), 1.0 - agxEpsilon)
        c.curveGamma = p.curveGamma
        c.pivotY = Self.pivotY(atGamma: c.curveGamma, targetBlackRatio: p.targetBlackRatio, targetWhiteRatio: p.targetWhiteRatio)

        // Avoid range altering slope — 16.5 EV is the default AgX range; keep the meaning of contrast.
        let rangeAdjustedSlope = p.contrast * (c.rangeInEV / 16.5)
        let compensationFactor = Self.slopeGammaCompensation(gamma: c.curveGamma, pivotY: c.pivotY, targetBlackRatio: p.targetBlackRatio, targetWhiteRatio: p.targetWhiteRatio)
        c.slope = rangeAdjustedSlope / compensationFactor

        // Toe — `curve_linear_ratio_below_pivot` fixed at 0, so the toe transition sits exactly at the pivot.
        c.targetBlack = pow(p.targetBlackRatio, 1.0 / c.curveGamma)
        c.toePower = max(0.01, p.toePower)
        c.toeTransitionX = max(agxEpsilon, c.pivotX)
        c.toeTransitionY = c.pivotY

        let inverseToeLimitX = 1.0
        let inverseToeLimitY = 1.0 - c.targetBlack
        let inverseToeTransitionX = 1.0 - c.toeTransitionX
        let inverseToeTransitionY = 1.0 - c.toeTransitionY
        c.toeScale = -Self.scale(limitX: inverseToeLimitX, limitY: inverseToeLimitY, transitionX: inverseToeTransitionX, transitionY: inverseToeTransitionY, slope: c.slope, power: c.toePower)

        let toeLengthX = c.toeTransitionX
        let toeDyTransitionToLimit = max(agxEpsilon, c.toeTransitionY - c.targetBlack)
        let toeSlopeTransitionToLimit = toeDyTransitionToLimit / toeLengthX
        c.needConvexToe = toeSlopeTransitionToLimit > c.slope

        c.toeFallbackPower = Self.slopeMatchingPower(slope: c.slope, dxTransitionToLimit: toeLengthX, dyTransitionToLimit: toeDyTransitionToLimit)
        c.toeFallbackCoefficient = Self.fallbackCurveCoefficient(dxTransitionToLimit: toeLengthX, dyTransitionToLimit: toeDyTransitionToLimit, exponent: c.toeFallbackPower)

        c.intercept = c.toeTransitionY - c.slope * c.toeTransitionX

        // Shoulder — `curve_linear_ratio_above_pivot` fixed at 0, so the shoulder transition sits exactly at the pivot.
        c.targetWhite = pow(p.targetWhiteRatio, 1.0 / c.curveGamma)
        c.shoulderTransitionX = min(1.0 - agxEpsilon, c.pivotX)
        c.shoulderTransitionY = c.pivotY
        c.shoulderPower = max(0.01, p.shoulderPower)

        let shoulderLimitX = 1.0
        c.shoulderScale = Self.scale(limitX: shoulderLimitX, limitY: c.targetWhite, transitionX: c.shoulderTransitionX, transitionY: c.shoulderTransitionY, slope: c.slope, power: c.shoulderPower)

        let shoulderLengthX = 1.0 - c.shoulderTransitionX
        let shoulderDyTransitionToLimit = max(agxEpsilon, c.targetWhite - c.shoulderTransitionY)
        let shoulderSlopeTransitionToLimit = shoulderDyTransitionToLimit / shoulderLengthX
        c.needConcaveShoulder = shoulderSlopeTransitionToLimit > c.slope

        c.shoulderFallbackPower = Self.slopeMatchingPower(slope: c.slope, dxTransitionToLimit: shoulderLengthX, dyTransitionToLimit: shoulderDyTransitionToLimit)
        c.shoulderFallbackCoefficient = Self.fallbackCurveCoefficient(dxTransitionToLimit: shoulderLengthX, dyTransitionToLimit: shoulderDyTransitionToLimit, exponent: c.shoulderFallbackPower)

        return c
    }

    // MARK: - Reference evaluation (Swift-only; the live path re-implements this in CIKL, see `AgXKernel`)

    private static func sigmoid(_ x: Double, power: Double) -> Double {
        x / pow(1.0 + pow(x, power), 1.0 / power)
    }

    private static func scaledSigmoid(_ x: Double, scale: Double, slope: Double, power: Double, transitionX: Double, transitionY: Double) -> Double {
        scale * sigmoid(slope * (x - transitionX) / scale, power: power) + transitionY
    }

    private static func fallbackToe(_ x: Double, _ c: AgXCurveCoefficients) -> Double {
        x < 0 ? c.targetBlack : c.targetBlack + max(0, c.toeFallbackCoefficient * pow(x, c.toeFallbackPower))
    }

    private static func fallbackShoulder(_ x: Double, _ c: AgXCurveCoefficients) -> Double {
        x >= 1 ? c.targetWhite : c.targetWhite - max(0, c.shoulderFallbackCoefficient * pow(1.0 - x, c.shoulderFallbackPower))
    }

    /// Port of `_apply_curve`. Swift reference implementation only, used by tests — the live
    /// render path re-implements this formula in CIKL (see `AgXKernel`).
    static func evaluate(_ x: Double, _ c: AgXCurveCoefficients) -> Double {
        let result: Double
        if x < c.toeTransitionX {
            result = c.needConvexToe ? fallbackToe(x, c) : scaledSigmoid(x, scale: c.toeScale, slope: c.slope, power: c.toePower, transitionX: c.toeTransitionX, transitionY: c.toeTransitionY)
        } else if x <= c.shoulderTransitionX {
            result = c.slope * x + c.intercept
        } else {
            result = c.needConcaveShoulder ? fallbackShoulder(x, c) : scaledSigmoid(x, scale: c.shoulderScale, slope: c.slope, power: c.shoulderPower, transitionX: c.shoulderTransitionX, transitionY: c.shoulderTransitionY)
        }
        return min(max(result, c.targetBlack), c.targetWhite)
    }

    /// Port of `_apply_log_encoding`.
    static func applyLogEncoding(_ x: Double, rangeInEV: Double, blackRelativeEV: Double) -> Double {
        let xRelative = max(agxEpsilon, x / 0.18)
        let mapped = (log2(max(xRelative, 0)) - blackRelativeEV) / rangeInEV
        return min(max(mapped, 0), 1)
    }
}
