import Foundation
import PhotoCatalog

/// A full copy of every user-editable field on a `Stage` (every module's values plus its mask) —
/// the shared building block for both `EditHistory` (in-memory undo/redo diffing, hence
/// `Equatable`) and `AssetVersionSnapshot` (persisted named versions, hence `Codable`). Field list
/// mirrors `Stage.swift` exactly; keep the two in sync when a module gains/loses a field.
struct StageFieldSnapshot: Codable, Equatable {
    var editDehazeAmount: Double?

    var editFilmicEnabled: Bool
    var editFilmicWhitePointSource: Double?
    var editFilmicBlackPointSource: Double?
    var editFilmicContrast: Double?
    var editFilmicLatitude: Double?
    var editFilmicSaturation: Double?
    var editFilmicBalance: Double?

    var editColorBalanceEnabled: Bool
    var editColorBalanceGlobalY: Double?
    var editColorBalanceGlobalC: Double?
    var editColorBalanceGlobalH: Double?
    var editColorBalanceShadowsY: Double?
    var editColorBalanceShadowsC: Double?
    var editColorBalanceShadowsH: Double?
    var editColorBalanceMidtonesY: Double?
    var editColorBalanceMidtonesC: Double?
    var editColorBalanceMidtonesH: Double?
    var editColorBalanceHighlightsY: Double?
    var editColorBalanceHighlightsC: Double?
    var editColorBalanceHighlightsH: Double?
    var editColorBalanceContrast: Double?
    var editColorBalanceVibrance: Double?
    var editColorBalanceChromaGlobal: Double?

    var editRGBCurveEnabled: Bool
    var editRGBCurvePoints: [Double]?
    var editRGBCurvePreserveColors: Bool?

    var editColorZonesEnabled: Bool
    var editColorZonesLightnessPoints: [Double]?
    var editColorZonesChromaPoints: [Double]?
    var editColorZonesHuePoints: [Double]?

    var editLUT3DEnabled: Bool
    var lut3DData: Data?
    var lut3DSize: Int?
    var lut3DTitle: String?
    var lut3DIntensity: Double?

    var maskData: Data?

    init(capturing stage: Stage) {
        editDehazeAmount = stage.editDehazeAmount

        editFilmicEnabled = stage.editFilmicEnabled
        editFilmicWhitePointSource = stage.editFilmicWhitePointSource
        editFilmicBlackPointSource = stage.editFilmicBlackPointSource
        editFilmicContrast = stage.editFilmicContrast
        editFilmicLatitude = stage.editFilmicLatitude
        editFilmicSaturation = stage.editFilmicSaturation
        editFilmicBalance = stage.editFilmicBalance

        editColorBalanceEnabled = stage.editColorBalanceEnabled
        editColorBalanceGlobalY = stage.editColorBalanceGlobalY
        editColorBalanceGlobalC = stage.editColorBalanceGlobalC
        editColorBalanceGlobalH = stage.editColorBalanceGlobalH
        editColorBalanceShadowsY = stage.editColorBalanceShadowsY
        editColorBalanceShadowsC = stage.editColorBalanceShadowsC
        editColorBalanceShadowsH = stage.editColorBalanceShadowsH
        editColorBalanceMidtonesY = stage.editColorBalanceMidtonesY
        editColorBalanceMidtonesC = stage.editColorBalanceMidtonesC
        editColorBalanceMidtonesH = stage.editColorBalanceMidtonesH
        editColorBalanceHighlightsY = stage.editColorBalanceHighlightsY
        editColorBalanceHighlightsC = stage.editColorBalanceHighlightsC
        editColorBalanceHighlightsH = stage.editColorBalanceHighlightsH
        editColorBalanceContrast = stage.editColorBalanceContrast
        editColorBalanceVibrance = stage.editColorBalanceVibrance
        editColorBalanceChromaGlobal = stage.editColorBalanceChromaGlobal

        editRGBCurveEnabled = stage.editRGBCurveEnabled
        editRGBCurvePoints = stage.editRGBCurvePoints
        editRGBCurvePreserveColors = stage.editRGBCurvePreserveColors

        editColorZonesEnabled = stage.editColorZonesEnabled
        editColorZonesLightnessPoints = stage.editColorZonesLightnessPoints
        editColorZonesChromaPoints = stage.editColorZonesChromaPoints
        editColorZonesHuePoints = stage.editColorZonesHuePoints

        editLUT3DEnabled = stage.editLUT3DEnabled
        lut3DData = stage.lut3DData
        lut3DSize = stage.lut3DSize
        lut3DTitle = stage.lut3DTitle
        lut3DIntensity = stage.lut3DIntensity

        maskData = stage.maskData
    }

    func apply(to stage: Stage) {
        stage.editDehazeAmount = editDehazeAmount

        stage.editFilmicEnabled = editFilmicEnabled
        stage.editFilmicWhitePointSource = editFilmicWhitePointSource
        stage.editFilmicBlackPointSource = editFilmicBlackPointSource
        stage.editFilmicContrast = editFilmicContrast
        stage.editFilmicLatitude = editFilmicLatitude
        stage.editFilmicSaturation = editFilmicSaturation
        stage.editFilmicBalance = editFilmicBalance

        stage.editColorBalanceEnabled = editColorBalanceEnabled
        stage.editColorBalanceGlobalY = editColorBalanceGlobalY
        stage.editColorBalanceGlobalC = editColorBalanceGlobalC
        stage.editColorBalanceGlobalH = editColorBalanceGlobalH
        stage.editColorBalanceShadowsY = editColorBalanceShadowsY
        stage.editColorBalanceShadowsC = editColorBalanceShadowsC
        stage.editColorBalanceShadowsH = editColorBalanceShadowsH
        stage.editColorBalanceMidtonesY = editColorBalanceMidtonesY
        stage.editColorBalanceMidtonesC = editColorBalanceMidtonesC
        stage.editColorBalanceMidtonesH = editColorBalanceMidtonesH
        stage.editColorBalanceHighlightsY = editColorBalanceHighlightsY
        stage.editColorBalanceHighlightsC = editColorBalanceHighlightsC
        stage.editColorBalanceHighlightsH = editColorBalanceHighlightsH
        stage.editColorBalanceContrast = editColorBalanceContrast
        stage.editColorBalanceVibrance = editColorBalanceVibrance
        stage.editColorBalanceChromaGlobal = editColorBalanceChromaGlobal

        stage.editRGBCurveEnabled = editRGBCurveEnabled
        stage.editRGBCurvePoints = editRGBCurvePoints
        stage.editRGBCurvePreserveColors = editRGBCurvePreserveColors

        stage.editColorZonesEnabled = editColorZonesEnabled
        stage.editColorZonesLightnessPoints = editColorZonesLightnessPoints
        stage.editColorZonesChromaPoints = editColorZonesChromaPoints
        stage.editColorZonesHuePoints = editColorZonesHuePoints

        stage.editLUT3DEnabled = editLUT3DEnabled
        stage.lut3DData = lut3DData
        stage.lut3DSize = lut3DSize
        stage.lut3DTitle = lut3DTitle
        stage.lut3DIntensity = lut3DIntensity

        stage.maskData = maskData
    }
}

extension StageFieldSnapshot {
    /// Which modules differ between `self` and `other` — used only for `EditHistory`'s
    /// human-readable history-list labels (`EditSnapshot.changeLabel(from:to:)`), never to decide
    /// what to restore.
    func changedModules(from other: StageFieldSnapshot) -> Set<String> {
        var changed: Set<String> = []
        if editDehazeAmount != other.editDehazeAmount {
            changed.insert("Dehaze")
        }
        if editFilmicEnabled != other.editFilmicEnabled || editFilmicWhitePointSource != other.editFilmicWhitePointSource
            || editFilmicBlackPointSource != other.editFilmicBlackPointSource || editFilmicContrast != other.editFilmicContrast
            || editFilmicLatitude != other.editFilmicLatitude || editFilmicSaturation != other.editFilmicSaturation
            || editFilmicBalance != other.editFilmicBalance {
            changed.insert("Filmic RGB")
        }
        if editColorBalanceEnabled != other.editColorBalanceEnabled
            || editColorBalanceGlobalY != other.editColorBalanceGlobalY || editColorBalanceGlobalC != other.editColorBalanceGlobalC
            || editColorBalanceGlobalH != other.editColorBalanceGlobalH || editColorBalanceShadowsY != other.editColorBalanceShadowsY
            || editColorBalanceShadowsC != other.editColorBalanceShadowsC || editColorBalanceShadowsH != other.editColorBalanceShadowsH
            || editColorBalanceMidtonesY != other.editColorBalanceMidtonesY || editColorBalanceMidtonesC != other.editColorBalanceMidtonesC
            || editColorBalanceMidtonesH != other.editColorBalanceMidtonesH || editColorBalanceHighlightsY != other.editColorBalanceHighlightsY
            || editColorBalanceHighlightsC != other.editColorBalanceHighlightsC || editColorBalanceHighlightsH != other.editColorBalanceHighlightsH
            || editColorBalanceContrast != other.editColorBalanceContrast || editColorBalanceVibrance != other.editColorBalanceVibrance
            || editColorBalanceChromaGlobal != other.editColorBalanceChromaGlobal {
            changed.insert("Color Balance RGB")
        }
        if editRGBCurveEnabled != other.editRGBCurveEnabled || editRGBCurvePoints != other.editRGBCurvePoints
            || editRGBCurvePreserveColors != other.editRGBCurvePreserveColors {
            changed.insert("RGB Curve")
        }
        if editColorZonesEnabled != other.editColorZonesEnabled || editColorZonesLightnessPoints != other.editColorZonesLightnessPoints
            || editColorZonesChromaPoints != other.editColorZonesChromaPoints || editColorZonesHuePoints != other.editColorZonesHuePoints {
            changed.insert("Color Zones")
        }
        if editLUT3DEnabled != other.editLUT3DEnabled || lut3DData != other.lut3DData || lut3DSize != other.lut3DSize
            || lut3DTitle != other.lut3DTitle || lut3DIntensity != other.lut3DIntensity {
            changed.insert("Film Simulation")
        }
        if maskData != other.maskData {
            changed.insert("Mask")
        }
        return changed
    }
}
