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
        sharpnessAmount: asset.editDetailEnabled ? asset.editSharpnessAmount : nil
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
    return RGBCurveParameters(points: rgbCurvePoints(for: stage), preserveColors: stage.editRGBCurvePreserveColors ?? true)
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

// MARK: - Has-edits

func dehazeHasEdits(_ stage: Stage) -> Bool {
    stage.editDehazeAmount != nil
}

func filmicHasEdits(_ stage: Stage) -> Bool {
    !stage.editFilmicEnabled
        || stage.editFilmicWhitePointSource != nil || stage.editFilmicBlackPointSource != nil
        || stage.editFilmicContrast != nil || stage.editFilmicLatitude != nil
        || stage.editFilmicSaturation != nil || stage.editFilmicBalance != nil
}

func colorBalanceHasEdits(_ stage: Stage) -> Bool {
    !stage.editColorBalanceEnabled || !stage.editColorWheelsEnabled || !stage.editBalanceEnabled
        || stage.editColorBalanceGlobalY != nil || stage.editColorBalanceGlobalC != nil || stage.editColorBalanceGlobalH != nil
        || stage.editColorBalanceShadowsY != nil || stage.editColorBalanceShadowsC != nil || stage.editColorBalanceShadowsH != nil
        || stage.editColorBalanceMidtonesY != nil || stage.editColorBalanceMidtonesC != nil || stage.editColorBalanceMidtonesH != nil
        || stage.editColorBalanceHighlightsY != nil || stage.editColorBalanceHighlightsC != nil || stage.editColorBalanceHighlightsH != nil
        || stage.editColorBalanceContrast != nil || stage.editColorBalanceVibrance != nil || stage.editColorBalanceChromaGlobal != nil
}

func rgbCurveHasEdits(_ stage: Stage) -> Bool {
    !stage.editRGBCurveEnabled || stage.editRGBCurvePoints != nil || stage.editRGBCurvePreserveColors != nil
}

func colorZonesHasEdits(_ stage: Stage) -> Bool {
    !stage.editColorZonesEnabled
        || stage.editColorZonesLightnessPoints != nil || stage.editColorZonesChromaPoints != nil
        || stage.editColorZonesHuePoints != nil
}

func lut3DHasEdits(_ stage: Stage) -> Bool {
    stage.lut3DData != nil || !stage.editLUT3DEnabled || stage.lut3DIntensity != nil
}

/// Whether `stage` itself carries any adjustments — used to grey out per-stage reset buttons and
/// (via `hasAnyEdits`) "Reset All".
func stageHasEdits(_ stage: Stage) -> Bool {
    dehazeHasEdits(stage) || filmicHasEdits(stage) || colorBalanceHasEdits(stage) || rgbCurveHasEdits(stage)
        || colorZonesHasEdits(stage) || lut3DHasEdits(stage)
}

/// Whether there's anything for "Reset All" to do — the asset's base params plus whichever stage
/// is currently selected for editing. Scoped to the selected stage rather than every active stage
/// so "Reset All" only ever touches what's currently on screen, matching the "blank slate"
/// editing model (see `Stage`'s doc comment).
func hasAnyEdits(asset: PhotoAsset, stage: Stage) -> Bool {
    asset.editExposure != nil || asset.editNeutralTemperature != nil || asset.editNeutralTint != nil
        || asset.editSharpnessAmount != nil || !asset.editWhiteBalanceEnabled || !asset.editDetailEnabled
        || stageHasEdits(stage)
}

// MARK: - Reset

func resetDehaze(_ stage: Stage) {
    stage.editDehazeAmount = nil
}

func resetFilmic(_ stage: Stage) {
    stage.editFilmicEnabled = true
    stage.editFilmicWhitePointSource = nil
    stage.editFilmicBlackPointSource = nil
    stage.editFilmicContrast = nil
    stage.editFilmicLatitude = nil
    stage.editFilmicSaturation = nil
    stage.editFilmicBalance = nil
}

func resetColorBalance(_ stage: Stage) {
    stage.editColorBalanceEnabled = true
    stage.editColorWheelsEnabled = true
    stage.editBalanceEnabled = true
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
    stage.editRGBCurveEnabled = true
    stage.editRGBCurvePoints = nil
    stage.editRGBCurvePreserveColors = nil
}

func resetColorZones(_ stage: Stage) {
    stage.editColorZonesEnabled = true
    stage.editColorZonesLightnessPoints = nil
    stage.editColorZonesChromaPoints = nil
    stage.editColorZonesHuePoints = nil
}

func resetLUT3D(_ stage: Stage) {
    stage.editLUT3DEnabled = true
    stage.lut3DData = nil
    stage.lut3DSize = nil
    stage.lut3DTitle = nil
    stage.lut3DIntensity = nil
}

func resetAllEdits(asset: PhotoAsset, stage: Stage) {
    asset.editExposure = nil
    asset.editNeutralTemperature = nil
    asset.editNeutralTint = nil
    asset.editSharpnessAmount = nil
    asset.editWhiteBalanceEnabled = true
    asset.editDetailEnabled = true
    resetDehaze(stage)
    resetFilmic(stage)
    resetColorBalance(stage)
    resetRGBCurve(stage)
    resetColorZones(stage)
    resetLUT3D(stage)
}
