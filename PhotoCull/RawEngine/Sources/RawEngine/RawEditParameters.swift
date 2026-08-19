import Foundation

/// Edit parameters passed to `CIRAWFilter`'s native inputs. Every field is optional — `nil`
/// means "use the filter's as-shot/vendor default for this image", not zero.
public struct RawEditParameters: Equatable, Sendable {
    public var exposure: Double?
    public var boostAmount: Double?
    public var neutralTemperature: Double?
    public var neutralTint: Double?
    public var sharpnessAmount: Double?
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
    /// `nil` means "no RGB curve". Applied last — the final tonal shaping pass, matching where a
    /// Lightroom-style tone curve sits in most editors (see `RGBCurveParameters`).
    public var rgbCurve: RGBCurveParameters?

    public init(
        exposure: Double? = nil,
        boostAmount: Double? = nil,
        neutralTemperature: Double? = nil,
        neutralTint: Double? = nil,
        sharpnessAmount: Double? = nil,
        filmicRGB: FilmicRGBParameters? = nil,
        colorBalanceRGB: ColorBalanceRGBParameters? = nil,
        colorZones: ColorZonesParameters? = nil,
        rgbCurve: RGBCurveParameters? = nil
    ) {
        self.exposure = exposure
        self.boostAmount = boostAmount
        self.neutralTemperature = neutralTemperature
        self.neutralTint = neutralTint
        self.sharpnessAmount = sharpnessAmount
        self.filmicRGB = filmicRGB
        self.colorBalanceRGB = colorBalanceRGB
        self.colorZones = colorZones
        self.rgbCurve = rgbCurve
    }

    public static let none = RawEditParameters()
}
