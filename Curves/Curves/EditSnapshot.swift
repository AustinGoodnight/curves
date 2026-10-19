import Foundation
import PhotoCatalog

/// A point-in-time copy of every field `EditHistory` treats as undoable: the asset's own base
/// params plus each currently active stage's full module state (`StageFieldSnapshot`). Used only
/// for in-memory undo/redo diffing — see `AssetVersionSnapshot` for the persisted, Single-stage-
/// only counterpart used by "Versions".
struct EditSnapshot: Equatable {
    var assetExposure: Double?
    var assetNeutralTemperature: Double?
    var assetNeutralTint: Double?
    var assetSharpnessAmount: Double?
    /// JSON-encoded `[SpotRemoval]`/`[ObjectRemoval]` (see `RawEngine`) — captured as opaque `Data`
    /// blobs, same as every other field here; `EditSnapshot` only needs `Equatable`, never needs to
    /// decode them itself. Added so `SpotRemovalEditorOverlay`/`RemoveObjectEditorOverlay`/
    /// `PaintedFillEditorOverlay`'s edits participate in Cmd+Z — their `onFinished` closures already
    /// call `scheduleRender(...,history:)` like every other edit, so capturing these two fields is
    /// the only change needed; nothing in `EditHistory` itself or the three overlays had to change.
    var assetSpotRemovalData: Data?
    var assetObjectRemovalData: Data?
    var stages: [StageEntry]

    /// Holds the live `Stage` reference alongside its captured fields so `apply(to:)` can write
    /// straight back to it — `Equatable` compares only `stageID`/`fields`, not `stage` itself
    /// (`Stage` isn't necessarily `Equatable`, and identity isn't what "did anything change"
    /// needs anyway).
    struct StageEntry: Equatable {
        let stageID: UUID
        let stage: Stage
        var fields: StageFieldSnapshot

        static func == (lhs: StageEntry, rhs: StageEntry) -> Bool {
            lhs.stageID == rhs.stageID && lhs.fields == rhs.fields
        }
    }

    init(asset: PhotoAsset, activeStages: [Stage]) {
        assetExposure = asset.editExposure
        assetNeutralTemperature = asset.editNeutralTemperature
        assetNeutralTint = asset.editNeutralTint
        assetSharpnessAmount = asset.editSharpnessAmount
        assetSpotRemovalData = asset.spotRemovalData
        assetObjectRemovalData = asset.objectRemovalData
        stages = activeStages.map { StageEntry(stageID: $0.id, stage: $0, fields: StageFieldSnapshot(capturing: $0)) }
    }

    var stageIDs: Set<UUID> { Set(stages.map(\.stageID)) }

    func apply(to asset: PhotoAsset) {
        asset.editExposure = assetExposure
        asset.editNeutralTemperature = assetNeutralTemperature
        asset.editNeutralTint = assetNeutralTint
        asset.editSharpnessAmount = assetSharpnessAmount
        asset.spotRemovalData = assetSpotRemovalData
        asset.objectRemovalData = assetObjectRemovalData
        for entry in stages {
            entry.fields.apply(to: entry.stage)
        }
    }

    /// A short, best-effort description of what changed between two snapshots, for
    /// `EditHistoryListView`'s rows — cosmetic only. Falls back to "Multiple Edits" once more than
    /// one module changed at once (a mask paint plus a slider in the same debounced burst, a
    /// "Reset All", a version restore) rather than trying to list every one.
    static func changeLabel(from before: EditSnapshot, to after: EditSnapshot) -> String {
        var changed: Set<String> = []
        if before.assetExposure != after.assetExposure { changed.insert("Exposure") }
        if before.assetNeutralTemperature != after.assetNeutralTemperature || before.assetNeutralTint != after.assetNeutralTint {
            changed.insert("White Balance")
        }
        if before.assetSharpnessAmount != after.assetSharpnessAmount { changed.insert("Sharpness") }
        if before.assetSpotRemovalData != after.assetSpotRemovalData { changed.insert("Spot Removal") }
        if before.assetObjectRemovalData != after.assetObjectRemovalData { changed.insert("Remove Object") }
        for beforeEntry in before.stages {
            guard let afterEntry = after.stages.first(where: { $0.stageID == beforeEntry.stageID }) else { continue }
            changed.formUnion(afterEntry.fields.changedModules(from: beforeEntry.fields))
        }
        if changed.isEmpty { return "Edit" }
        if changed.count == 1 { return changed.first! }
        return "Multiple Edits"
    }
}
