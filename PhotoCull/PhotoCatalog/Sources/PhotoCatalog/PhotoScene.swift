import Foundation
import SwiftData

/// A user-assigned group of photos within a `Session` that should be edited together (e.g.
/// "Reception", "First Dance"). Unlike a `PhotoStack` (multiple exposures of one moment) a scene
/// can hold any number of photos, but unlike the app's earlier many-to-many tagging, each photo
/// belongs to at most one scene — that singularity is what lets a scene's shared "Scene" edit
/// stage apply unambiguously to every photo in it.
@Model
public final class PhotoScene {
    public var id: UUID = UUID()
    public var name: String = ""
    public var createdDate: Date = Date()

    public var session: Session?

    @Relationship(deleteRule: .nullify, inverse: \PhotoAsset.scene)
    public var photos: [PhotoAsset]? = []

    /// The shared stage every photo in this scene composites in — created alongside the scene
    /// and never deleted or renamed. Always non-nil after `init`; stays `Stage?` (rather than a
    /// non-optional wrapper) to match `PhotoAsset.stack`'s style of optional-but-effectively-
    /// always-present relationship.
    @Relationship(deleteRule: .cascade, inverse: \Stage.scene)
    public var stage: Stage?

    public init(name: String, session: Session? = nil) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.session = session
        self.photos = []
        self.stage = Stage(kind: .scene, name: "Scene", scene: self)
    }
}
