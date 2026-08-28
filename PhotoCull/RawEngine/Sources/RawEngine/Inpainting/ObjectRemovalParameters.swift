import Foundation

/// One AI-removed object: a mask marking what was removed, the (square, padded) crop region the
/// inpainting model actually saw, and the model's already-synthesized fill for that region, baked
/// once at edit time. Plain Doubles for the crop rect rather than `CGRect`, and a PNG mask rather
/// than any richer shape type — same conventions `SpotRemoval` already uses, for the same reasons
/// (see its doc comment on `RawEngine`). Unlike `SpotRemoval` (a translate-and-blend of real pixels
/// from elsewhere in the same photo), there's no "source point" here — the fill is synthesized
/// content, so this is a distinct type rather than an overload of `SpotRemoval`'s fields.
public struct ObjectRemoval: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Grayscale PNG (white = removed), normalized to the same full, unrotated, uncropped frame as
    /// `SpotRemoval`'s coordinates.
    public var maskData: Data
    /// The padded, square region actually sent to `InpaintingFilter`, normalized (0...1) to the
    /// same frame as `maskData`.
    public var cropX: Double
    public var cropY: Double
    public var cropWidth: Double
    public var cropHeight: Double
    /// The model's output for `cropX/Y/Width/Height`, PNG-encoded, baked once at whatever
    /// resolution the working preview was at edit time — see `ObjectRemovalKernel`'s doc comment
    /// for why compositing this is cheap even though producing it was not.
    public var previewPatchData: Data

    public init(
        id: UUID = UUID(), maskData: Data, cropX: Double, cropY: Double, cropWidth: Double, cropHeight: Double,
        previewPatchData: Data
    ) {
        self.id = id
        self.maskData = maskData
        self.cropX = cropX
        self.cropY = cropY
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
        self.previewPatchData = previewPatchData
    }
}

/// A list of `ObjectRemoval`s, composited in order — see `ObjectRemovalKernel.apply`.
public struct ObjectRemovalParameters: Equatable, Sendable {
    public var removals: [ObjectRemoval]

    public init(removals: [ObjectRemoval] = []) {
        self.removals = removals
    }

    public var isEmpty: Bool { removals.isEmpty }
}
