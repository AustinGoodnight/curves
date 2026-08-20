import Foundation
import SwiftData

@Model
public final class PhotoStack {
    public var id: UUID = UUID()
    public var name: String?
    public var createdDate: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \PhotoAsset.stack)
    public var photos: [PhotoAsset]? = []

    /// The shared `.single` + `.custom` stages every photo in this stack edits through — created
    /// alongside the stack (a blank `.single` stage; `.custom` ones are added on demand, same as
    /// `PhotoAsset.stages`). `PhotoAsset.singleStage`/`.customStages` route here instead of to the
    /// asset's own `stages` whenever `asset.stack` is set — see that property's doc comment. This
    /// is deliberately *not* one extra shared layer alongside each photo's own (that was tried and
    /// rejected): multiple exposures of one moment are supposed to match exactly, so stacking makes
    /// every member share its *entire* edit stack, not just part of it. A photo's own pre-stacking
    /// stages are never deleted, only bypassed — unstacking (`asset.stack = nil`) makes
    /// `PhotoAsset.singleStage`/`.customStages` fall back to them again, unchanged.
    @Relationship(deleteRule: .cascade, inverse: \Stage.stack)
    public var stages: [Stage]? = []

    public var singleStage: Stage? {
        stages?.first(where: { $0.kind == .single })
    }

    public var customStages: [Stage] {
        (stages ?? []).filter { $0.kind == .custom }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public init(name: String? = nil) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.photos = []
        self.stages = [Stage(kind: .single, name: "Single", stack: self)]
    }
}
