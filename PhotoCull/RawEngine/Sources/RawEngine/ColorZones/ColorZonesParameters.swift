import Foundation

/// Parameters for the color zones module, ported from darktable's `colorzones` module
/// (`src/iop/colorzones.c`, tag `release-5.6.0`) — an EQ-style tool: three curves (lightness,
/// chroma, hue), each a function of the pixel's own hue, so you can push "just the greens
/// brighter" or "just the reds more saturated" without touching anything else.
///
/// Scope note: darktable's module has a "select by" axis (`channel`: hue / saturation /
/// lightness) that determines which of the pixel's own properties indexes into the 3 curves —
/// this port fixes it to `.hue` (darktable's own default, and the only axis this feature was
/// asked for: "hue vs hue, hue vs sat, hue vs luminance" are all the same "select by hue" mode,
/// just looking at a different one of the 3 output curves). "Select by saturation/lightness"
/// is not implemented. Also out of scope: the `strength` mix slider and the "strong" process
/// mode (`process_v1`) — this ports only `process_v3`, darktable's own default
/// (`DT_IOP_COLORZONES_MODE_SMOOTH`).
///
/// Also consistent with `FilmicRGBParameters`/`ColorBalanceRGBParameters`: this assumes incoming
/// RGB is already linear sRGB/Rec709 at D65, and does its own RGB->Lab conversion directly at
/// D65 (see `ColorZonesMath`) rather than porting darktable's D50 ICC-profile round trip.
public struct ColorZonesParameters: Equatable, Sendable {
    /// Lightness curve: `f(hue) -> lightness multiplier exponent`, y = 0.5 is a no-op.
    public var lightnessPoints: [SIMD2<Double>]
    /// Chroma curve: `f(hue) -> chroma scale`, y = 0.5 is a no-op (output scale = 2 * y).
    public var chromaPoints: [SIMD2<Double>]
    /// Hue curve: `f(hue) -> hue shift`, y = 0.5 is a no-op.
    public var huePoints: [SIMD2<Double>]

    public init(
        lightnessPoints: [SIMD2<Double>] = ColorZonesParameters.identityPoints,
        chromaPoints: [SIMD2<Double>] = ColorZonesParameters.identityPoints,
        huePoints: [SIMD2<Double>] = ColorZonesParameters.identityPoints
    ) {
        self.lightnessPoints = lightnessPoints
        self.chromaPoints = chromaPoints
        self.huePoints = huePoints
    }

    /// darktable's real default (`_reset_nodes`): 2 nodes at x = 0.25 / 0.75 (not touching the
    /// domain edges — only the `.hue` "select by" axis skips edge-touching, and `.hue` is this
    /// port's only axis), y = 0.5 (no-op) at both. Every curve defaults to this.
    public static let identityPoints: [SIMD2<Double>] = [SIMD2(0.25, 0.5), SIMD2(0.75, 0.5)]

    public static let darktableDefault = ColorZonesParameters()
}
