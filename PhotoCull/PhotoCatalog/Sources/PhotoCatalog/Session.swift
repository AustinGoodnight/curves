import Foundation
import SwiftData

/// A day/shoot's worth of imported photos — the top-level grouping a photo belongs to. Picked or
/// created by the user at import time (see `LibraryImporter.importFiles(_:into:session:)`).
/// Unlike `PhotoScene` (which nests inside a session and groups photos that should be edited
/// together), a photo belongs to exactly one session for its whole life — re-importing the same
/// file into a different session creates a new, separate `PhotoAsset`.
@Model
public final class Session {
    public var id: UUID = UUID()
    public var name: String = ""
    public var createdDate: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \PhotoAsset.session)
    public var photos: [PhotoAsset]? = []

    public init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.photos = []
    }
}
