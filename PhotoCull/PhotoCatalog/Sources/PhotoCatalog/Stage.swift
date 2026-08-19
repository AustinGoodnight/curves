import Foundation
import SwiftData

/// Which of the three (eventually four, once masking lands) roles a `Stage` plays. `.single` and
/// `.scene` are structural — every `PhotoAsset`/`PhotoScene` has exactly one, created alongside
/// its owner and never deleted or renamed. `.custom` stages are freely added/removed/renamed by
/// the user.
public enum StageKind: Int, Codable, Sendable {
    case single = 0
    case scene = 1
    case custom = 2
}

/// One independently-editable, non-destructive set of tone/color adjustments. A photo's rendered
/// result is always the *composite* of every enabled stage that applies to it, applied in a fixed
/// order (scene stage, then the photo's own single stage, then its custom stages by
/// `sortIndex`) — see `activeStageStack(for:)` in the app target's `EditorParameters.swift`.
/// Selecting a stage in the editor only changes which stage's own values the controls show
/// ("blank slate" editing); it never changes what's rendered.
///
/// Exactly one of `asset`/`scene` is set: `.single`/`.custom` stages are owned by a `PhotoAsset`
/// (`asset`), the one shared `.scene` stage is owned by a `PhotoScene` (`scene`) and applies to
/// every photo in it.
///
/// Holds the four *stackable* kernel-module parameter groups that used to live directly on
/// `PhotoAsset` (Filmic RGB, Color Balance RGB, RGB Curve, Color Zones) — see each field's doc
/// comment there for the original rationale, unchanged by the move. Exposure/white-balance/
/// sharpness stay on `PhotoAsset` itself rather than becoming per-stage: those are native
/// `CIRAWFilter` inputs applied once during RAW decode, before any stage's kernel passes run, so
/// they can't be meaningfully stacked per-stage the way the four `CIColorKernel` modules can.
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

    /// Reserved for future region/brush masking — `nil` means the stage applies to the whole
    /// image, matching every other module's "nil = no-op" convention in this codebase.
    public var maskData: Data?

    public var editFilmicEnabled: Bool = true
    public var editFilmicWhitePointSource: Double?
    public var editFilmicBlackPointSource: Double?
    public var editFilmicContrast: Double?
    public var editFilmicLatitude: Double?
    public var editFilmicSaturation: Double?
    public var editFilmicBalance: Double?

    public var editColorBalanceEnabled: Bool = true
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
    public var editColorBalanceContrast: Double?
    public var editColorBalanceVibrance: Double?
    public var editColorBalanceChromaGlobal: Double?

    public var editRGBCurveEnabled: Bool = true
    public var editRGBCurvePoints: [Double]?
    public var editRGBCurvePreserveColors: Bool?

    public var editColorZonesEnabled: Bool = true
    public var editColorZonesLightnessPoints: [Double]?
    public var editColorZonesChromaPoints: [Double]?
    public var editColorZonesHuePoints: [Double]?

    public var kind: StageKind {
        get { StageKind(rawValue: kindRaw) ?? .custom }
        set { kindRaw = newValue.rawValue }
    }

    public init(kind: StageKind, name: String, asset: PhotoAsset? = nil, scene: PhotoScene? = nil, sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.isEnabled = true
        self.createdDate = Date()
        self.sortIndex = sortIndex
        self.asset = asset
        self.scene = scene
    }
}
