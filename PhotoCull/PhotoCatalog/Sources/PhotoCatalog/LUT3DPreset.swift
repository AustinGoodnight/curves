import Foundation
import SwiftData

/// A named 3D LUT ("film simulation") in the user's reusable library — parsed once via
/// `LUT3DLoader` and imported through a file picker, then selectable from an in-app list for any
/// stage afterward (see `LUT3DPresetMenu` in the app target) instead of reopening Finder every
/// time. Independent of any particular `Stage`: `Stage`'s own `lut3DData`/`lut3DSize`/
/// `lut3DTitle` fields hold a denormalized copy of whichever preset (if any) is currently
/// applied, copied in at selection time rather than modeled as a SwiftData relationship — so
/// renaming or deleting a preset from the library later doesn't retroactively change what a stage
/// that already picked it renders.
@Model
public final class LUT3DPreset {
    public var id: UUID = UUID()
    public var name: String = ""
    /// The cube's edge length — matches `LUT3D.size`.
    public var size: Int = 0
    /// Raw RGBA float32 bytes, red-fastest order — matches `LUT3D.data`'s layout exactly, so this
    /// can be handed straight to `LUT3D.init` with no reparsing.
    public var data: Data = Data()
    public var createdDate: Date = Date()

    public init(name: String, size: Int, data: Data) {
        self.id = UUID()
        self.name = name
        self.size = size
        self.data = data
        self.createdDate = Date()
    }
}
