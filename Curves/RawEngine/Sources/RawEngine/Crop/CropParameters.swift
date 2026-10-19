import CoreGraphics
import Foundation

/// Straighten angle plus a crop rectangle — everything `CropTransform` needs to turn a rendered
/// image into its final, user-framed output. Lives on `RawBaseParameters`, not `StageParameters`,
/// same "applied once, not stackable" reasoning as `LensCorrectionParameters` (see its doc comment):
/// there's exactly one final framing per photo, not a per-region creative choice. Unlike lens
/// correction (applied right after RAW decode, before any grading, since it depends on the shot's
/// physical optics), this is applied dead last in `RawImageRenderer` — crop/straighten only decides
/// *which pixels of the already-graded image survive*, so it doesn't matter to any earlier module,
/// and cropping last means every earlier kernel pass runs at full pre-crop resolution rather than
/// needing to reason about a moving output boundary.
public struct CropParameters: Equatable, Sendable {
    /// Degrees, positive = clockwise. Small straighten angles in practice (a handful of degrees),
    /// but not clamped here — `CropEditorOverlay` in the app target is what constrains the UI's own
    /// slider range.
    public var angleDegrees: Double
    /// Normalized (0...1 on both axes) crop rectangle, in the frame of the image *after* rotating by
    /// `angleDegrees` around its own center — i.e. exactly the rectangle a user drags directly on
    /// top of the live-rotated preview, not something expressed in the original unrotated image's
    /// coordinates. `(0,0,1,1)` (the default) is "no crop": the whole rotated frame.
    public var rect: CGRect

    public init(angleDegrees: Double = 0, rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        self.angleDegrees = angleDegrees
        self.rect = rect
    }

    /// True when this is a complete no-op (no rotation, full-frame rect) — `CropTransform.apply`
    /// skips the whole transform/crop pass entirely rather than doing a same-result no-op crop.
    public var isIdentity: Bool {
        angleDegrees == 0 && rect == CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}
