import Foundation
import PhotoCatalog
import RawEngine

/// Builds a `RawEditParameters` from an asset's stored edit fields, plus the smaller per-module
/// pieces and reset/has-edits helpers it's assembled from. Free functions rather than computed
/// properties on `EditorView` so every control cluster (`EditorSidebarView`, `ColorBalanceBarView`,
/// `EditorFooterActions`) can build the full params it needs to hand to
/// `EditorRenderCoordinator.scheduleRender(params:)` — every render needs all modules' params
/// regardless of which single control changed — without funneling through a shared parent.

func rawEditParameters(for asset: PhotoAsset) -> RawEditParameters {
    RawEditParameters(
        exposure: asset.editExposure,
        neutralTemperature: asset.editNeutralTemperature,
        neutralTint: asset.editNeutralTint,
        sharpnessAmount: asset.editSharpnessAmount,
        filmicRGB: filmicParameters(for: asset),
        colorBalanceRGB: colorBalanceParameters(for: asset),
        colorZones: colorZonesParameters(for: asset),
        rgbCurve: rgbCurveParameters(for: asset)
    )
}

/// Every module has a bypass switch — `nil` here means "skip this `CIColorKernel` pass
/// entirely", not just "run it at its numerically-no-op defaults". That's a real cost difference,
/// not just semantics: these are `CIColorKernel(source:)`-based (the deprecated Core Image Kernel
/// Language path, not native Metal), so running one at its defaults still pays for a full
/// pixel-buffer pass through it.
func filmicParameters(for asset: PhotoAsset) -> FilmicRGBParameters? {
    guard asset.editFilmicEnabled else { return nil }
    let d = FilmicRGBParameters.darktableDefault
    return FilmicRGBParameters(
        blackPointSource: asset.editFilmicBlackPointSource ?? d.blackPointSource,
        whitePointSource: asset.editFilmicWhitePointSource ?? d.whitePointSource,
        latitude: asset.editFilmicLatitude ?? d.latitude,
        contrast: asset.editFilmicContrast ?? d.contrast,
        saturation: asset.editFilmicSaturation ?? d.saturation,
        balance: asset.editFilmicBalance ?? d.balance
    )
}

func colorBalanceParameters(for asset: PhotoAsset) -> ColorBalanceRGBParameters? {
    guard asset.editColorBalanceEnabled else { return nil }
    let d = ColorBalanceRGBParameters.darktableDefault
    return ColorBalanceRGBParameters(
        shadowsY: asset.editColorBalanceShadowsY ?? d.shadowsY,
        shadowsC: asset.editColorBalanceShadowsC ?? d.shadowsC,
        shadowsH: asset.editColorBalanceShadowsH ?? d.shadowsH,
        midtonesY: asset.editColorBalanceMidtonesY ?? d.midtonesY,
        midtonesC: asset.editColorBalanceMidtonesC ?? d.midtonesC,
        midtonesH: asset.editColorBalanceMidtonesH ?? d.midtonesH,
        highlightsY: asset.editColorBalanceHighlightsY ?? d.highlightsY,
        highlightsC: asset.editColorBalanceHighlightsC ?? d.highlightsC,
        highlightsH: asset.editColorBalanceHighlightsH ?? d.highlightsH,
        globalY: asset.editColorBalanceGlobalY ?? d.globalY,
        globalC: asset.editColorBalanceGlobalC ?? d.globalC,
        globalH: asset.editColorBalanceGlobalH ?? d.globalH,
        chromaGlobal: asset.editColorBalanceChromaGlobal ?? d.chromaGlobal,
        vibrance: asset.editColorBalanceVibrance ?? d.vibrance,
        contrast: asset.editColorBalanceContrast ?? d.contrast
    )
}

/// `PhotoAsset` stores curve points flat-interleaved (`[x0, y0, x1, y1, ...]`) for SwiftData
/// persistence (see `PhotoAsset.editRGBCurvePoints`); `CurveEditorControl` works in
/// `[SIMD2<Double>]` for its own geometry math. This is the conversion boundary.
func rgbCurvePoints(for asset: PhotoAsset) -> [SIMD2<Double>] {
    guard let flat = asset.editRGBCurvePoints, flat.count >= 4, flat.count.isMultiple(of: 2) else {
        return RGBCurveParameters.identityPoints
    }
    return stride(from: 0, to: flat.count, by: 2).map { SIMD2(flat[$0], flat[$0 + 1]) }
}

func rgbCurveParameters(for asset: PhotoAsset) -> RGBCurveParameters? {
    guard asset.editRGBCurveEnabled else { return nil }
    return RGBCurveParameters(points: rgbCurvePoints(for: asset), preserveColors: asset.editRGBCurvePreserveColors ?? true)
}

/// Same flat-interleaved <-> `[SIMD2<Double>]` conversion as `rgbCurvePoints`, but generalized
/// over the 3 color-zones curve keypaths.
func colorZonesPoints(for asset: PhotoAsset, _ keyPath: ReferenceWritableKeyPath<PhotoAsset, [Double]?>) -> [SIMD2<Double>] {
    guard let flat = asset[keyPath: keyPath], flat.count >= 4, flat.count.isMultiple(of: 2) else {
        return ColorZonesParameters.identityPoints
    }
    return stride(from: 0, to: flat.count, by: 2).map { SIMD2(flat[$0], flat[$0 + 1]) }
}

func colorZonesParameters(for asset: PhotoAsset) -> ColorZonesParameters? {
    guard asset.editColorZonesEnabled else { return nil }
    return ColorZonesParameters(
        lightnessPoints: colorZonesPoints(for: asset, \.editColorZonesLightnessPoints),
        chromaPoints: colorZonesPoints(for: asset, \.editColorZonesChromaPoints),
        huePoints: colorZonesPoints(for: asset, \.editColorZonesHuePoints)
    )
}

// MARK: - Has-edits

func filmicHasEdits(_ asset: PhotoAsset) -> Bool {
    !asset.editFilmicEnabled
        || asset.editFilmicWhitePointSource != nil || asset.editFilmicBlackPointSource != nil
        || asset.editFilmicContrast != nil || asset.editFilmicLatitude != nil
        || asset.editFilmicSaturation != nil || asset.editFilmicBalance != nil
}

func colorBalanceHasEdits(_ asset: PhotoAsset) -> Bool {
    !asset.editColorBalanceEnabled
        || asset.editColorBalanceGlobalY != nil || asset.editColorBalanceGlobalC != nil || asset.editColorBalanceGlobalH != nil
        || asset.editColorBalanceShadowsY != nil || asset.editColorBalanceShadowsC != nil || asset.editColorBalanceShadowsH != nil
        || asset.editColorBalanceMidtonesY != nil || asset.editColorBalanceMidtonesC != nil || asset.editColorBalanceMidtonesH != nil
        || asset.editColorBalanceHighlightsY != nil || asset.editColorBalanceHighlightsC != nil || asset.editColorBalanceHighlightsH != nil
        || asset.editColorBalanceContrast != nil || asset.editColorBalanceVibrance != nil || asset.editColorBalanceChromaGlobal != nil
}

func rgbCurveHasEdits(_ asset: PhotoAsset) -> Bool {
    !asset.editRGBCurveEnabled || asset.editRGBCurvePoints != nil || asset.editRGBCurvePreserveColors != nil
}

func colorZonesHasEdits(_ asset: PhotoAsset) -> Bool {
    !asset.editColorZonesEnabled
        || asset.editColorZonesLightnessPoints != nil || asset.editColorZonesChromaPoints != nil
        || asset.editColorZonesHuePoints != nil
}

func hasAnyEdits(_ asset: PhotoAsset) -> Bool {
    asset.editExposure != nil || asset.editNeutralTemperature != nil || asset.editNeutralTint != nil
        || asset.editSharpnessAmount != nil || filmicHasEdits(asset) || colorBalanceHasEdits(asset)
        || rgbCurveHasEdits(asset) || colorZonesHasEdits(asset)
}

// MARK: - Reset

func resetFilmic(_ asset: PhotoAsset) {
    asset.editFilmicEnabled = true
    asset.editFilmicWhitePointSource = nil
    asset.editFilmicBlackPointSource = nil
    asset.editFilmicContrast = nil
    asset.editFilmicLatitude = nil
    asset.editFilmicSaturation = nil
    asset.editFilmicBalance = nil
}

func resetColorBalance(_ asset: PhotoAsset) {
    asset.editColorBalanceEnabled = true
    asset.editColorBalanceGlobalY = nil
    asset.editColorBalanceGlobalC = nil
    asset.editColorBalanceGlobalH = nil
    asset.editColorBalanceShadowsY = nil
    asset.editColorBalanceShadowsC = nil
    asset.editColorBalanceShadowsH = nil
    asset.editColorBalanceMidtonesY = nil
    asset.editColorBalanceMidtonesC = nil
    asset.editColorBalanceMidtonesH = nil
    asset.editColorBalanceHighlightsY = nil
    asset.editColorBalanceHighlightsC = nil
    asset.editColorBalanceHighlightsH = nil
    asset.editColorBalanceContrast = nil
    asset.editColorBalanceVibrance = nil
    asset.editColorBalanceChromaGlobal = nil
}

func resetRGBCurve(_ asset: PhotoAsset) {
    asset.editRGBCurveEnabled = true
    asset.editRGBCurvePoints = nil
    asset.editRGBCurvePreserveColors = nil
}

func resetColorZones(_ asset: PhotoAsset) {
    asset.editColorZonesEnabled = true
    asset.editColorZonesLightnessPoints = nil
    asset.editColorZonesChromaPoints = nil
    asset.editColorZonesHuePoints = nil
}

func resetAllEdits(_ asset: PhotoAsset) {
    asset.editExposure = nil
    asset.editNeutralTemperature = nil
    asset.editNeutralTint = nil
    asset.editSharpnessAmount = nil
    resetFilmic(asset)
    resetColorBalance(asset)
    resetRGBCurve(asset)
    resetColorZones(asset)
}
