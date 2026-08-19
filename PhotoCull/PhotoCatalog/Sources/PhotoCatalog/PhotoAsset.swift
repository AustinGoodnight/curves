import Foundation
import SwiftData

@Model
public final class PhotoAsset {
    public var id: UUID = UUID()
    public var filePath: String = ""
    public var bookmarkData: Data?
    public var fileName: String = ""
    public var fileExtension: String = ""
    public var importDate: Date = Date()
    public var captureDate: Date?
    public var fileSize: Int64 = 0
    public var pixelWidth: Int = 0
    public var pixelHeight: Int = 0
    public var ratingRaw: Int = 0
    public var flagRaw: Int = FlagState.none.rawValue
    public var colorLabelRaw: Int = ColorLabel.none.rawValue

    public var stack: PhotoStack?
    public var scene: PhotoScene?
    public var session: Session?

    /// Base edit parameters for `RawEngine`'s `CIRAWFilter` pipeline. `nil` means "use this
    /// image's as-shot/vendor default" — not zero — so an unedited photo renders exactly as the
    /// camera intended until the user actually touches a slider. Unlike the four kernel-module
    /// parameter groups (Filmic RGB, Color Balance RGB, RGB Curve, Color Zones — now on `Stage`),
    /// these stay directly on `PhotoAsset`: `CIRAWFilter` applies them once during RAW decode,
    /// before any stage's kernel passes run, so there's no "per stage" version of these to stack.
    public var editExposure: Double?
    public var editBoostAmount: Double?
    public var editNeutralTemperature: Double?
    public var editNeutralTint: Double?
    public var editSharpnessAmount: Double?

    /// Owns this photo's `.single` stage (always present, index 0) and any `.custom` stages the
    /// user has added. The shared `.scene` stage lives on `PhotoScene` instead — see `Stage`'s
    /// doc comment.
    @Relationship(deleteRule: .cascade, inverse: \Stage.asset)
    public var stages: [Stage]? = []

    /// The always-present, per-photo stage — created alongside this asset in `init` and never
    /// deleted or renamed. The `??` fallback only matters for assets that predate the `Stage`
    /// model and haven't been migrated yet; it deliberately returns a transient, unpersisted
    /// `Stage` rather than crashing.
    public var singleStage: Stage {
        stages?.first(where: { $0.kind == .single }) ?? Stage(kind: .single, name: "Single", asset: self)
    }

    /// User-added stages, in display/composite order.
    public var customStages: [Stage] {
        (stages ?? []).filter { $0.kind == .custom }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public var rating: Int {
        get { ratingRaw }
        set { ratingRaw = max(0, min(5, newValue)) }
    }

    public var flag: FlagState {
        get { FlagState(rawValue: flagRaw) ?? .none }
        set { flagRaw = newValue.rawValue }
    }

    public var colorLabel: ColorLabel {
        get { ColorLabel(rawValue: colorLabelRaw) ?? .none }
        set { colorLabelRaw = newValue.rawValue }
    }

    public init(
        filePath: String,
        bookmarkData: Data? = nil,
        fileName: String,
        fileExtension: String,
        session: Session,
        importDate: Date = Date(),
        captureDate: Date? = nil,
        fileSize: Int64 = 0,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0
    ) {
        self.id = UUID()
        self.filePath = filePath
        self.bookmarkData = bookmarkData
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.session = session
        self.importDate = importDate
        self.captureDate = captureDate
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.ratingRaw = 0
        self.flagRaw = FlagState.none.rawValue
        self.colorLabelRaw = ColorLabel.none.rawValue
        self.stages = [Stage(kind: .single, name: "Single", asset: self)]
    }

    /// Bookmarks survive file moves/renames within the same volume; the raw path is the
    /// fast-path fallback when no bookmark was captured (or it fails to resolve).
    public func resolvedURL() -> URL {
        if let bookmarkData {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return url
            }
        }
        return URL(fileURLWithPath: filePath)
    }
}
