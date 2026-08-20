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
        neutralTemperature: asset.editNeutralTemperature,
        neutralTint: asset.editNeutralTint,
        sharpnessAmount: asset.editSharpnessAmount
    )
}

// MARK: - Stage params (the four stackable `CIColorKernel` modules)

/// Every module has a bypass switch — `nil` here means "skip this `CIColorKernel` pass
/// entirely", not just "run it at its numerically-no-op defaults". That's a real cost difference,
/// not just semantics: these are `CIColorKernel(source:)`-based (the deprecated Core Image Kernel
/// Language path, not native Metal), so running one at its defaults still pays for a full
/// pixel-buffer pass through it.
func filmicParameters(for stage: Stage) -> FilmicRGBParameters? {
    guard stage.editFilmicEnabled else { return nil }
    let d = FilmicRGBParameters.darktableDefault
    return FilmicRGBParameters(
        blackPointSource: stage.editFilmicBlackPointSource ?? d.blackPointSource,
        whitePointSource: stage.editFilmicWhitePointSource ?? d.whitePointSource,
        latitude: stage.editFilmicLatitude ?? d.latitude,
        contrast: stage.editFilmicContrast ?? d.contrast,
        saturation: stage.editFilmicSaturation ?? d.saturation,
        balance: stage.editFilmicBalance ?? d.balance
    )
}

func colorBalanceParameters(for stage: Stage) -> ColorBalanceRGBParameters? {
    guard stage.editColorBalanceEnabled else { return nil }
    let d = ColorBalanceRGBParameters.darktableDefault
    return ColorBalanceRGBParameters(
        shadowsY: stage.editColorBalanceShadowsY ?? d.shadowsY,
        shadowsC: stage.editColorBalanceShadowsC ?? d.shadowsC,
        shadowsH: stage.editColorBalanceShadowsH ?? d.shadowsH,
        midtonesY: stage.editColorBalanceMidtonesY ?? d.midtonesY,
        midtonesC: stage.editColorBalanceMidtonesC ?? d.midtonesC,
        midtonesH: stage.editColorBalanceMidtonesH ?? d.midtonesH,
        highlightsY: stage.editColorBalanceHighlightsY ?? d.highlightsY,
        highlightsC: stage.editColorBalanceHighlightsC ?? d.highlightsC,
        highlightsH: stage.editColorBalanceHighlightsH ?? d.highlightsH,
        globalY: stage.editColorBalanceGlobalY ?? d.globalY,
        globalC: stage.editColorBalanceGlobalC ?? d.globalC,
        globalH: stage.editColorBalanceGlobalH ?? d.globalH,
        chromaGlobal: stage.editColorBalanceChromaGlobal ?? d.chromaGlobal,
        vibrance: stage.editColorBalanceVibrance ?? d.vibrance,
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

func stageParameters(for stage: Stage) -> StageParameters {
    StageParameters(
        filmicRGB: filmicParameters(for: stage),
        colorBalanceRGB: colorBalanceParameters(for: stage),
        colorZones: colorZonesParameters(for: stage),
        rgbCurve: rgbCurveParameters(for: stage)
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
@MainActor
func scheduleRender(for asset: PhotoAsset, activeStages: [Stage], coordinator: EditorRenderCoordinator) {
    coordinator.scheduleRender(
        baseParams: rawBaseParameters(for: asset),
        stageStack: activeStages.map(stageParameters(for:))
    )
}

// MARK: - Has-edits

func filmicHasEdits(_ stage: Stage) -> Bool {
    !stage.editFilmicEnabled
        || stage.editFilmicWhitePointSource != nil || stage.editFilmicBlackPointSource != nil
        || stage.editFilmicContrast != nil || stage.editFilmicLatitude != nil
        || stage.editFilmicSaturation != nil || stage.editFilmicBalance != nil
}

func colorBalanceHasEdits(_ stage: Stage) -> Bool {
    !stage.editColorBalanceEnabled
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

/// Whether `stage` itself carries any adjustments — used to grey out per-stage reset buttons and
/// (via `hasAnyEdits`) "Reset All".
func stageHasEdits(_ stage: Stage) -> Bool {
    filmicHasEdits(stage) || colorBalanceHasEdits(stage) || rgbCurveHasEdits(stage) || colorZonesHasEdits(stage)
}

/// Whether there's anything for "Reset All" to do — the asset's base params plus whichever stage
/// is currently selected for editing. Scoped to the selected stage rather than every active stage
/// so "Reset All" only ever touches what's currently on screen, matching the "blank slate"
/// editing model (see `Stage`'s doc comment).
func hasAnyEdits(asset: PhotoAsset, stage: Stage) -> Bool {
    asset.editExposure != nil || asset.editNeutralTemperature != nil || asset.editNeutralTint != nil
        || asset.editSharpnessAmount != nil || stageHasEdits(stage)
}

// MARK: - Reset

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

func resetAllEdits(asset: PhotoAsset, stage: Stage) {
    asset.editExposure = nil
    asset.editNeutralTemperature = nil
    asset.editNeutralTint = nil
    asset.editSharpnessAmount = nil
    resetFilmic(stage)
    resetColorBalance(stage)
    resetRGBCurve(stage)
    resetColorZones(stage)
}
