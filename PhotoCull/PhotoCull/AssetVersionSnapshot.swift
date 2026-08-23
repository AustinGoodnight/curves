import Foundation
import PhotoCatalog

/// The decoded contents of an `AssetVersion.snapshotData` blob — everything needed to restore "the
/// photo's primary edit" to a prior state: the asset's own base params plus its Single stage's
/// full module state (`StageFieldSnapshot`, shared with `EditHistory`'s undo/redo).
///
/// Scope note: this deliberately does **not** include the Scene stage (shared across every photo
/// in the scene — restoring it here would silently change other photos too) or Custom/Assisted-
/// mask stages (an open-ended list whose *membership* would need restoring, not just field
/// values — a bigger feature than "basic version control" calls for). A version captures the same
/// surface `EditorSidebarView`/`ColorBalanceBarView` show for the Single stage.
struct AssetVersionSnapshot: Codable {
    var editExposure: Double?
    var editNeutralTemperature: Double?
    var editNeutralTint: Double?
    var editSharpnessAmount: Double?
    var singleStage: StageFieldSnapshot

    init(asset: PhotoAsset) {
        editExposure = asset.editExposure
        editNeutralTemperature = asset.editNeutralTemperature
        editNeutralTint = asset.editNeutralTint
        editSharpnessAmount = asset.editSharpnessAmount
        singleStage = StageFieldSnapshot(capturing: asset.singleStage)
    }

    func apply(to asset: PhotoAsset) {
        asset.editExposure = editExposure
        asset.editNeutralTemperature = editNeutralTemperature
        asset.editNeutralTint = editNeutralTint
        asset.editSharpnessAmount = editSharpnessAmount
        singleStage.apply(to: asset.singleStage)
    }
}
