import Foundation
import SwiftData

@Model
public final class PhotoStack {
    public var id: UUID = UUID()
    public var name: String?
    public var createdDate: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \PhotoAsset.stack)
    public var photos: [PhotoAsset]? = []

    public init(name: String? = nil) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.photos = []
    }
}
