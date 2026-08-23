import Foundation

/// Render-time parameters for the 3D LUT ("film simulation") module: which parsed cube to apply
/// and how strongly. `nil` at the `StageParameters.lut3D` level means "no LUT loaded" — same
/// convention as every other stackable module (see `StageParameters`'s doc comment).
public struct LUT3DParameters: Equatable, Sendable {
    public var lut: LUT3D
    /// Blend between the untouched input (`0`) and the full LUT result (`1`) — lets a film
    /// simulation be dialed back rather than applied all-or-nothing, matching how most creative
    /// LUT tools (VSCO, RNI, etc.) expose LUT strength.
    public var intensity: Double

    public init(lut: LUT3D, intensity: Double = 1) {
        self.lut = lut
        self.intensity = intensity
    }
}
