import Foundation

/// What a color wheel position actually does to a neutral grey, for drawing the wheel itself.
///
/// A wheel's hue is *not* an HSB hue: `ColorBalanceRGBProcessor.compute` offsets it by 30° and
/// applies it in darktable's Yrg space, whose hues are unevenly spaced relative to display hues
/// (wheel 90° ≈ display yellow at 60°, wheel 120° ≈ display 110°, wheel 240° ≈ display 212°, …).
/// A wheel painted with a plain `Color(hue:)` spectrum therefore shows a different color under the
/// puck than the tint the render applies. This runs the same `wheelRGB` math the processor does
/// and converts the result to display RGB, so a wheel UI can paint what the engine really does.
public enum ColorBalanceWheelTint {
    /// Linear sRGB (D65) of a neutral grey tinted by the wheel at `hueDegrees`, normalized so the
    /// untinted white reference maps to (1, 1, 1). Only the *direction* away from (1, 1, 1) is
    /// meaningful — `chroma` just needs to be large enough to give a stable hue (the default is).
    public static func linearRGB(hueDegrees: Double, chroma: Double = 0.1) -> SIMD3<Double> {
        let hue = (hueDegrees - 30.0) * .pi / 180.0 // same CONVENTIONAL_DEG_TO_YRG_RAD as the processor
        let tinted = displayRGB(ColorBalanceMath.ychToGradingRGB(ColorBalanceMath.makeYch(Y: 1, c: chroma, h: hue)))
        let white = displayRGB(ColorBalanceMath.ychToGradingRGB(Ych(Y: 1, c: 0, cosH: 1, sinH: 0)))
        return tinted / white
    }

    private static func displayRGB(_ grading: Triplet) -> SIMD3<Double> {
        let rgb = ColorBalanceMath.xyzToRGB(ColorBalanceMath.lmsToXYZ(ColorBalanceMath.gradingRGBToLMS(grading)))
        return SIMD3(rgb.x, rgb.y, rgb.z)
    }
}
