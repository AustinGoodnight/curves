import Foundation

/// Parameters for the RGB curve module, ported from darktable's `rgbcurve` module
/// (`src/iop/rgbcurve.c`, tag `release-5.6.0`) — a Lightroom/Photoshop-style tone curve editor.
///
/// Scope note: darktable's module supports two "autoscale" modes (a single master curve applied
/// to all channels — `DT_S_SCALE_AUTOMATIC_RGB`, the default — or three independent R/G/B
/// curves — `DT_S_SCALE_MANUAL_RGB`), three spline types (cubic spline, Catmull-Rom, monotone
/// Hermite — default), and six chrominance-preservation norms. This port covers only the
/// default combination: a single master curve, monotone Hermite spline, applied either directly
/// per-channel (`preserveColors == false`) or as a luminance-preserving ratio
/// (`preserveColors == true`, darktable's default `DT_RGB_NORM_LUMINANCE`) — the two options a
/// user actually needs day to day. Independent R/G/B curves and the other four norms
/// (max/average/sum/norm/power) are not implemented.
public struct RGBCurveParameters: Equatable, Sendable {
    /// Control points, unsorted order allowed; must have at least 2 points to be meaningful
    /// (fewer degrades to a no-op — see `RGBCurveKernel`). X and Y are both in [0, 1].
    public var points: [SIMD2<Double>]
    /// darktable's `DT_RGB_NORM_LUMINANCE`-vs-`DT_RGB_NORM_NONE` toggle: apply the curve to a
    /// camera-RGB luminance value and rescale all 3 channels by the resulting ratio (preserves
    /// hue/chroma), vs. applying the curve to each channel independently (can shift color, but
    /// is more predictable for deliberate channel-level grading).
    public var preserveColors: Bool
    /// Uniform lift applied after the curve (`out = in × (1 − blackLift) + blackLift`) — not part
    /// of darktable's `rgbcurve` module, added so the UI can offer a small precise black-point
    /// nudge separate from dragging the curve graph's own endpoint. 0 is a no-op.
    public var blackLift: Double

    public init(points: [SIMD2<Double>] = RGBCurveParameters.identityPoints, preserveColors: Bool = true, blackLift: Double = 0) {
        self.points = points
        self.preserveColors = preserveColors
        self.blackLift = blackLift
    }

    /// The 2-node identity line: `f(x) = x`, matching darktable's default (`curve_num_nodes = 2`
    /// at `(0,0)` and `(1,1)`).
    public static let identityPoints: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 1)]

    public static let darktableDefault = RGBCurveParameters()
}
