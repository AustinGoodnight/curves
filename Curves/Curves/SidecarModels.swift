import Foundation
import PhotoCatalog
import RawEngine

/// Codable schemas for the three sidecar file kinds this app persists edit state to (`.curve` per
/// photo, `.scene` per `PhotoScene`, `.stack` per `PhotoStack`) — see the
/// `sidecar-persistence` branch's plan for why: SwiftData stays only as a disposable, rebuildable
/// query cache, these files are the actual source of truth. Every type here carries a
/// `schemaVersion` and decodes leniently (`decodeIfPresent` via a custom `init(from:)`, added the
/// first time a V2 of any of these is ever needed) so a sidecar's own shape can evolve without
/// requiring a `SchemaMigrationPlan`-style mechanism one layer down — the exact fragility that
/// caused this whole redesign, this time one level removed from SwiftData's reach entirely.
///
/// This file only covers construction (`init(capturing:)`) and simple field-level restoration
/// (`apply(to:)`, for fields that live directly on an already-existing model object). Recreating
/// relationships from scratch (inserting new `Stage`/`AssetVersion` rows, linking scene/stack
/// membership) needs a `ModelContext` and is deliberately out of scope here — that's
/// `CacheRebuilder`'s job (library rebuild) and `ContentView`'s import-adoption path, not something
/// a pure data model should know how to do.

// MARK: - Per-stage entry (identity + full field set)

/// A `StageFieldSnapshot` (see that type — already `Codable`, reused as-is) plus the identity/
/// ordering fields it doesn't carry, so a sidecar can preserve *which* stage each entry is and
/// where it sits in the stack, not just its values. Field list mirrors `Stage`'s own identity
/// fields (`Stage.swift`).
struct StageFieldEntry: Codable, Sendable {
    var id: UUID
    var kindRaw: Int
    var name: String
    var isEnabled: Bool
    var sortIndex: Int
    var createdDate: Date
    var fields: StageFieldSnapshot

    init(capturing stage: Stage) {
        id = stage.id
        kindRaw = stage.kindRaw
        name = stage.name
        isEnabled = stage.isEnabled
        sortIndex = stage.sortIndex
        createdDate = stage.createdDate
        fields = StageFieldSnapshot(capturing: stage)
    }

    /// Field-level restoration only — assumes `stage` already exists (its relationship to whichever
    /// asset/scene/stack owns it is unaffected). Callers that need to recreate a stage that no
    /// longer exists at all (the rebuild-from-sidecars path) construct a fresh `Stage` first and
    /// apply onto that.
    func apply(to stage: Stage) {
        stage.id = id
        stage.kindRaw = kindRaw
        stage.name = name
        stage.isEnabled = isEnabled
        stage.sortIndex = sortIndex
        stage.createdDate = createdDate
        fields.apply(to: stage)
    }
}

// MARK: - PhotoAsset base fields (native CIRAWFilter inputs, not stackable per-stage)

/// Mirrors the base-param fields `EditorParameters.rawBaseParameters(for:)` reads directly off
/// `PhotoAsset` — see each field's doc comment there and on `PhotoAsset` itself. Deliberately
/// excludes catalog/EXIF metadata (file size, pixel dimensions, camera model, etc.): that's always
/// re-derived from the file itself on import/rebuild, never edit data, so it has no place in a
/// sidecar meant to hold only what the user actually changed.
struct AssetBaseFieldSnapshot: Codable, Sendable {
    var editExposure: Double?
    var editBoostAmount: Double?
    var editNeutralTemperature: Double?
    var editNeutralTint: Double?
    var editSharpnessAmount: Double?
    var editDenoiseAmount: Double?
    var editWhiteBalanceEnabled: Bool
    var editDetailEnabled: Bool
    var editLensCorrectionEnabled: Bool
    var editLensCorrectionIntensity: Double?
    var editCropAngleDegrees: Double?
    var editCropRectX: Double?
    var editCropRectY: Double?
    var editCropRectWidth: Double?
    var editCropRectHeight: Double?
    /// Decoded from `asset.spotRemovalData`/`objectRemovalData` (raw JSON `Data` blobs on the
    /// model) rather than carried as opaque `Data` here — a sidecar is meant to be inspectable, and
    /// nesting an already-JSON-encoded blob as a base64 string defeats that. Empty array (not nil),
    /// matching `spotRemovalParameters(for:)`/`objectRemovalParameters(for:)`'s own "nil-or-empty
    /// means no contribution" convention.
    var spotRemoval: [SpotRemoval]
    var objectRemoval: [ObjectRemoval]

    init(capturing asset: PhotoAsset) {
        editExposure = asset.editExposure
        editBoostAmount = asset.editBoostAmount
        editNeutralTemperature = asset.editNeutralTemperature
        editNeutralTint = asset.editNeutralTint
        editSharpnessAmount = asset.editSharpnessAmount
        editDenoiseAmount = asset.editDenoiseAmount
        editWhiteBalanceEnabled = asset.editWhiteBalanceEnabled
        editDetailEnabled = asset.editDetailEnabled
        editLensCorrectionEnabled = asset.editLensCorrectionEnabled
        editLensCorrectionIntensity = asset.editLensCorrectionIntensity
        editCropAngleDegrees = asset.editCropAngleDegrees
        editCropRectX = asset.editCropRectX
        editCropRectY = asset.editCropRectY
        editCropRectWidth = asset.editCropRectWidth
        editCropRectHeight = asset.editCropRectHeight
        spotRemoval = asset.spotRemovalData.flatMap { try? JSONDecoder().decode([SpotRemoval].self, from: $0) } ?? []
        objectRemoval = asset.objectRemovalData.flatMap { try? JSONDecoder().decode([ObjectRemoval].self, from: $0) } ?? []
    }

    func apply(to asset: PhotoAsset) {
        asset.editExposure = editExposure
        asset.editBoostAmount = editBoostAmount
        asset.editNeutralTemperature = editNeutralTemperature
        asset.editNeutralTint = editNeutralTint
        asset.editSharpnessAmount = editSharpnessAmount
        asset.editDenoiseAmount = editDenoiseAmount
        asset.editWhiteBalanceEnabled = editWhiteBalanceEnabled
        asset.editDetailEnabled = editDetailEnabled
        asset.editLensCorrectionEnabled = editLensCorrectionEnabled
        asset.editLensCorrectionIntensity = editLensCorrectionIntensity
        asset.editCropAngleDegrees = editCropAngleDegrees
        asset.editCropRectX = editCropRectX
        asset.editCropRectY = editCropRectY
        asset.editCropRectWidth = editCropRectWidth
        asset.editCropRectHeight = editCropRectHeight
        asset.spotRemovalData = spotRemoval.isEmpty ? nil : try? JSONEncoder().encode(spotRemoval)
        asset.objectRemovalData = objectRemoval.isEmpty ? nil : try? JSONEncoder().encode(objectRemoval)
    }
}

// MARK: - Version history entry

/// A sidecar-persisted counterpart to `AssetVersion`/today's `AssetVersionSnapshot` — reuses
/// `AssetBaseFieldSnapshot` (rather than the narrower 4-field legacy snapshot) so a restored version
/// also covers crop/spot-removal/object-removal, which today's in-app version history silently
/// drops. Still deliberately excludes the Scene stage (shared across other photos — restoring it
/// here would change them too) and Custom/mask stages (membership, not just values, would need
/// restoring) — same scope as today, just with a wider single-stage/base-field capture.
struct VersionEntry: Codable, Sendable {
    var id: UUID
    var name: String
    var branchName: String
    var createdDate: Date
    var parentID: UUID?
    var baseFields: AssetBaseFieldSnapshot
    var singleStage: StageFieldSnapshot
}

extension AssetVersionSnapshot {
    /// Projects a `VersionEntry` (the sidecar's wider capture) down to this legacy shape for
    /// storage in a rebuilt `AssetVersion.snapshotData` — `StagesSidebarView.restore(_:)` only ever
    /// decodes this narrower type, so a live in-app "Restore" still can't apply the wider fields
    /// back. The sidecar itself keeps the full `VersionEntry` regardless; this conversion only
    /// affects what the rebuilt SwiftData cache's own version-restore feature can act on.
    init(wide entry: VersionEntry) {
        editExposure = entry.baseFields.editExposure
        editNeutralTemperature = entry.baseFields.editNeutralTemperature
        editNeutralTint = entry.baseFields.editNeutralTint
        editSharpnessAmount = entry.baseFields.editSharpnessAmount
        singleStage = entry.singleStage
    }
}

// MARK: - .curve — one per PhotoAsset, self-sufficient

/// Everything affecting one photo, so opening this file alone tells the whole story for it —
/// including a redundant copy of whatever scene stage currently applies (the `.scene` manifest is
/// the authoritative owner of that data; this copy is what keeps a single stray `.curve` file
/// self-describing if it's ever separated from its session folder). Always sits beside the original
/// photo file — see `PhotoAsset.sidecarURL()`.
struct CurveSidecar: Codable, Sendable {
    var schemaVersion: Int = 1
    var assetID: UUID
    var baseFields: AssetBaseFieldSnapshot
    var rating: Int
    var flagRaw: Int
    var colorLabelRaw: Int
    /// The effective single/custom stages — already resolved through `PhotoAsset.singleStage`/
    /// `.customStages`, which route to the shared `PhotoStack` stages when stacked (see that
    /// property's doc comment on `PhotoAsset`). This is the same value whether or not this asset is
    /// stacked; the `.stack` manifest is the authoritative owner when it is, this is the redundant
    /// self-sufficient copy.
    var singleStage: StageFieldEntry
    var customStages: [StageFieldEntry]
    /// Distinct from `singleStage`/`customStages` because the scene stage layers *on top of* them
    /// rather than being routed through them — see `activeStageStack(for:)` in `EditorParameters.swift`.
    var sceneStageCopy: StageFieldEntry?
    var versions: [VersionEntry]
    var currentVersionID: UUID?
    // Reconciliation pointers — enough for a stray, separated file to self-identify even without
    // its session folder's `.scene`/`.stack` manifest.
    var sceneID: UUID?
    var sceneName: String?
    var sessionID: UUID?
    var sessionName: String?
    var stackID: UUID?

    init(capturing asset: PhotoAsset) {
        assetID = asset.id
        baseFields = AssetBaseFieldSnapshot(capturing: asset)
        rating = asset.ratingRaw
        flagRaw = asset.flagRaw
        colorLabelRaw = asset.colorLabelRaw
        singleStage = StageFieldEntry(capturing: asset.singleStage)
        customStages = asset.customStages.map(StageFieldEntry.init(capturing:))
        sceneStageCopy = asset.scene?.stage.map(StageFieldEntry.init(capturing:))
        versions = (asset.versions ?? []).map { version in
            VersionEntry(
                id: version.id, name: version.name, branchName: version.branchName,
                createdDate: version.createdDate, parentID: version.parent?.id,
                baseFields: AssetBaseFieldSnapshot(capturing: asset), singleStage: StageFieldSnapshot(capturing: asset.singleStage)
            )
        }
        currentVersionID = asset.currentVersionID
        sceneID = asset.scene?.id
        sceneName = asset.scene?.name
        sessionID = asset.session?.id
        sessionName = asset.session?.name
        stackID = asset.stack?.id
    }
}

// MARK: - .scene — one per PhotoScene, authoritative for its session folder

/// Since a `Session` now maps 1:1 to a single folder (see `Session`'s doc comment), every
/// `PhotoScene` nested in it is automatically confined to that same folder — which is what lets
/// this manifest be authoritative for membership + the shared stage's values, not just a
/// best-effort cache.
struct SceneSidecar: Codable, Sendable {
    var schemaVersion: Int = 1
    var sceneID: UUID
    var name: String
    var createdDate: Date
    var sessionID: UUID?
    var sessionName: String?
    var stage: StageFieldEntry
    /// Full filenames (with extension) of every member, resolvable purely from what's on disk —
    /// deliberately not `PhotoAsset` UUIDs, so a from-scratch rebuild (no existing rows at all) can
    /// still resolve membership.
    var memberFileNames: [String]

    init(capturing scene: PhotoScene) {
        sceneID = scene.id
        name = scene.name
        createdDate = scene.createdDate
        sessionID = scene.session?.id
        sessionName = scene.session?.name
        stage = StageFieldEntry(capturing: scene.stage ?? Stage(kind: .scene, name: "Scene", scene: scene))
        memberFileNames = (scene.photos ?? []).map(\.fileName)
    }
}

// MARK: - .stack — one per PhotoStack, authoritative for its session folder

/// Mirrors `SceneSidecar` — same folder-confinement reasoning (a `PhotoStack`'s members are already
/// scoped to one `Session` via `ContentView.groupIntoStack`'s pairing key, so this is confined the
/// same way once that session is confined to one folder).
struct StackSidecar: Codable, Sendable {
    var schemaVersion: Int = 1
    var stackID: UUID
    var name: String?
    var createdDate: Date
    var sessionID: UUID?
    var sessionName: String?
    var singleStage: StageFieldEntry
    var customStages: [StageFieldEntry]
    var memberFileNames: [String]

    init(capturing stack: PhotoStack) {
        stackID = stack.id
        name = stack.name
        createdDate = stack.createdDate
        let firstMemberSession = stack.photos?.first?.session
        sessionID = firstMemberSession?.id
        sessionName = firstMemberSession?.name
        singleStage = StageFieldEntry(capturing: stack.singleStage ?? Stage(kind: .single, name: "Single", stack: stack))
        customStages = stack.customStages.map(StageFieldEntry.init(capturing:))
        memberFileNames = (stack.photos ?? []).map(\.fileName)
    }
}
