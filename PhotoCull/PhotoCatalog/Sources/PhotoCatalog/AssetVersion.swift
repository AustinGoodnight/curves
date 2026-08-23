import Foundation
import SwiftData

/// A named, user-created checkpoint of a photo's edit state — "basic version control": save one
/// deliberately, come back to it later. Distinct from `EditHistory` (in the app target), which
/// covers automatic per-edit Cmd+Z/Cmd+Shift+Z undo/redo instead — this is the manual, named,
/// persisted counterpart, shown in `StagesSidebarView`'s "Versions" section as a small branching
/// graph (`VersionTreeView` in the app target).
///
/// `parent` is which version was checked out (`PhotoAsset.currentVersionID`) when this one was
/// saved — `nil` only for the very first version ever saved on an asset. That single parent
/// pointer is the whole "git-like" model: a linear run of same-`branchName` versions is a branch,
/// and a version whose `branchName` differs from its `parent`'s is a fork point, exactly like
/// `git branch <name>` followed by a commit — no separate "branch" object exists, `branchName` is
/// just a label carried by whichever versions were saved while that name was current (see
/// `StagesSidebarView.createBranch()`).
///
/// `snapshotData` is an opaque encoded blob from `PhotoCatalog`'s perspective, same convention as
/// `Stage.maskData`/`lut3DData` — see `AssetVersionSnapshot` in the app target for its shape and
/// scope (the asset's base params + its Single stage; Scene/Custom stages aren't captured).
@Model
public final class AssetVersion {
    public var id: UUID = UUID()
    public var name: String = ""
    public var branchName: String = "main"
    public var createdDate: Date = Date()
    public var asset: PhotoAsset?
    public var parent: AssetVersion?
    /// The inverse of `parent` — every other version whose `parent` is this one. `.nullify` (not
    /// `.cascade`): deleting a version in the middle of a branch promotes its children to roots
    /// rather than wiping the rest of the branch's history with it.
    @Relationship(deleteRule: .nullify, inverse: \AssetVersion.parent)
    public var children: [AssetVersion]? = []
    public var snapshotData: Data = Data()

    public init(name: String, branchName: String = "main", asset: PhotoAsset, parent: AssetVersion? = nil, snapshotData: Data) {
        self.id = UUID()
        self.name = name
        self.branchName = branchName
        self.createdDate = Date()
        self.asset = asset
        self.parent = parent
        self.snapshotData = snapshotData
    }
}
