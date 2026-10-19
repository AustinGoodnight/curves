import Foundation
import SwiftData

/// Which of the seven roles a `Stage` plays. `.single` and `.scene` are structural — every
/// `PhotoAsset`/`PhotoScene` has exactly one, created alongside its owner and never deleted or
/// renamed. `.custom`, `.assistedMask`, `.linearGradientMask`, `.radialGradientMask`, and
/// `.colorRangeMask` stages are freely added/removed/renamed by the user and share one `sortIndex`
/// sequence (see `PhotoAsset.customStages`'s doc comment). The five mask kinds all differ from
/// `.custom` only in how `maskData` gets populated: `.assistedMask` via the assisted mask editor
/// (rough brush strokes refined to the photo's own edges by a guided filter — see
/// `GuidedMaskRefiner` in the app target); `.linearGradientMask`/`.radialGradientMask` via
/// `GradientMaskEditorOverlay`, which also keeps the gradient's geometry on `gradientStartX`/etc. so
/// it stays live-editable ("Adjust Gradient…") instead of only being a baked raster like the other
/// mask kinds; `.colorRangeMask` via `ColorRangeMaskEditorOverlay` (click-to-sample a color, then
/// threshold/feather select every pixel near it), which similarly keeps its own parameters on
/// `colorRangeRed`/etc. for the same "Adjust…" live-reedit reason; `.objectMask` via
/// `ObjectMaskEditorOverlay` (click a Vision-detected object/subject to add its whole silhouette to
/// the mask, option-click to remove one) — a baked raster like `.assistedMask`, no live-reedit
/// parameters of its own, since a Vision instance selection has no small parameter set the way a
/// gradient or color sample does. A stack doesn't get its own kind
/// — see `PhotoStack.stages`'s doc comment for why a stacked photo's `.single`/`.custom`/mask stages
/// are the *same kind*, just owned by the stack instead of the asset.
public enum StageKind: Int, Codable, Sendable {
    case single = 0
    case scene = 1
    case custom = 2
    case assistedMask = 3
    case linearGradientMask = 4
    case radialGradientMask = 5
    case colorRangeMask = 6
    case objectMask = 7

    /// Whether this kind belongs to the user-managed `.custom`-style sequence (freely added,
    /// renamed, deleted, ordered by `sortIndex`) rather than being structural like `.single`/
    /// `.scene`. Centralizes the membership check `PhotoAsset.customStages`/`PhotoStack
    /// .customStages` and `StagesSidebarView`'s rename/delete gating all need, so a future new kind
    /// only has to be added here once instead of at every call site independently.
    public var isUserManaged: Bool {
        self != .single && self != .scene
    }

    /// SF Symbol shown as a small prefix before this kind's name in `StagesSidebarView`'s stage
    /// list — `nil` for kinds that need no visual distinction from a plain `.custom` stage.
    public var rowIcon: String? {
        switch self {
        case .assistedMask: return "wand.and.stars"
        case .linearGradientMask: return "rectangle.righthalf.filled"
        case .radialGradientMask: return "target"
        case .colorRangeMask: return "eyedropper"
        case .objectMask: return "wand.and.rays"
        case .single, .scene, .custom: return nil
        }
    }
}

/// One independently-editable, non-destructive set of tone/color adjustments. A photo's rendered
/// result is always the *composite* of every enabled stage that applies to it, applied in a fixed
/// order (scene stage, then the photo's own single stage, then its custom stages by
/// `sortIndex`) — see `activeStageStack(for:)` in the app target's `EditorParameters.swift`.
/// Selecting a stage in the editor only changes which stage's own values the controls show
/// ("blank slate" editing); it never changes what's rendered.
///
/// Exactly one of `asset`/`scene`/`stack` is set: an unstacked photo's own `.single`/`.custom`
/// stages are owned by its `PhotoAsset` (`asset`); a *stacked* photo's `.single`/`.custom` stages
/// are instead owned by its `PhotoStack` (`stack`) and shared with every other photo in that stack
/// — see `PhotoStack.stages`'s and `PhotoAsset.singleStage`'s doc comments. The one shared `.scene`
/// stage is owned by a `PhotoScene` (`scene`) and applies to every photo in it, independently of
/// stacking.
///
/// Holds the five *stackable* kernel-module parameter groups: Dehaze, plus the four that used to
/// live directly on `PhotoAsset` (Filmic RGB, Color Balance RGB, RGB Curve, Color Zones) — see
/// each field's doc comment there for the original rationale, unchanged by the move. Exposure/
/// white-balance/sharpness stay on `PhotoAsset` itself rather than becoming per-stage: those are
/// native `CIRAWFilter` inputs applied once during RAW decode, before any stage's kernel passes
/// run, so they can't be meaningfully stacked per-stage the way the five `CIColorKernel` modules
/// can.
@Model
public final class Stage {
    public var id: UUID = UUID()
    public var name: String = ""
    public var kindRaw: Int = StageKind.custom.rawValue
    public var isEnabled: Bool = true
    public var createdDate: Date = Date()
    /// Ordering among a `PhotoAsset`'s `.custom` stages. `.scene` and `.single` are always first/
    /// second by construction, not by this field.
    public var sortIndex: Int = 0

    public var asset: PhotoAsset?
    public var scene: PhotoScene?
    public var stack: PhotoStack?

    /// A grayscale PNG (white = fully affected, black = unaffected) limiting which pixels this
    /// stage's kernel passes touch — `nil` means the stage applies to the whole image, matching
    /// every other module's "nil = no-op" convention in this codebase. Populated by the assisted
    /// mask editor for `.assistedMask` stages; `.custom` stages may also set it by the same
    /// mechanism. Stored at a fixed working resolution independent of render size — see
    /// `RawImageRenderer.applyStage(_:to:)` for how it's rescaled per render.
    public var maskData: Data?

    /// Gradient geometry for `.linearGradientMask`/`.radialGradientMask` stages, `nil` for every
    /// other kind. All in normalized 0–1 image-space coordinates/lengths (fraction of image width,
    /// matching `x`'s own normalization, so a circle stays a true circle regardless of the photo's
    /// aspect ratio) rather than pixel coordinates, so they stay meaningful independent of
    /// `maskData`'s own fixed working resolution. Kept alongside the baked `maskData` raster
    /// (`GradientMaskEditorOverlay.finish()` writes both together) purely so reopening the editor
    /// ("Adjust Gradient…") can restore the exact handle positions instead of only offering a blank
    /// slate the way `.assistedMask`'s "Refine Mask…" does — the render pipeline itself only ever
    /// reads `maskData`, never these. `gradientStartX`/`Y` doubles as the linear gradient's start
    /// handle (full effect) or the radial gradient's center; `gradientEndX`/`Y` is the linear
    /// gradient's end handle (no effect) and is unused by `.radialGradientMask`, which uses
    /// `gradientRadius`/`gradientFeather` instead.
    public var gradientStartX: Double?
    public var gradientStartY: Double?
    public var gradientEndX: Double?
    public var gradientEndY: Double?
    /// Radial only: normalized radius (from center) of full effect, before the feather falloff.
    public var gradientRadius: Double?
    /// Radial only: normalized width of the soft falloff band beyond `gradientRadius`.
    public var gradientFeather: Double?
    /// Both kinds: flips which side of the gradient is fully affected vs. fully protected.
    public var gradientInverted: Bool?

    /// Sampled target color for `.colorRangeMask` stages, `nil` for every other kind — linear 0–1
    /// components, matching the working-space convention `ColorRangeMaskEditorOverlay` samples the
    /// preview `CGImage` in. Kept alongside the baked `maskData` raster for the same "Adjust…"
    /// live-reedit reason as `gradientStartX`/etc. above; the render pipeline only ever reads
    /// `maskData`.
    public var colorRangeRed: Double?
    public var colorRangeGreen: Double?
    public var colorRangeBlue: Double?
    /// Normalized (0–1) color-distance a pixel can be from the sampled target and still count as
    /// fully selected.
    public var colorRangeThreshold: Double?
    /// Normalized (0–1) width of the soft falloff band beyond `colorRangeThreshold`, same role as
    /// `gradientFeather` above.
    public var colorRangeFeather: Double?
    /// Flips which pixels are fully selected vs. fully excluded, same role as `gradientInverted`.
    public var colorRangeInverted: Bool?

    /// `nil` means no haze removal — see `DehazeKernel`/`DehazeParameters` in `RawEngine`. No
    /// separate `editDehazeEnabled` switch of its *own* — `nil`/0 is already a true no-op — but its
    /// *group's* switch (`PhotoAsset.editDetailEnabled`, shared with Sharpness under the "Detail"
    /// header in `ColorBalanceBarView`) can still suppress it; see that property's doc comment.
    public var editDehazeAmount: Double?

    /// `false` by default and whenever the module empties back out (see `syncModuleEnabled` in the
    /// app target's `EditorParameters.swift`) — matches every other `nil`-valued field's "no
    /// contribution until touched" convention, and avoids paying for a `CIColorKernel` pass with
    /// nothing to do (see this file's doc comment). Flips `true` automatically the moment any of
    /// this module's fields below get an actual adjustment; the `StoplightToggle` bound to it in
    /// `EditorSidebarView` still works as a manual bypass once that's happened.
    public var editFilmicEnabled: Bool = false
    public var editFilmicWhitePointSource: Double?
    public var editFilmicBlackPointSource: Double?
    public var editFilmicContrast: Double?
    public var editFilmicLatitude: Double?
    /// Also gated by `editBalanceEnabled` (see its doc comment) despite living in the Filmic RGB
    /// module rather than Color Balance RGB — `ColorBalanceBarView`'s "Balance" fader group spans
    /// both kernels (Chroma/Vibrance here are Color Balance RGB fields; Saturation is this one).
    public var editFilmicSaturation: Double?
    public var editFilmicBalance: Double?

    /// Same auto-managed convention as `editFilmicEnabled` above, and mutually exclusive with it —
    /// Filmic and AgX are alternative tone mappers for the same pipeline slot (see
    /// `RawImageRenderer.applyStage(_:to:)`); the app target's tone-mapper picker in
    /// `EditorSidebarView` is what keeps only one of the two `true` at a time.
    public var editAgXEnabled: Bool = false
    public var editAgXWhitePointSource: Double?
    public var editAgXBlackPointSource: Double?
    public var editAgXContrast: Double?
    public var editAgXSlope: Double?
    public var editAgXLift: Double?
    public var editAgXBrightness: Double?
    public var editAgXSaturation: Double?
    public var editAgXHueMix: Double?

    /// `false` by default/when empty, same auto-managed convention as `editFilmicEnabled` above —
    /// see `syncModuleEnabled` in the app target's `EditorParameters.swift`.
    public var editColorBalanceEnabled: Bool = false
    /// Sub-group bypass switches, finer-grained than `editColorBalanceEnabled` above — that one
    /// gates the whole `CIColorKernel` pass (returning `nil` from `colorBalanceParameters(for:)`
    /// entirely); these two instead swap specific fields back to
    /// `ColorBalanceRGBParameters.darktableDefault`'s neutral values while the pass still runs (so
    /// e.g. Contrast, which has no group of its own, keeps applying independently of either). Named
    /// for the two independently-toggleable clusters `ColorBalanceBarView.colorBalanceSection`
    /// splits its fields into: "Color Wheels" (the 12 Y/C/H fields below) and "Balance" (Chroma/
    /// Vibrance here, plus Filmic's Saturation — see `editFilmicSaturation`'s doc comment).
    /// Both `false` by default/when their own fields are all unset, same auto-managed convention
    /// as `editFilmicEnabled` above.
    public var editColorWheelsEnabled: Bool = false
    public var editBalanceEnabled: Bool = false
    public var editColorBalanceGlobalY: Double?
    public var editColorBalanceGlobalC: Double?
    public var editColorBalanceGlobalH: Double?
    public var editColorBalanceShadowsY: Double?
    public var editColorBalanceShadowsC: Double?
    public var editColorBalanceShadowsH: Double?
    public var editColorBalanceMidtonesY: Double?
    public var editColorBalanceMidtonesC: Double?
    public var editColorBalanceMidtonesH: Double?
    public var editColorBalanceHighlightsY: Double?
    public var editColorBalanceHighlightsC: Double?
    public var editColorBalanceHighlightsH: Double?
    /// Per-wheel bypass, inside the Color Wheels group — `true` sends just that wheel's Y/C/H back
    /// to neutral while the others keep applying, without losing its values. `nil` means on (every
    /// stage predating these reads as on). Cleared again as soon as that wheel is dragged.
    public var editColorBalanceGlobalOff: Bool?
    public var editColorBalanceShadowsOff: Bool?
    public var editColorBalanceMidtonesOff: Bool?
    public var editColorBalanceHighlightsOff: Bool?
    public var editColorBalanceContrast: Double?
    public var editColorBalanceVibrance: Double?
    public var editColorBalanceChromaGlobal: Double?

    /// `false` by default/when empty, same auto-managed convention as `editFilmicEnabled` above.
    public var editRGBCurveEnabled: Bool = false
    public var editRGBCurvePoints: [Double]?
    public var editRGBCurvePreserveColors: Bool?
    /// A small, fixed lift applied uniformly to the curve's output (`out = in × (1 − lift) +
    /// lift`, the standard "lift" term from lift/gamma/gain color grading) — raises the black
    /// point while keeping the white point pinned at 1, independent of `editRGBCurvePoints`'s own
    /// node positions. A separate, precise numeric control rather than dragging the curve graph's
    /// bottom-left endpoint, for the same "coarse graph vs. exact number" reason Filmic's sliders
    /// exist alongside a graph-free module. Gated by `editRGBCurveEnabled`, same as the curve
    /// itself — see `RGBCurveKernel`'s doc comment for where this applies in the shader.
    public var editRGBCurveBlackLift: Double?
    /// A second tone curve, applied right after the first (same flat `[x0, y0, x1, y1, …]`
    /// layout, same enable switch and Preserve Color setting) — the Curve section's "2" tab. Lets
    /// a creative curve be stacked on a corrective one without merging them into a single shape.
    /// `nil` (or a straight line) means it isn't rendered at all.
    public var editRGBCurve2Points: [Double]?

    /// `false` by default/when empty, same auto-managed convention as `editFilmicEnabled` above.
    public var editColorZonesEnabled: Bool = false
    public var editColorZonesLightnessPoints: [Double]?
    public var editColorZonesChromaPoints: [Double]?
    public var editColorZonesHuePoints: [Double]?

    /// A loaded "film simulation" 3D LUT (`.cube` file), applied last in the stage's kernel
    /// chain — see `RawImageRenderer.applyStage(_:to:)`. `lut3DData`/`lut3DSize` being `nil` means
    /// no LUT is loaded, independent of `editLUT3DEnabled` (which just lets a loaded LUT be
    /// bypassed without discarding it, matching every other module's bypass switch).
    /// `false` by default/whenever no LUT is loaded, same auto-managed convention as
    /// `editFilmicEnabled` above — flips `true` the moment a LUT is loaded (see
    /// `ColorBalanceBarView.applyLUT(_:)`).
    public var editLUT3DEnabled: Bool = false
    /// Raw RGBA float32 bytes, red-fastest order — see `LUT3D.data`'s doc comment for the exact
    /// layout. Stored pre-parsed so the original `.cube` file never needs to be re-read.
    public var lut3DData: Data?
    public var lut3DSize: Int?
    public var lut3DTitle: String?
    public var lut3DIntensity: Double?

    public var kind: StageKind {
        get { StageKind(rawValue: kindRaw) ?? .custom }
        set { kindRaw = newValue.rawValue }
    }

    public init(
        kind: StageKind, name: String, asset: PhotoAsset? = nil, scene: PhotoScene? = nil, stack: PhotoStack? = nil,
        sortIndex: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.isEnabled = true
        self.createdDate = Date()
        self.sortIndex = sortIndex
        self.asset = asset
        self.scene = scene
        self.stack = stack
    }
}
