import CoreGraphics
import Foundation
import PhotoCatalog
import RawEngine

/// Builds render parameters from an asset's base fields and a stage's stored module fields, plus
/// the smaller per-module pieces and reset/has-edits helpers they're assembled from. Free
/// functions rather than computed properties on `EditorView` so every control cluster
/// (`EditorSidebarView`, `ColorBalanceBarView`, `EditorFooterActions`) can build what it needs to
/// hand to `EditorRenderCoordinator` without funneling through a shared parent.

// MARK: - Base params (PhotoAsset — native `CIRAWFilter` inputs, not stackable per-stage)

func rawBaseParameters(for asset: PhotoAsset) -> RawBaseParameters {
    RawBaseParameters(
        exposure: asset.editExposure,
        neutralTemperature: asset.editWhiteBalanceEnabled ? asset.editNeutralTemperature : nil,
        neutralTint: asset.editWhiteBalanceEnabled ? asset.editNeutralTint : nil,
        sharpnessAmount: asset.editDetailEnabled ? asset.editSharpnessAmount : nil,
        lensCorrection: lensCorrectionParameters(for: asset),
        crop: cropParameters(for: asset)
    )
}

/// Looks up `asset`'s matched lens profile (see `LensCorrectionDatabase.profile`) and applies the
/// user's own enable switch/Amount dial on top. `nil` whenever the switch is off *or* no lens in
/// the database matched this shot's EXIF closely enough — both cases render exactly as if this
/// module didn't exist, matching every other module's "nil = no contribution" convention.
func lensCorrectionParameters(for asset: PhotoAsset) -> LensCorrectionParameters? {
    guard asset.editLensCorrectionEnabled else { return nil }
    guard var profile = LensCorrectionDatabase.shared.profile(
        cameraModel: asset.cameraModel, lensModel: asset.lensModel,
        focalLength: asset.focalLength, aperture: asset.aperture
    ) else { return nil }
    profile.intensity = asset.editLensCorrectionIntensity ?? 1
    return profile
}

/// `nil` whenever `asset` has no straighten/crop set at all — same "nil = no contribution"
/// convention as every other base param, checked via the crop rect fields (all four are always set
/// together by `CropEditorOverlay`, see their doc comment on `PhotoAsset`) rather than the angle
/// alone, since a rect-only crop with zero rotation is still a real crop to apply.
func cropParameters(for asset: PhotoAsset) -> CropParameters? {
    guard asset.editCropAngleDegrees != nil || asset.editCropRectWidth != nil else { return nil }
    return CropParameters(
        angleDegrees: asset.editCropAngleDegrees ?? 0,
        rect: CGRect(
            x: asset.editCropRectX ?? 0, y: asset.editCropRectY ?? 0,
            width: asset.editCropRectWidth ?? 1, height: asset.editCropRectHeight ?? 1
        )
    )
}

// MARK: - Stage params (the four stackable `CIColorKernel` modules)

/// Every module has a bypass switch — `nil` here means "skip this `CIColorKernel` pass
/// entirely", not just "run it at its numerically-no-op defaults". That's a real cost difference,
/// not just semantics: these are `CIColorKernel(source:)`-based (the deprecated Core Image Kernel
/// Language path, not native Metal), so running one at its defaults still pays for a full
/// pixel-buffer pass through it.
/// `nil` whenever the fader is untouched, dragged back to exactly 0, or its group's own switch
/// (`detailEnabled`, `PhotoAsset.editDetailEnabled` — see its doc comment) is off — there's no
/// separate per-field bypass switch for Dehaze itself (see `Stage.editDehazeAmount`'s doc comment).
func dehazeParameters(for stage: Stage, detailEnabled: Bool) -> DehazeParameters? {
    guard detailEnabled, let amount = stage.editDehazeAmount, amount != 0 else { return nil }
    return DehazeParameters(amount: amount)
}

func filmicParameters(for stage: Stage) -> FilmicRGBParameters? {
    guard stage.editFilmicEnabled else { return nil }
    let d = FilmicRGBParameters.darktableDefault
    return FilmicRGBParameters(
        blackPointSource: stage.editFilmicBlackPointSource ?? d.blackPointSource,
        whitePointSource: stage.editFilmicWhitePointSource ?? d.whitePointSource,
        latitude: stage.editFilmicLatitude ?? d.latitude,
        contrast: stage.editFilmicContrast ?? d.contrast,
        saturation: stage.editBalanceEnabled ? (stage.editFilmicSaturation ?? d.saturation) : d.saturation,
        balance: stage.editFilmicBalance ?? d.balance
    )
}

/// Builds every `ColorBalanceRGBParameters` field from `stage`'s stored edits, except that the
/// "Color Wheels" group (12 Y/C/H fields) and the "Balance" group (Chroma/Vibrance) each fall back
/// to `ColorBalanceRGBParameters.darktableDefault`'s neutral value — not just the stored edit's own
/// `?? default` fallback, but unconditionally — whenever that group's own switch
/// (`editColorWheelsEnabled`/`editBalanceEnabled`) is off, same as `editColorBalanceEnabled`
/// already does for the whole struct but scoped to just that group's fields. Contrast has no group
/// switch of its own (it's a sidebar control, not part of either bar group) and always uses its
/// stored edit regardless.
func colorBalanceParameters(for stage: Stage) -> ColorBalanceRGBParameters? {
    guard stage.editColorBalanceEnabled else { return nil }
    let d = ColorBalanceRGBParameters.darktableDefault
    let wheels = stage.editColorWheelsEnabled
    let balance = stage.editBalanceEnabled
    return ColorBalanceRGBParameters(
        shadowsY: wheels ? (stage.editColorBalanceShadowsY ?? d.shadowsY) : d.shadowsY,
        shadowsC: wheels ? (stage.editColorBalanceShadowsC ?? d.shadowsC) : d.shadowsC,
        shadowsH: wheels ? (stage.editColorBalanceShadowsH ?? d.shadowsH) : d.shadowsH,
        midtonesY: wheels ? (stage.editColorBalanceMidtonesY ?? d.midtonesY) : d.midtonesY,
        midtonesC: wheels ? (stage.editColorBalanceMidtonesC ?? d.midtonesC) : d.midtonesC,
        midtonesH: wheels ? (stage.editColorBalanceMidtonesH ?? d.midtonesH) : d.midtonesH,
        highlightsY: wheels ? (stage.editColorBalanceHighlightsY ?? d.highlightsY) : d.highlightsY,
        highlightsC: wheels ? (stage.editColorBalanceHighlightsC ?? d.highlightsC) : d.highlightsC,
        highlightsH: wheels ? (stage.editColorBalanceHighlightsH ?? d.highlightsH) : d.highlightsH,
        globalY: wheels ? (stage.editColorBalanceGlobalY ?? d.globalY) : d.globalY,
        globalC: wheels ? (stage.editColorBalanceGlobalC ?? d.globalC) : d.globalC,
        globalH: wheels ? (stage.editColorBalanceGlobalH ?? d.globalH) : d.globalH,
        chromaGlobal: balance ? (stage.editColorBalanceChromaGlobal ?? d.chromaGlobal) : d.chromaGlobal,
        vibrance: balance ? (stage.editColorBalanceVibrance ?? d.vibrance) : d.vibrance,
        contrast: stage.editColorBalanceContrast ?? d.contrast
    )
}

/// `Stage` stores curve points flat-interleaved (`[x0, y0, x1, y1, ...]`) for SwiftData
/// persistence (see `Stage.editRGBCurvePoints`); `CurveEditorControl` works in `[SIMD2<Double>]`
/// for its own geometry math. This is the conversion boundary.
func rgbCurvePoints(for stage: Stage) -> [SIMD2<Double>] {
    guard let flat = stage.editRGBCurvePoints, flat.count >= 4, flat.count.isMultiple(of: 2) else {
        return RGBCurveParameters.identityPoints
    }
    return stride(from: 0, to: flat.count, by: 2).map { SIMD2(flat[$0], flat[$0 + 1]) }
}

func rgbCurveParameters(for stage: Stage) -> RGBCurveParameters? {
    guard stage.editRGBCurveEnabled else { return nil }
    return RGBCurveParameters(
        points: rgbCurvePoints(for: stage), preserveColors: stage.editRGBCurvePreserveColors ?? true,
        blackLift: stage.editRGBCurveBlackLift ?? 0
    )
}

/// Same flat-interleaved <-> `[SIMD2<Double>]` conversion as `rgbCurvePoints`, but generalized
/// over the 3 color-zones curve keypaths.
func colorZonesPoints(for stage: Stage, _ keyPath: ReferenceWritableKeyPath<Stage, [Double]?>) -> [SIMD2<Double>] {
    guard let flat = stage[keyPath: keyPath], flat.count >= 4, flat.count.isMultiple(of: 2) else {
        return ColorZonesParameters.identityPoints
    }
    return stride(from: 0, to: flat.count, by: 2).map { SIMD2(flat[$0], flat[$0 + 1]) }
}

func colorZonesParameters(for stage: Stage) -> ColorZonesParameters? {
    guard stage.editColorZonesEnabled else { return nil }
    return ColorZonesParameters(
        lightnessPoints: colorZonesPoints(for: stage, \.editColorZonesLightnessPoints),
        chromaPoints: colorZonesPoints(for: stage, \.editColorZonesChromaPoints),
        huePoints: colorZonesPoints(for: stage, \.editColorZonesHuePoints)
    )
}

/// `nil` whenever no LUT is loaded (`lut3DData`/`lut3DSize` unset), regardless of
/// `editLUT3DEnabled` — a bypass switch has nothing to bypass until a LUT exists.
func lut3DParameters(for stage: Stage) -> LUT3DParameters? {
    guard stage.editLUT3DEnabled, let data = stage.lut3DData, let size = stage.lut3DSize, size >= 2 else { return nil }
    let lut = LUT3D(size: size, data: data, title: stage.lut3DTitle)
    return LUT3DParameters(lut: lut, intensity: stage.lut3DIntensity ?? 1)
}

func stageParameters(for stage: Stage, detailEnabled: Bool) -> StageParameters {
    StageParameters(
        dehaze: dehazeParameters(for: stage, detailEnabled: detailEnabled),
        filmicRGB: filmicParameters(for: stage),
        colorBalanceRGB: colorBalanceParameters(for: stage),
        colorZones: colorZonesParameters(for: stage),
        rgbCurve: rgbCurveParameters(for: stage),
        lut3D: lut3DParameters(for: stage),
        maskData: stage.maskData
    )
}

// MARK: - Compositing

/// The full set of stages that contribute to this asset's rendered image, in the fixed
/// Scene → Single → Custom order, filtered to enabled stages. Selecting a different stage for
/// *editing* (`EditorView.selectedStage`) never changes this — the render always composites every
/// active stage regardless of which one's controls are currently shown. No separate step for
/// stacking: `asset.singleStage`/`.customStages` already resolve to the stack's shared stages when
/// `asset.stack` is set (see `PhotoAsset.singleStage`'s doc comment), so this reads the same either
/// way.
func activeStageStack(for asset: PhotoAsset) -> [Stage] {
    var stack: [Stage] = []
    if let sceneStage = asset.scene?.stage {
        stack.append(sceneStage)
    }
    stack.append(asset.singleStage)
    stack.append(contentsOf: asset.customStages)
    return stack.filter(\.isEnabled)
}

/// Every render needs the full composited stack, not just the stage being edited — same "every
/// render needs all modules" reasoning the single-stage version of this file used to document,
/// just widened from one stage's modules to every active stage's. Takes `activeStages` as an
/// already-computed array (see `EditorView.activeStages`) rather than recomputing it via
/// `activeStageStack(for:)` here — that walks relationships and is too expensive to redo on every
/// single slider-drag tick.
/// `history` is `nil` at the few call sites that make a *structural* change (add/delete/rename a
/// stage, flip a stage's own `isEnabled`) — see `EditHistory`'s doc comment for why those aren't
/// undoable. Every value-level call site passes its `EditHistory` so the edit is undoable.
@MainActor
func scheduleRender(for asset: PhotoAsset, activeStages: [Stage], coordinator: EditorRenderCoordinator, history: EditHistory? = nil) {
    history?.registerChange(asset: asset, activeStages: activeStages)
    coordinator.scheduleRender(
        baseParams: rawBaseParameters(for: asset),
        stageStack: activeStages.map { stageParameters(for: $0, detailEnabled: asset.editDetailEnabled) }
    )
}

// MARK: - Module auto-toggle

/// A module's own bypass switch, described generically enough to cover a `Stage`-level switch, a
/// `PhotoAsset`-level switch, or (Detail's) one whose fields span both — the closures just close
/// over whichever object(s) actually hold the relevant fields, so this one type serves every call
/// site in `EditorSidebarView`/`ColorBalanceBarView` instead of a bespoke variant per owner type.
struct ModuleGate {
    let hasAdjustments: () -> Bool
    let setEnabled: (Bool) -> Void
}

/// Keeps a module's bypass switch in sync with whether it actually holds any adjustments. Call
/// with the module's `hasAdjustments` result from *before* the edit that just happened (`stageBind`/
/// `bind`'s setters, and the few bespoke value-change closures, all do this around their own
/// mutation). Forced off the instant a module empties out — there's no reason to keep paying a
/// module's render cost (Filmic/Color Balance/RGB Curve/Color Zones are `CIColorKernel` passes,
/// real cost even at neutral defaults, see `filmicParameters`'s doc comment) once nothing in it
/// differs from the identity case. Forced *on* only on the transition from empty to non-empty —
/// otherwise the very edit that just gave the module its first adjustment would silently not
/// render. Never forces a module back on while it already had adjustments: that's what lets a user
/// manually bypass a populated module (keeping its values, suppressing its effect) without a later
/// edit to one of its *other* fields fighting the toggle back on.
func syncModuleEnabled(_ gate: ModuleGate, hadAdjustments: Bool) {
    let hasAdjustmentsNow = gate.hasAdjustments()
    if !hasAdjustmentsNow {
        gate.setEnabled(false)
    } else if !hadAdjustments {
        gate.setEnabled(true)
    }
}

// MARK: - Has-adjustments

func dehazeHasAdjustments(_ stage: Stage) -> Bool {
    stage.editDehazeAmount != nil
}

func filmicHasAdjustments(_ stage: Stage) -> Bool {
    stage.editFilmicWhitePointSource != nil || stage.editFilmicBlackPointSource != nil
        || stage.editFilmicContrast != nil || stage.editFilmicLatitude != nil
        || stage.editFilmicSaturation != nil || stage.editFilmicBalance != nil
}

func colorWheelsHasAdjustments(_ stage: Stage) -> Bool {
    stage.editColorBalanceGlobalY != nil || stage.editColorBalanceGlobalC != nil || stage.editColorBalanceGlobalH != nil
        || stage.editColorBalanceShadowsY != nil || stage.editColorBalanceShadowsC != nil || stage.editColorBalanceShadowsH != nil
        || stage.editColorBalanceMidtonesY != nil || stage.editColorBalanceMidtonesC != nil || stage.editColorBalanceMidtonesH != nil
        || stage.editColorBalanceHighlightsY != nil || stage.editColorBalanceHighlightsC != nil || stage.editColorBalanceHighlightsH != nil
}

func balanceGroupHasAdjustments(_ stage: Stage) -> Bool {
    stage.editColorBalanceChromaGlobal != nil || stage.editColorBalanceVibrance != nil || stage.editFilmicSaturation != nil
}

/// The whole Color Balance RGB module's own adjustments, spanning both sub-groups (Wheels/
/// Balance) plus Contrast, which has no sub-group switch of its own — see
/// `Stage.editColorBalanceContrast`'s doc comment.
func colorBalanceHasAdjustments(_ stage: Stage) -> Bool {
    colorWheelsHasAdjustments(stage) || balanceGroupHasAdjustments(stage) || stage.editColorBalanceContrast != nil
}

func rgbCurveHasAdjustments(_ stage: Stage) -> Bool {
    stage.editRGBCurvePoints != nil || stage.editRGBCurvePreserveColors != nil || stage.editRGBCurveBlackLift != nil
}

func colorZonesHasAdjustments(_ stage: Stage) -> Bool {
    stage.editColorZonesLightnessPoints != nil || stage.editColorZonesChromaPoints != nil
        || stage.editColorZonesHuePoints != nil
}

func lut3DHasAdjustments(_ stage: Stage) -> Bool {
    stage.lut3DData != nil
}

func whiteBalanceHasAdjustments(_ asset: PhotoAsset) -> Bool {
    asset.editNeutralTemperature != nil || asset.editNeutralTint != nil
}

/// Spans both `asset` (Sharpness) and `stage` (Dehaze) — "Detail" is the one bypass switch that
/// gates fields living on two different owners, see `PhotoAsset.editDetailEnabled`'s doc comment.
func detailHasAdjustments(asset: PhotoAsset, stage: Stage) -> Bool {
    asset.editSharpnessAmount != nil || stage.editDehazeAmount != nil
}

/// Whether `stage` itself carries any adjustments — used to grey out per-stage reset buttons and
/// (via `hasAnyEdits`) "Reset All". Each module's own bypass switch is kept in sync with this by
/// `syncModuleEnabled`, so — unlike before this existed — a disabled switch never needs checking
/// here separately: a module left enabled with nothing set, or disabled while still holding
/// values, are exactly the two states `syncModuleEnabled` guards against/preserves respectively.
func stageHasEdits(_ stage: Stage) -> Bool {
    dehazeHasAdjustments(stage) || filmicHasAdjustments(stage) || colorBalanceHasAdjustments(stage)
        || rgbCurveHasAdjustments(stage) || colorZonesHasAdjustments(stage) || lut3DHasAdjustments(stage)
}

/// Whether there's anything for "Reset All" to do — the asset's base params plus whichever stage
/// is currently selected for editing. Scoped to the selected stage rather than every active stage
/// so "Reset All" only ever touches what's currently on screen, matching the "blank slate"
/// editing model (see `Stage`'s doc comment). Lens correction keeps its own explicit
/// `!editLensCorrectionEnabled` check (unlike every other module here) because it's the one switch
/// that's meaningfully "on" even with zero adjustments — see
/// `PhotoAsset.editLensCorrectionEnabled`'s doc comment for why it's on-by-default rather than an
/// opt-in module like the others.
/// Whether `asset` has a straighten angle or crop rect set — see the crop fields' doc comment on
/// `PhotoAsset` for why checking the rect's width alone is enough (all four rect fields are always
/// set together).
func cropHasAdjustments(_ asset: PhotoAsset) -> Bool {
    asset.editCropAngleDegrees != nil || asset.editCropRectWidth != nil
}

func hasAnyEdits(asset: PhotoAsset, stage: Stage) -> Bool {
    asset.editExposure != nil || whiteBalanceHasAdjustments(asset) || asset.editSharpnessAmount != nil
        || !asset.editLensCorrectionEnabled || asset.editLensCorrectionIntensity != nil
        || cropHasAdjustments(asset)
        || stageHasEdits(stage)
}

// MARK: - Reset

func resetDehaze(_ stage: Stage) {
    stage.editDehazeAmount = nil
}

func resetFilmic(_ stage: Stage) {
    stage.editFilmicEnabled = false
    stage.editFilmicWhitePointSource = nil
    stage.editFilmicBlackPointSource = nil
    stage.editFilmicContrast = nil
    stage.editFilmicLatitude = nil
    stage.editFilmicSaturation = nil
    stage.editFilmicBalance = nil
}

func resetColorBalance(_ stage: Stage) {
    stage.editColorBalanceEnabled = false
    stage.editColorWheelsEnabled = false
    stage.editBalanceEnabled = false
    stage.editColorBalanceGlobalY = nil
    stage.editColorBalanceGlobalC = nil
    stage.editColorBalanceGlobalH = nil
    stage.editColorBalanceShadowsY = nil
    stage.editColorBalanceShadowsC = nil
    stage.editColorBalanceShadowsH = nil
    stage.editColorBalanceMidtonesY = nil
    stage.editColorBalanceMidtonesC = nil
    stage.editColorBalanceMidtonesH = nil
    stage.editColorBalanceHighlightsY = nil
    stage.editColorBalanceHighlightsC = nil
    stage.editColorBalanceHighlightsH = nil
    stage.editColorBalanceContrast = nil
    stage.editColorBalanceVibrance = nil
    stage.editColorBalanceChromaGlobal = nil
}

func resetRGBCurve(_ stage: Stage) {
    stage.editRGBCurveEnabled = false
    stage.editRGBCurvePoints = nil
    stage.editRGBCurvePreserveColors = nil
    stage.editRGBCurveBlackLift = nil
}

func resetColorZones(_ stage: Stage) {
    stage.editColorZonesEnabled = false
    stage.editColorZonesLightnessPoints = nil
    stage.editColorZonesChromaPoints = nil
    stage.editColorZonesHuePoints = nil
}

func resetLUT3D(_ stage: Stage) {
    stage.editLUT3DEnabled = false
    stage.lut3DData = nil
    stage.lut3DSize = nil
    stage.lut3DTitle = nil
    stage.lut3DIntensity = nil
}

func resetCrop(_ asset: PhotoAsset) {
    asset.editCropAngleDegrees = nil
    asset.editCropRectX = nil
    asset.editCropRectY = nil
    asset.editCropRectWidth = nil
    asset.editCropRectHeight = nil
}

func resetAllEdits(asset: PhotoAsset, stage: Stage) {
    asset.editExposure = nil
    asset.editNeutralTemperature = nil
    asset.editNeutralTint = nil
    asset.editSharpnessAmount = nil
    asset.editWhiteBalanceEnabled = false
    asset.editDetailEnabled = false
    asset.editLensCorrectionEnabled = true
    asset.editLensCorrectionIntensity = nil
    resetCrop(asset)
    resetDehaze(stage)
    resetFilmic(stage)
    resetColorBalance(stage)
    resetRGBCurve(stage)
    resetColorZones(stage)
    resetLUT3D(stage)
}
