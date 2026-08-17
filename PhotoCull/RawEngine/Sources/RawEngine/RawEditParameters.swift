import Foundation

/// Edit parameters passed to `CIRAWFilter`'s native inputs. Every field is optional — `nil`
/// means "use the filter's as-shot/vendor default for this image", not zero.
public struct RawEditParameters: Equatable, Sendable {
    public var exposure: Double?
    public var boostAmount: Double?
    public var neutralTemperature: Double?
    public var neutralTint: Double?
    public var sharpnessAmount: Double?

    public init(
        exposure: Double? = nil,
        boostAmount: Double? = nil,
        neutralTemperature: Double? = nil,
        neutralTint: Double? = nil,
        sharpnessAmount: Double? = nil
    ) {
        self.exposure = exposure
        self.boostAmount = boostAmount
        self.neutralTemperature = neutralTemperature
        self.neutralTint = neutralTint
        self.sharpnessAmount = sharpnessAmount
    }

    public static let none = RawEditParameters()
}
