import Foundation

/// Parameters for AI-based noise reduction, run via Intel Open Image Denoise (OIDN) — see
/// `DenoiseFilter`'s doc comment for how it's wired in. Unlike the darktable-derived modules
/// elsewhere in this package (`FilmicRGB`, `ColorZones`, `RGBCurve`), this isn't a port of
/// anyone's GPL source: OIDN's code and pretrained weights are both Apache-2.0 (see
/// `RawEngine/Vendor/OpenImageDenoise-LICENSE.txt`), so it carries none of the licensing
/// caveats those modules do.
public struct DenoiseParameters: Equatable, Sendable {
    /// 0 = no-op (skipped entirely by `RawImageRenderer`, same as `nil` at the
    /// `RawBaseParameters.denoise` level), 1 = the full OIDN output. Values in between blend
    /// linearly between the untouched and denoised images, the same way `LUT3DParameters.intensity`
    /// blends a graded image back toward its input.
    public var amount: Double

    public init(amount: Double = 0) {
        self.amount = amount
    }

    public static let none = DenoiseParameters()
}
