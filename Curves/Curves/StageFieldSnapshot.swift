import Foundation
import PhotoCatalog
import SwiftData

/// A full copy of every user-editable field on a `Stage` (every module's values plus its mask) —
/// the shared building block for both `EditHistory` (in-memory undo/redo diffing, hence
/// `Equatable`) and `AssetVersionSnapshot` (persisted named versions, hence `Codable`). Field list
/// mirrors `Stage.swift` exactly; keep the two in sync when a module gains/loses a field.
struct StageFieldSnapshot: Codable, Equatable, Sendable {
    var editDehazeAmount: Double?

    var editFilmicEnabled: Bool
    var editFilmicWhitePointSource: Double?
    var editFilmicBlackPointSource: Double?
    var editFilmicContrast: Double?
    var editFilmicLatitude: Double?
    var editFilmicSaturation: Double?
    var editFilmicBalance: Double?

    var editAgXEnabled: Bool
    var editAgXWhitePointSource: Double?
    var editAgXBlackPointSource: Double?
    var editAgXContrast: Double?
    var editAgXSlope: Double?
    var editAgXLift: Double?
    var editAgXBrightness: Double?
    var editAgXSaturation: Double?
    var editAgXHueMix: Double?

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
    var editColorBalanceGlobalOff: Bool?
    var editColorBalanceShadowsOff: Bool?
    var editColorBalanceMidtonesOff: Bool?
    var editColorBalanceHighlightsOff: Bool?
    var editColorBalanceContrast: Double?
    var editColorBalanceVibrance: Double?
    var editColorBalanceChromaGlobal: Double?

    var editRGBCurveEnabled: Bool
    var editRGBCurvePoints: [Double]?
    var editRGBCurvePreserveColors: Bool?
    var editRGBCurveBlackLift: Double?
    var editRGBCurve2Points: [Double]?

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

    var gradientStartX: Double?
    var gradientStartY: Double?
    var gradientEndX: Double?
    var gradientEndY: Double?
    var gradientRadius: Double?
    var gradientFeather: Double?
    var gradientInverted: Bool?

    var colorRangeRed: Double?
    var colorRangeGreen: Double?
    var colorRangeBlue: Double?
    var colorRangeThreshold: Double?
    var colorRangeFeather: Double?
    var colorRangeInverted: Bool?

    init(capturing stage: Stage) {
        editDehazeAmount = stage.editDehazeAmount

        editFilmicEnabled = stage.editFilmicEnabled
        editFilmicWhitePointSource = stage.editFilmicWhitePointSource
        editFilmicBlackPointSource = stage.editFilmicBlackPointSource
        editFilmicContrast = stage.editFilmicContrast
        editFilmicLatitude = stage.editFilmicLatitude
        editFilmicSaturation = stage.editFilmicSaturation
        editFilmicBalance = stage.editFilmicBalance

        editAgXEnabled = stage.editAgXEnabled
        editAgXWhitePointSource = stage.editAgXWhitePointSource
        editAgXBlackPointSource = stage.editAgXBlackPointSource
        editAgXContrast = stage.editAgXContrast
        editAgXSlope = stage.editAgXSlope
        editAgXLift = stage.editAgXLift
        editAgXBrightness = stage.editAgXBrightness
        editAgXSaturation = stage.editAgXSaturation
        editAgXHueMix = stage.editAgXHueMix

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
        editColorBalanceGlobalOff = stage.editColorBalanceGlobalOff
        editColorBalanceShadowsOff = stage.editColorBalanceShadowsOff
        editColorBalanceMidtonesOff = stage.editColorBalanceMidtonesOff
        editColorBalanceHighlightsOff = stage.editColorBalanceHighlightsOff
        editColorBalanceContrast = stage.editColorBalanceContrast
        editColorBalanceVibrance = stage.editColorBalanceVibrance
        editColorBalanceChromaGlobal = stage.editColorBalanceChromaGlobal

        editRGBCurveEnabled = stage.editRGBCurveEnabled
        editRGBCurvePoints = stage.editRGBCurvePoints
        editRGBCurvePreserveColors = stage.editRGBCurvePreserveColors
        editRGBCurveBlackLift = stage.editRGBCurveBlackLift
        editRGBCurve2Points = stage.editRGBCurve2Points

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

        gradientStartX = stage.gradientStartX
        gradientStartY = stage.gradientStartY
        gradientEndX = stage.gradientEndX
        gradientEndY = stage.gradientEndY
        gradientRadius = stage.gradientRadius
        gradientFeather = stage.gradientFeather
        gradientInverted = stage.gradientInverted

        colorRangeRed = stage.colorRangeRed
        colorRangeGreen = stage.colorRangeGreen
        colorRangeBlue = stage.colorRangeBlue
        colorRangeThreshold = stage.colorRangeThreshold
        colorRangeFeather = stage.colorRangeFeather
        colorRangeInverted = stage.colorRangeInverted
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

        stage.editAgXEnabled = editAgXEnabled
        stage.editAgXWhitePointSource = editAgXWhitePointSource
        stage.editAgXBlackPointSource = editAgXBlackPointSource
        stage.editAgXContrast = editAgXContrast
        stage.editAgXSlope = editAgXSlope
        stage.editAgXLift = editAgXLift
        stage.editAgXBrightness = editAgXBrightness
        stage.editAgXSaturation = editAgXSaturation
        stage.editAgXHueMix = editAgXHueMix

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
        stage.editColorBalanceGlobalOff = editColorBalanceGlobalOff
        stage.editColorBalanceShadowsOff = editColorBalanceShadowsOff
        stage.editColorBalanceMidtonesOff = editColorBalanceMidtonesOff
        stage.editColorBalanceHighlightsOff = editColorBalanceHighlightsOff
        stage.editColorBalanceContrast = editColorBalanceContrast
        stage.editColorBalanceVibrance = editColorBalanceVibrance
        stage.editColorBalanceChromaGlobal = editColorBalanceChromaGlobal

        stage.editRGBCurveEnabled = editRGBCurveEnabled
        stage.editRGBCurvePoints = editRGBCurvePoints
        stage.editRGBCurvePreserveColors = editRGBCurvePreserveColors
        stage.editRGBCurveBlackLift = editRGBCurveBlackLift
        stage.editRGBCurve2Points = editRGBCurve2Points

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

        stage.gradientStartX = gradientStartX
        stage.gradientStartY = gradientStartY
        stage.gradientEndX = gradientEndX
        stage.gradientEndY = gradientEndY
        stage.gradientRadius = gradientRadius
        stage.gradientFeather = gradientFeather
        stage.gradientInverted = gradientInverted

        stage.colorRangeRed = colorRangeRed
        stage.colorRangeGreen = colorRangeGreen
        stage.colorRangeBlue = colorRangeBlue
        stage.colorRangeThreshold = colorRangeThreshold
        stage.colorRangeFeather = colorRangeFeather
        stage.colorRangeInverted = colorRangeInverted
    }
}

extension StageFieldSnapshot {
    /// Applies whichever `Preset` has `isDefault` set (see `StagesSidebarView.saveAsDefaultStage(_:)`)
    /// onto `asset`'s `.single` stage, plus the preset's exposure/white balance onto `asset` itself
    /// (`Preset.applyAssetFields(to:)`) — called once per newly-imported photo from
    /// `ContentView.performImport`. A silent no-op when no default has ever been saved, or the
    /// stored snapshot somehow fails to decode; import should never fail or block on this.
    static func applyDefaultIfAvailable(to asset: PhotoAsset, context: ModelContext) {
        var descriptor = FetchDescriptor<Preset>(predicate: #Predicate { $0.isDefault })
        descriptor.fetchLimit = 1
        guard let preset = try? context.fetch(descriptor).first,
              let snapshot = try? JSONDecoder().decode(StageFieldSnapshot.self, from: preset.snapshotData) else { return }
        snapshot.apply(to: asset.singleStage)
        preset.applyAssetFields(to: asset)
    }

    /// Approximates "the combined look of every active stage" as a single flat snapshot, for the
    /// "Save All Stages as Preset" action (`StagesSidebarView.savePreset()`). This is **not** a
    /// mathematically exact flatten of the composited kernel stack — that's not generally possible,
    /// since curves/zones/LUTs don't compose by simple field overwrite — it's a practical
    /// approximation: walk `stages` in their actual composite order (scene, then single, then
    /// customs by `sortIndex` — see `activeStageStack(for:)`) and, per field, let the topmost stage
    /// that actually set a value win. The per-module "Enabled" bypass flags are ANDed instead of
    /// overridden, so a module any stage in the stack explicitly turned off stays off in the merged
    /// preset, rather than a later, untouched stage's default `true` silently reviving it.
    /// `maskData` (and the gradient geometry that can accompany it) is dropped entirely — masks are
    /// spatial and stage-specific, so carrying one over from an arbitrary stage in the merge would
    /// misapply it; a merged preset always covers the whole image. `stages` must be non-empty
    /// (callers gate the triggering button on that).
    init(mergingActiveStages stages: [Stage]) {
        precondition(!stages.isEmpty, "mergingActiveStages requires at least one stage")
        var result = StageFieldSnapshot(capturing: stages[0])
        for stage in stages.dropFirst() {
            let next = StageFieldSnapshot(capturing: stage)
            result.editDehazeAmount = next.editDehazeAmount ?? result.editDehazeAmount

            result.editFilmicEnabled = result.editFilmicEnabled && next.editFilmicEnabled
            result.editFilmicWhitePointSource = next.editFilmicWhitePointSource ?? result.editFilmicWhitePointSource
            result.editFilmicBlackPointSource = next.editFilmicBlackPointSource ?? result.editFilmicBlackPointSource
            result.editFilmicContrast = next.editFilmicContrast ?? result.editFilmicContrast
            result.editFilmicLatitude = next.editFilmicLatitude ?? result.editFilmicLatitude
            result.editFilmicSaturation = next.editFilmicSaturation ?? result.editFilmicSaturation
            result.editFilmicBalance = next.editFilmicBalance ?? result.editFilmicBalance

            result.editAgXEnabled = result.editAgXEnabled && next.editAgXEnabled
            result.editAgXWhitePointSource = next.editAgXWhitePointSource ?? result.editAgXWhitePointSource
            result.editAgXBlackPointSource = next.editAgXBlackPointSource ?? result.editAgXBlackPointSource
            result.editAgXContrast = next.editAgXContrast ?? result.editAgXContrast
            result.editAgXSlope = next.editAgXSlope ?? result.editAgXSlope
            result.editAgXLift = next.editAgXLift ?? result.editAgXLift
            result.editAgXBrightness = next.editAgXBrightness ?? result.editAgXBrightness
            result.editAgXSaturation = next.editAgXSaturation ?? result.editAgXSaturation
            result.editAgXHueMix = next.editAgXHueMix ?? result.editAgXHueMix

            result.editColorBalanceEnabled = result.editColorBalanceEnabled && next.editColorBalanceEnabled
            result.editColorBalanceGlobalY = next.editColorBalanceGlobalY ?? result.editColorBalanceGlobalY
            result.editColorBalanceGlobalC = next.editColorBalanceGlobalC ?? result.editColorBalanceGlobalC
            result.editColorBalanceGlobalH = next.editColorBalanceGlobalH ?? result.editColorBalanceGlobalH
            result.editColorBalanceShadowsY = next.editColorBalanceShadowsY ?? result.editColorBalanceShadowsY
            result.editColorBalanceShadowsC = next.editColorBalanceShadowsC ?? result.editColorBalanceShadowsC
            result.editColorBalanceShadowsH = next.editColorBalanceShadowsH ?? result.editColorBalanceShadowsH
            result.editColorBalanceMidtonesY = next.editColorBalanceMidtonesY ?? result.editColorBalanceMidtonesY
            result.editColorBalanceMidtonesC = next.editColorBalanceMidtonesC ?? result.editColorBalanceMidtonesC
            result.editColorBalanceMidtonesH = next.editColorBalanceMidtonesH ?? result.editColorBalanceMidtonesH
            result.editColorBalanceHighlightsY = next.editColorBalanceHighlightsY ?? result.editColorBalanceHighlightsY
            result.editColorBalanceHighlightsC = next.editColorBalanceHighlightsC ?? result.editColorBalanceHighlightsC
            result.editColorBalanceHighlightsH = next.editColorBalanceHighlightsH ?? result.editColorBalanceHighlightsH
            result.editColorBalanceGlobalOff = next.editColorBalanceGlobalOff ?? result.editColorBalanceGlobalOff
            result.editColorBalanceShadowsOff = next.editColorBalanceShadowsOff ?? result.editColorBalanceShadowsOff
            result.editColorBalanceMidtonesOff = next.editColorBalanceMidtonesOff ?? result.editColorBalanceMidtonesOff
            result.editColorBalanceHighlightsOff = next.editColorBalanceHighlightsOff ?? result.editColorBalanceHighlightsOff
            result.editColorBalanceContrast = next.editColorBalanceContrast ?? result.editColorBalanceContrast
            result.editColorBalanceVibrance = next.editColorBalanceVibrance ?? result.editColorBalanceVibrance
            result.editColorBalanceChromaGlobal = next.editColorBalanceChromaGlobal ?? result.editColorBalanceChromaGlobal

            result.editRGBCurveEnabled = result.editRGBCurveEnabled && next.editRGBCurveEnabled
            result.editRGBCurvePoints = next.editRGBCurvePoints ?? result.editRGBCurvePoints
            result.editRGBCurvePreserveColors = next.editRGBCurvePreserveColors ?? result.editRGBCurvePreserveColors
            result.editRGBCurveBlackLift = next.editRGBCurveBlackLift ?? result.editRGBCurveBlackLift
            result.editRGBCurve2Points = next.editRGBCurve2Points ?? result.editRGBCurve2Points

            result.editColorZonesEnabled = result.editColorZonesEnabled && next.editColorZonesEnabled
            result.editColorZonesLightnessPoints = next.editColorZonesLightnessPoints ?? result.editColorZonesLightnessPoints
            result.editColorZonesChromaPoints = next.editColorZonesChromaPoints ?? result.editColorZonesChromaPoints
            result.editColorZonesHuePoints = next.editColorZonesHuePoints ?? result.editColorZonesHuePoints

            result.editLUT3DEnabled = result.editLUT3DEnabled && next.editLUT3DEnabled
            result.lut3DData = next.lut3DData ?? result.lut3DData
            result.lut3DSize = next.lut3DSize ?? result.lut3DSize
            result.lut3DTitle = next.lut3DTitle ?? result.lut3DTitle
            result.lut3DIntensity = next.lut3DIntensity ?? result.lut3DIntensity
        }
        result.maskData = nil
        result.gradientStartX = nil
        result.gradientStartY = nil
        result.gradientEndX = nil
        result.gradientEndY = nil
        result.gradientRadius = nil
        result.gradientFeather = nil
        result.gradientInverted = nil
        result.colorRangeRed = nil
        result.colorRangeGreen = nil
        result.colorRangeBlue = nil
        result.colorRangeThreshold = nil
        result.colorRangeFeather = nil
        result.colorRangeInverted = nil
        self = result
    }

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
        if editAgXEnabled != other.editAgXEnabled || editAgXWhitePointSource != other.editAgXWhitePointSource
            || editAgXBlackPointSource != other.editAgXBlackPointSource || editAgXContrast != other.editAgXContrast
            || editAgXSlope != other.editAgXSlope || editAgXLift != other.editAgXLift
            || editAgXBrightness != other.editAgXBrightness || editAgXSaturation != other.editAgXSaturation
            || editAgXHueMix != other.editAgXHueMix {
            changed.insert("AgX")
        }
        if editColorBalanceEnabled != other.editColorBalanceEnabled
            || editColorBalanceGlobalY != other.editColorBalanceGlobalY || editColorBalanceGlobalC != other.editColorBalanceGlobalC
            || editColorBalanceGlobalH != other.editColorBalanceGlobalH || editColorBalanceShadowsY != other.editColorBalanceShadowsY
            || editColorBalanceShadowsC != other.editColorBalanceShadowsC || editColorBalanceShadowsH != other.editColorBalanceShadowsH
            || editColorBalanceMidtonesY != other.editColorBalanceMidtonesY || editColorBalanceMidtonesC != other.editColorBalanceMidtonesC
            || editColorBalanceMidtonesH != other.editColorBalanceMidtonesH || editColorBalanceHighlightsY != other.editColorBalanceHighlightsY
            || editColorBalanceHighlightsC != other.editColorBalanceHighlightsC || editColorBalanceHighlightsH != other.editColorBalanceHighlightsH
            || editColorBalanceGlobalOff != other.editColorBalanceGlobalOff || editColorBalanceShadowsOff != other.editColorBalanceShadowsOff || editColorBalanceMidtonesOff != other.editColorBalanceMidtonesOff || editColorBalanceHighlightsOff != other.editColorBalanceHighlightsOff
            || editColorBalanceContrast != other.editColorBalanceContrast || editColorBalanceVibrance != other.editColorBalanceVibrance
            || editColorBalanceChromaGlobal != other.editColorBalanceChromaGlobal {
            changed.insert("Color Balance RGB")
        }
        if editRGBCurveEnabled != other.editRGBCurveEnabled || editRGBCurvePoints != other.editRGBCurvePoints
            || editRGBCurvePreserveColors != other.editRGBCurvePreserveColors || editRGBCurveBlackLift != other.editRGBCurveBlackLift
            || editRGBCurve2Points != other.editRGBCurve2Points {
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
        if maskData != other.maskData || gradientStartX != other.gradientStartX || gradientStartY != other.gradientStartY
            || gradientEndX != other.gradientEndX || gradientEndY != other.gradientEndY || gradientRadius != other.gradientRadius
            || gradientFeather != other.gradientFeather || gradientInverted != other.gradientInverted
            || colorRangeRed != other.colorRangeRed || colorRangeGreen != other.colorRangeGreen || colorRangeBlue != other.colorRangeBlue
            || colorRangeThreshold != other.colorRangeThreshold || colorRangeFeather != other.colorRangeFeather
            || colorRangeInverted != other.colorRangeInverted {
            changed.insert("Mask")
        }
        return changed
    }
}
