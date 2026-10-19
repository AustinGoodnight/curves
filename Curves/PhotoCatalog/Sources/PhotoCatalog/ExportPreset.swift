import Foundation
import SwiftData

/// The on-disk image format an export preset writes — mirrors `RawEngine.ExportFormat`'s cases,
/// but that type also carries a JPEG quality payload and isn't `Codable`/persistable on its own,
/// so this is the flat, storable equivalent `ExportPreset.formatRaw` actually round-trips.
public enum ExportImageFormat: Int, Codable, CaseIterable, Hashable, Sendable {
    case jpeg = 0
    case tiff = 1
    case png = 2
}

/// A named, reusable export configuration — format, JPEG quality, and an optional resize cap —
/// listed alongside the app's built-in presets ("Lossless", "90% JPG", "80% JPG", "Instagram") in
/// the culling grid's export bar. Unlike `Preset` (a saved *edit* — a stage's worth of slider
/// values), this never touches a photo's grading; it only controls how the already-graded render
/// gets rasterized to disk.
@Model
public final class ExportPreset {
    public var id: UUID = UUID()
    public var name: String = ""
    public var formatRaw: Int = ExportImageFormat.jpeg.rawValue
    /// Only meaningful when `format == .jpeg` — ignored for TIFF/PNG, both lossless.
    public var quality: Double = 0.9
    /// `nil` means export at full native resolution; otherwise the longer side is downscaled to
    /// fit this many pixels — see `RawImageRenderer.renderFullResolution(maxLongEdge:)`.
    public var maxLongEdge: Double?
    public var sortIndex: Int = 0
    public var createdDate: Date = Date()

    public var format: ExportImageFormat {
        get { ExportImageFormat(rawValue: formatRaw) ?? .jpeg }
        set { formatRaw = newValue.rawValue }
    }

    public init(name: String, format: ExportImageFormat, quality: Double = 0.9, maxLongEdge: Double? = nil, sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.formatRaw = format.rawValue
        self.quality = quality
        self.maxLongEdge = maxLongEdge
        self.sortIndex = sortIndex
        self.createdDate = Date()
    }
}
