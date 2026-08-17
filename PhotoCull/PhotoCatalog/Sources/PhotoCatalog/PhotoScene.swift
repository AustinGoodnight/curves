import Foundation
import SwiftData

/// A user-assigned collection of photos (e.g. "Reception", "First Dance"). Unlike a
/// `PhotoStack` (multiple exposures of one moment, one stack per photo), a photo can
/// belong to any number of scenes.
@Model
public final class PhotoScene {
    public var id: UUID = UUID()
    public var name: String = ""
    public var createdDate: Date = Date()

    public var photos: [PhotoAsset]? = []

    public init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.photos = []
    }
}
