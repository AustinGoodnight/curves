import Foundation
import SwiftData

/// A named, reusable snapshot of a stage's worth of adjustments — saved from the editor's
/// "Save as Preset…" context-menu item (one stage) or "Save All Stages as Preset…" button (the
/// current photo's whole active stack, flattened — see `StageFieldSnapshot.init(mergingActiveStages:)`
/// in the app target), and listed for reuse in `PresetBrowserView`. Applying a preset always creates
/// a new **custom `Stage`** on the target photo (`StagesSidebarView.applyPreset(_:)`) — never a
/// scene stage — so loading the same preset onto ten different photos gives each its own
/// independently-editable/removable copy, the same way `addCustomStage()` does, rather than linking
/// them the way `PhotoScene.stage` links every photo in a scene.
///
/// Stores its field values as an encoded `StageFieldSnapshot` blob rather than duplicating that
/// struct's fields as `@Model` properties — same convention as `AssetVersion.snapshotData`;
/// `snapshotData` is opaque from this package's perspective.
@Model
public final class Preset {
    public var id: UUID = UUID()
    public var name: String = ""
    public var createdDate: Date = Date()
    public var snapshotData: Data = Data()

    public init(name: String, snapshotData: Data) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.snapshotData = snapshotData
    }
}
