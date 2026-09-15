import Foundation
import SwiftData

@Model
public final class PhotoAsset {
    public var id: UUID = UUID()
    public var filePath: String = ""
    public var bookmarkData: Data?
    public var fileName: String = ""
    public var fileExtension: String = ""
    public var importDate: Date = Date()
    public var captureDate: Date?
    /// Set each time this photo is *opened* in the editor (`ContentView.openEditor(for:)`), not on
    /// every slider tick — a per-tick write would fire a SwiftData mutation, and thus a broad
    /// `@Query` re-fire, on every single drag, which is exactly the write-side mirror of the read-
    /// side `@Query`-invalidation traps this app's CLAUDE.md documents at length. "Opened for
    /// editing" is a cheap-to-maintain proxy for "recently edited" — good enough to drive the
    /// editor sidebar's "Copy from Recent" list (`RecentEditsBrowserView`) without that cost.
    public var lastEditedDate: Date?
    public var fileSize: Int64 = 0
    public var pixelWidth: Int = 0
    public var pixelHeight: Int = 0
    public var ratingRaw: Int = 0
    public var flagRaw: Int = FlagState.none.rawValue
    public var colorLabelRaw: Int = ColorLabel.none.rawValue

    /// EXIF/TIFF readouts captured at import time (see `ThumbnailProvider.captureMetadata`) —
    /// empty string/zero when the file's tags didn't have that field, not `nil`, so older assets
    /// that predate this migrate in at the same "unknown" default a fresh import would get for a
    /// file missing that tag.
    public var cameraModel: String = ""
    public var lensModel: String = ""
    public var iso: Int = 0
    public var shutterSpeed: Double = 0
    public var aperture: Double = 0
    public var focalLength: Double = 0

    public var stack: PhotoStack?
    public var scene: PhotoScene?
    public var session: Session?

    /// Base edit parameters for `RawEngine`'s `CIRAWFilter` pipeline. `nil` means "use this
    /// image's as-shot/vendor default" — not zero — so an unedited photo renders exactly as the
    /// camera intended until the user actually touches a slider. Unlike the four kernel-module
    /// parameter groups (Filmic RGB, Color Balance RGB, RGB Curve, Color Zones — now on `Stage`),
    /// these stay directly on `PhotoAsset`: `CIRAWFilter` applies them once during RAW decode,
    /// before any stage's kernel passes run, so there's no "per stage" version of these to stack.
    public var editExposure: Double?
    public var editBoostAmount: Double?
    public var editNeutralTemperature: Double?
    public var editNeutralTint: Double?
    public var editSharpnessAmount: Double?
    /// AI-based noise reduction (`RawEngine`'s OIDN-backed `DenoiseFilter`), 0...1. Asset-level
    /// like Sharpness above, not per-`Stage` like Dehaze — same "applied once during RAW decode"
    /// reasoning, and gated by the same `editDetailEnabled` switch below.
    public var editDenoiseAmount: Double?

    /// Module bypass switches for the two asset-level (non-stackable) groups in
    /// `ColorBalanceBarView` — "WB" and "Detail". `true` means apply whatever's stored above/on the
    /// relevant `Stage`; `false` renders as if untouched (native as-shot WB; native sharpness; no
    /// Dehaze contribution from any stage) without discarding the stored values, so re-enabling
    /// restores exactly what was there. Asset-level (not per-`Stage`, unlike the four kernel-module
    /// `isEnabled` switches on `Stage`) because every field they gate — Temp/Tint/Sharpness —
    /// already lives directly on `PhotoAsset` for the same "not stackable per stage" reason (see
    /// the doc comment above); "Detail" additionally suppresses Dehaze's contribution from every
    /// active `Stage` uniformly rather than per-stage, since there's no single "the stage this
    /// toggle belongs to" once more than one stage is active at once. Denoise joined this group
    /// alongside Sharpness rather than getting its own switch — same asset-level "detail
    /// correction" category, and OIDN's inference cost only applies at all once `amount > 0`
    /// (`DenoiseFilter.apply` short-circuits before touching the GPU otherwise), so there's no
    /// separate performance reason to keep it out of the shared bypass.
    ///
    /// `false` by default and whenever the group's own fields are all unset (Temp/Tint for WB;
    /// Sharpness/Denoise plus the *current* stage's Dehaze for Detail) — auto-managed by
    /// `syncModuleEnabled` in the app target's `EditorParameters.swift`, same "no contribution
    /// until touched" convention as `Stage`'s own module switches. Flips `true` automatically on
    /// the first adjustment to either field; the `StoplightToggle` in `ColorBalanceBarView` still
    /// works as a manual bypass once that's happened.
    public var editWhiteBalanceEnabled: Bool = false
    public var editDetailEnabled: Bool = false

    /// Whether `RawEngine`'s lens-correction module (distortion/vignetting/chromatic aberration,
    /// looked up from `cameraModel`/`lensModel`/`focalLength`/`aperture` above) contributes to this
    /// asset's render. Asset-level, not per-`Stage`, for the same "not stackable" reason as the
    /// group above — see `RawBaseParameters.lensCorrection`'s doc comment. `true` by default:
    /// unlike WB/Detail (which start as no-ops until the user drags a slider), a matched lens
    /// profile should correct the shot from the moment it's imported, matching how every other RAW
    /// editor treats lens profiles as on-by-default rather than an opt-in effect.
    public var editLensCorrectionEnabled: Bool = true
    /// 0...1 "Amount" dial layered on top of the calculated correction; `nil` means the default
    /// full-strength (1.0) correction, same "nil = untouched default" convention as every other
    /// optional edit field.
    public var editLensCorrectionIntensity: Double?

    /// Straighten angle in degrees; `nil` means untouched (0°). Asset-level, not per-`Stage` — see
    /// `CropParameters`'s doc comment for why crop/straighten is a base param like the lens
    /// correction group above rather than a stackable/maskable module.
    public var editCropAngleDegrees: Double?
    /// The crop rectangle's four normalized (0...1) components, in the coordinate frame of the
    /// image *after* rotating by `editCropAngleDegrees` — see `CropParameters.rect`'s doc comment.
    /// All four are `nil` together (never independently) whenever no crop has been set, meaning the
    /// full rotated frame; `CropEditorOverlay` is the only writer and always sets all four at once.
    public var editCropRectX: Double?
    public var editCropRectY: Double?
    public var editCropRectWidth: Double?
    public var editCropRectHeight: Double?

    /// JSON-encoded `[SpotRemoval]` (see `RawEngine`) — healed/cloned spots, in normalized
    /// coordinates of the full, unrotated, uncropped image frame. `nil` or an empty decoded array
    /// both mean "no spots", same "no contribution" convention as the crop fields above.
    /// Asset-level, not per-`Stage`, for the same "one repair pass, not a per-stage creative grade"
    /// reasoning as crop/lens correction — see `RawBaseParameters.spotRemoval`'s doc comment.
    public var spotRemovalData: Data?
    /// JSON-encoded `[ObjectRemoval]` (see `RawEngine`) — AI-removed objects (Vision-selected mask
    /// plus an already-synthesized Core ML fill), same normalized full-frame convention and
    /// "nil/empty = no contribution" rule as `spotRemovalData` above. A separate field/list rather
    /// than folded into `spotRemovalData` — see `ObjectRemoval`'s doc comment on `RawEngine` for why
    /// it's a distinct type from `SpotRemoval`.
    public var objectRemovalData: Data?

    /// Owns this photo's `.single` stage (always present, index 0) and any `.custom` stages the
    /// user has added. The shared `.scene` stage lives on `PhotoScene` instead — see `Stage`'s
    /// doc comment.
    @Relationship(deleteRule: .cascade, inverse: \Stage.asset)
    public var stages: [Stage]? = []

    /// Named checkpoints of this photo's edit state — see `AssetVersion`'s doc comment. Unordered
    /// storage; `StagesSidebarView` sorts by `createdDate` for display.
    @Relationship(deleteRule: .cascade, inverse: \AssetVersion.asset)
    public var versions: [AssetVersion]? = []
    /// The version currently "checked out" — git's HEAD, essentially. `nil` means the live edit
    /// state isn't known to match any saved version (the common case: mid-edit, or no version
    /// saved yet). A plain `UUID`, not a relationship, so deleting the `AssetVersion` it points to
    /// doesn't need a cascade/nullify rule of its own — `StagesSidebarView` clears this directly
    /// when deleting the version it currently points at.
    public var currentVersionID: UUID?

    /// The always-present, per-photo stage — created alongside this asset in `init` and never
    /// deleted or renamed. **Routed to `stack.singleStage` instead whenever `stack` is set**: a
    /// stacked photo doesn't get its own independent `Single` — every photo in the stack shares
    /// exactly the one on `PhotoStack`, so editing any one of them edits all of them identically.
    /// See `PhotoStack.stages`'s doc comment. Falls back to this asset's own stage only when
    /// unstacked (or, defensively, if the stack is somehow missing its shared stage). The final
    /// `??` fallback only matters for assets that predate the `Stage` model and haven't been
    /// migrated yet; it deliberately returns a transient, unpersisted `Stage` rather than crashing.
    public var singleStage: Stage {
        if let stack, let shared = stack.singleStage { return shared }
        return stages?.first(where: { $0.kind == .single }) ?? Stage(kind: .single, name: "Single", asset: self)
    }

    /// User-added stages (every `StageKind.isUserManaged` kind, interleaved in one shared
    /// `sortIndex` sequence), in display/composite order. Routed to `stack.customStages` whenever
    /// `stack` is set — same sharing as `singleStage`, see its doc comment.
    public var customStages: [Stage] {
        if let stack { return stack.customStages }
        return (stages ?? []).filter { $0.kind.isUserManaged }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public var rating: Int {
        get { ratingRaw }
        set { ratingRaw = max(0, min(5, newValue)) }
    }

    public var flag: FlagState {
        get { FlagState(rawValue: flagRaw) ?? .none }
        set { flagRaw = newValue.rawValue }
    }

    public var colorLabel: ColorLabel {
        get { ColorLabel(rawValue: colorLabelRaw) ?? .none }
        set { colorLabelRaw = newValue.rawValue }
    }

    public init(
        filePath: String,
        bookmarkData: Data? = nil,
        fileName: String,
        fileExtension: String,
        session: Session,
        importDate: Date = Date(),
        captureDate: Date? = nil,
        fileSize: Int64 = 0,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        cameraModel: String = "",
        lensModel: String = "",
        iso: Int = 0,
        shutterSpeed: Double = 0,
        aperture: Double = 0,
        focalLength: Double = 0
    ) {
        self.id = UUID()
        self.filePath = filePath
        self.bookmarkData = bookmarkData
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.session = session
        self.importDate = importDate
        self.captureDate = captureDate
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.iso = iso
        self.shutterSpeed = shutterSpeed
        self.aperture = aperture
        self.focalLength = focalLength
        self.ratingRaw = 0
        self.flagRaw = FlagState.none.rawValue
        self.colorLabelRaw = ColorLabel.none.rawValue
        self.stages = [Stage(kind: .single, name: "Single", asset: self)]
    }

    /// `"1/250s"` below one second (Lightroom/camera-app convention — a raw decimal like `0.004s`
    /// is unreadable at a glance), `"2.5s"` at or above one second. Trailing zeroes trimmed so a
    /// clean fraction like 1/250 doesn't print as `1/250.0s`.
    public var shutterSpeedDisplay: String {
        guard shutterSpeed > 0 else { return "" }
        if shutterSpeed >= 1 {
            return "\(shutterSpeed.formatted(.number.precision(.fractionLength(0...1))))s"
        }
        let denominator = (1 / shutterSpeed).rounded()
        return "1/\(Int(denominator))s"
    }

    public var apertureDisplay: String {
        guard aperture > 0 else { return "" }
        return "f/\(aperture.formatted(.number.precision(.fractionLength(0...1))))"
    }

    public var isoDisplay: String {
        guard iso > 0 else { return "" }
        return "ISO \(iso)"
    }

    public var focalLengthDisplay: String {
        guard focalLength > 0 else { return "" }
        return "\(focalLength.formatted(.number.precision(.fractionLength(0...1))))mm"
    }

    /// `fileName` with its extension stripped — the key used to match a RAW and a JPG as "the same
    /// shot" (e.g. "A7C05978.ARW" and "A7C05978.JPG" both give "A7C05978"). `(fileName as NSString)
    /// .deletingPathExtension` matches the one other ad hoc place in the app that already needed
    /// this (`ExportSupport.swift`'s renamed-export path), rather than reimplementing it via
    /// `fileExtension`'s stored length.
    public var baseFileName: String {
        (fileName as NSString).deletingPathExtension
    }

    /// Bookmarks survive file moves/renames within the same volume; the raw path is the
    /// fast-path fallback when no bookmark was captured (or it fails to resolve).
    public func resolvedURL() -> URL {
        if let bookmarkData {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return url
            }
        }
        return URL(fileURLWithPath: filePath)
    }

    /// The `.curve` sidecar co-located with the original file — always appends onto the full
    /// original filename (`IMG_1234.ARW` → `IMG_1234.ARW.curve`), never strips/replaces its
    /// extension. RAW+JPG pairs of the same shot are separate `PhotoAsset`s (matched later by
    /// `baseFileName`, not paired at import) — stripping the extension before appending would give
    /// both the same sidecar filename and collide them.
    public func sidecarURL() -> URL {
        resolvedURL().appendingPathExtension("curve")
    }
}
