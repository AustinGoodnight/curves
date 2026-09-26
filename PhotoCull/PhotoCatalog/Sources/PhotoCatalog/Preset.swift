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
///
/// Exposure and white balance live on `PhotoAsset`, not `Stage` (they're applied during RAW decode,
/// see `PhotoAsset.editExposure`'s doc comment), so they can't ride along inside `snapshotData` —
/// they're stored as their own fields below and written straight onto the target asset when the
/// preset is applied. Every preset saved since this landed carries exposure (`includesExposure`);
/// white balance is opt-in per save (`includesWhiteBalance`). Presets saved before either existed
/// decode with both flags `false` and leave the target's exposure/WB untouched, same as they always
/// did.
@Model
public final class Preset {
    public var id: UUID = UUID()
    public var name: String = ""
    public var createdDate: Date = Date()
    public var snapshotData: Data = Data()
    /// Whether this preset's values are applied automatically to every newly-imported photo's
    /// `.single` stage — see `StageFieldSnapshot.applyDefaultIfAvailable(to:context:)` in the app
    /// target, called from `ContentView.performImport`. At most one `Preset` has this set at a
    /// time; `StagesSidebarView.saveAsDefaultStage(_:)` clears it on every other preset before
    /// setting it here, rather than this type enforcing uniqueness itself.
    public var isDefault: Bool = false

    public var includesExposure: Bool = false
    /// `nil` means "as-shot" (same convention as `PhotoAsset.editExposure`) — applying a preset
    /// with `includesExposure` and a `nil` value resets the target back to as-shot exposure.
    public var exposure: Double?
    public var includesWhiteBalance: Bool = false
    public var neutralTemperature: Double?
    public var neutralTint: Double?
    public var whiteBalanceEnabled: Bool = false

    /// Set when the preset was saved with "Keep Within Session" — it's then only listed in the
    /// editor while a photo from that session is open. `nil` means global. Stored as a bare id
    /// (plus `sessionName` for display), **not** a relationship to `Session`, on purpose: deleting
    /// the session must never cascade to or orphan the preset, so the Settings preset manager can
    /// still list it (and promote it to global) after the session itself is gone.
    public var sessionID: UUID?
    public var sessionName: String = ""

    /// The global-library folder this preset is filed under — `nil` is the top level. Only
    /// meaningful for global presets (`sessionID == nil`); session presets are grouped by session
    /// instead.
    public var folder: PresetFolder?

    public init(name: String, snapshotData: Data) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.snapshotData = snapshotData
    }
}

/// A user-created folder for organizing global `Preset`s in the Settings preset manager. One level
/// deep — no nesting. Deleting a folder moves its presets back to the top level (`.nullify`)
/// rather than deleting them.
@Model
public final class PresetFolder {
    public var id: UUID = UUID()
    public var name: String = ""
    public var createdDate: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Preset.folder)
    public var presets: [Preset]? = []

    public init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.presets = []
    }
}
