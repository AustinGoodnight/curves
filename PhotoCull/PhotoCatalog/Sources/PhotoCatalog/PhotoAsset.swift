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

    @Relationship(deleteRule: .nullify, inverse: \PhotoScene.photos)
    public var scenes: [PhotoScene]? = []

    /// Edit parameters for `RawEngine`'s `CIRAWFilter` pipeline. `nil` means "use this image's
    /// as-shot/vendor default" — not zero — so an unedited photo renders exactly as the camera
    /// intended until the user actually touches a slider.
    public var editExposure: Double?
    public var editBoostAmount: Double?
    public var editNeutralTemperature: Double?
    public var editNeutralTint: Double?
    public var editSharpnessAmount: Double?

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
        self.importDate = importDate
        self.captureDate = captureDate
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.ratingRaw = 0
        self.flagRaw = FlagState.none.rawValue
        self.colorLabelRaw = ColorLabel.none.rawValue
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
