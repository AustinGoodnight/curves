import Foundation

/// One healed/cloned spot: a circular `target` area repaired by sampling a same-size circular
/// patch from `source` and blending it in through a soft-edged mask — see `SpotRemovalKernel`.
/// All coordinates are normalized (0...1, top-left origin) fractions of the full, unrotated,
/// uncropped image frame — the same frame `SpotRemovalEditorOverlay` renders its "uncropped, no
/// spots yet" working preview in, and the frame `SpotRemovalKernel.apply` reads directly rather
/// than one that depends on wherever the crop rectangle happens to be at edit time (unlike a
/// `Stage`'s `maskData`, which is baked as a PNG at whatever size the preview was when drawn — see
/// `RawImageRenderer.applyMask`'s doc comment — plain normalized fields here have no such
/// resolution/aspect coupling to get wrong later).
///
/// Plain Doubles rather than `CGPoint`, matching every other geometry field on `RawBaseParameters`
/// (e.g. `CropParameters`' rect components) instead of introducing a different convention just for
/// this module.
public struct SpotRemoval: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var targetX: Double
    public var targetY: Double
    public var sourceX: Double
    public var sourceY: Double
    /// Normalized radius, as a fraction of the image's width (matching `GradientMaskEditorOverlay
    /// .radius`'s own convention for a circular region).
    public var radius: Double

    public init(id: UUID = UUID(), targetX: Double, targetY: Double, sourceX: Double, sourceY: Double, radius: Double) {
        self.id = id
        self.targetX = targetX
        self.targetY = targetY
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.radius = radius
    }
}

/// A list of `SpotRemoval` patches, composited in order (see `SpotRemovalKernel.apply`). Lives on
/// `RawBaseParameters`, not `StageParameters` — like `CropParameters`, this is one asset-wide
/// repair pass, not a per-stage creative grade (see `RawBaseParameters.spotRemoval`'s doc comment
/// for exactly where it sits in the render order).
public struct SpotRemovalParameters: Equatable, Sendable {
    public var spots: [SpotRemoval]

    public init(spots: [SpotRemoval] = []) {
        self.spots = spots
    }

    public var isEmpty: Bool { spots.isEmpty }
}
