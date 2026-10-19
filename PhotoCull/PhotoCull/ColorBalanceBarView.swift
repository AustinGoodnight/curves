import SwiftUI
import SwiftData
import PhotoCatalog
import RawEngine

/// White Balance + Color Balance RGB (4 wheels) side by side with Color Zones EQ — two sibling
/// panels, each with its own reset/enabled-toggle, rather than one nested under the other,
/// separated by spacing alone (no `Divider` — see the `.fixedSize` note on `body` for why).
/// Every column shares the same three rows — section header (`colorZonesToolbarHeight`), per-control
/// title row (`controlSubtitleHeight`), then a content slot `contentSlotHeight` tall with the control
/// centered in it — so titles, sub-titles, and control centers line up across the whole bar by
/// construction rather than by per-section alignment offsets.
/// Everything here adjusts color rather than tone, grouped together regardless of which module
/// (native `CIRAWFilter` input vs. `ColorBalanceRGBParameters` vs. `ColorZonesParameters`)
/// actually produces it. A genuine separate `View` type from `EditorSidebarView` so dragging a
/// wheel, fader, or the Color Zones curve doesn't re-diff the Exposure/Filmic/RGB Curve sidebar,
/// and vice versa. See `EditorRenderCoordinator`'s doc comment for why that split matters, and
/// `ColorWheelHost` for the further per-wheel split.
///
/// Lives in a full-width bottom bar rather than the sidebar — the 4 wheels read much better with
/// room to breathe in a single row (matches how DaVinci Resolve lays its own color wheels out)
/// than cramped into `EditorSidebarView`'s resizable ~320-640pt column.
struct ColorBalanceBarView: View {
    let asset: PhotoAsset
    /// The stage currently selected in `StagesSidebarView` — the color wheels, Chroma/Vibrance/
    /// Saturation faders, and Color Zones curve below all read/write this stage's own values,
    /// blank-slate per stage. Temp/Tint stay bound to `asset` directly since they're base params
    /// shared by the whole composite, not per-stage.
    let stage: Stage
    /// Cached active stage list, threaded through to `scheduleRender` — see
    /// `EditorView.activeStages`'s doc comment for why this isn't recomputed here.
    let activeStages: [Stage]
    let coordinator: EditorRenderCoordinator
    let history: EditHistory
    let wheelDiameter: CGFloat
    /// Owned by `EditorView` (its image pane is what receives the click) — the WB group's
    /// eyedropper button just turns picking on/off. See `EditorView.pickWhiteBalance(at:)`.
    @Binding var isPickingWhiteBalance: Bool
    /// Owned by `EditorView` — the Film Simulation header's Browse button opens `LUTBrowserSidebar`
    /// in place of the right sidebar's controls.
    @Binding var isBrowsingLUTs: Bool

    @Environment(ColorSchemeStore.self) private var uiColors

    /// Set in Settings (`SettingsView`) — whether the WB group below renders as the classic
    /// Temp/Tint stripe faders or the single `WhiteBalancePad`. Not per-photo state.
    @AppStorage(AppSettingsKey.whiteBalanceControlStyle) private var whiteBalanceStyle: WhiteBalanceControlStyle = .classic
    @AppStorage(AppSettingsKey.colorWheelStyle) private var wheelStyle: ColorWheelStyle = .spectrum
    @AppStorage(AppSettingsKey.hueGraphStyle) private var hueGraphStyle: HueGraphStyle = .centerStripe
    @AppStorage(AppSettingsKey.hueGraphBackground) private var hueGraphBackground: HueGraphBackground = .outline
    @AppStorage(AppSettingsKey.developerMode) private var developerMode = false

    /// Which of the 3 color-zones curves is currently shown in the EQ graph. 2 (hue) matches
    /// darktable's own default "select by" channel.
    @State private var colorZonesChannel = 2
    /// Set when `LUT3DLoader` throws while loading a `.cube` file from the LUT folder, surfaced via `.alert`; `nil`
    /// means no error is showing.
    @State private var lut3DImportError: String?

    /// Height of every section's header row (WB, Color Wheels, Color Zones, Film Simulation) —
    /// shared so the section titles sit on one line across the bar.
    private let colorZonesToolbarHeight: CGFloat = 24

    /// Height of the slot each column's main control is centered in — the color wheel's own
    /// bounding box (dial + luminance arc), the tallest of them. The WB pad and Color Zones graph
    /// are centered in a slot this tall so their centers land on the wheels' centers.
    private var contentSlotHeight: CGFloat {
        ColorWheelControl.containerSize(forDiameter: wheelDiameter)
    }

    var body: some View {
        // Wrapped in a horizontal `ScrollView` — every section below (`colorBalanceSection`,
        // `colorZonesSection`, `lut3DSection`) carries its own `.fixedSize(horizontal: true)`
        // (see each one's doc comment for why: without it, an idle `Spacer` would let it greedily
        // expand and shove its neighbor sideways when the window has extra width). The flip side of
        // "never compress below ideal" is "never compress at all" — with this `HStack` sitting
        // directly in `EditorView`'s outer `VStack` (full window width, not constrained by the
        // `HSplitView` above it), that made this bar's full natural width — 4 wheels, Color Zones'
        // graph, every fader — an unconditional floor under the *entire window's* minimum width,
        // regardless of anything else on screen. A `ScrollView` reports a small, flexible width to
        // its parent and lets the bar's true content overflow into horizontal scrolling instead —
        // the individual sections keep their tuned "don't compress, don't be shoved" behavior
        // unchanged, it's just no longer the window's own problem when there isn't room for all of
        // them at once.
        //
        // `.fixedSize(vertical:)` pins this to its own ideal content height regardless of what
        // the parent `VStack` proposes — without it, this `HStack` was greedily claiming leftover
        // window height instead of leaving it to `EditorView`'s `HSplitView`, leaving a dead
        // `sidebarBackground` gap below the actual content once a `Divider` (since removed, but
        // this guard is cheap insurance against the same failure mode returning) was in the mix.
        //
        // Plain `.top` is enough: every section has the same fixed-height rows (see the type's doc
        // comment), so aligning their tops aligns everything below.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 32) {
                colorBalanceSection
                colorZonesSection
                lut3DSection
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 8)
        }
        .toggleStyle(.switch)
        .disabled(!coordinator.isReady)
        .background(uiColors.sidebarBackground)
    }

    /// No reset button for Color Balance RGB as a whole (each wheel and fader already double-
    /// click-resets individually, so a module-wide reset never earned its keep). Its three
    /// sub-groups (white balance, the four wheels, chroma/vibrance/saturation) each get their own
    /// small label plus a `StoplightToggle` via `titledGroup`, so the row doesn't read as one
    /// undifferentiated wall of controls and each cluster can be bypassed independently — see
    /// `Stage.editColorWheelsEnabled`/`editBalanceEnabled` and `PhotoAsset.editWhiteBalanceEnabled`.
    ///
    /// `.fixedSize(horizontal:)` pins this to its own ideal content width — without it, a
    /// `Spacer()`-bearing row here would make this whole section report an unbounded/flexible
    /// width upward to `body`'s `HStack`, the same failure mode as the `Divider` height bug noted
    /// on `body` but on the width axis: in a wide (e.g. full-screen) window this section would
    /// eat the leftover width meant for the trailing `Spacer`, shoving `colorZonesSection` far to
    /// the right with a dead gap in between.
    private var colorBalanceSection: some View {
        HStack(alignment: .top, spacing: 28) {
            titledGroup("WB", enabled: assetBoolBind(\.editWhiteBalanceEnabled), accessory: whiteBalanceEyedropper) {
                HStack(alignment: .top, spacing: 16) {
                switch whiteBalanceStyle {
                case .classic:
                    WhiteBalanceFaderPair(
                        temperature: whiteBalanceTemperature, tint: whiteBalanceTint, axes: whiteBalanceAxes, slotHeight: contentSlotHeight
                    )
                case .xy:
                    WhiteBalancePad(
                        temperature: whiteBalanceTemperature, tint: whiteBalanceTint, axes: whiteBalanceAxes, slotHeight: contentSlotHeight
                    )
                }
                }
            }
            .contextMenu {
                Button("Copy WB to Every Photo in Scene") { copyWhiteBalanceToScene() }
                    .disabled(asset.scene == nil)
            }

            titledGroup("Color Wheels", enabled: stageBoolBind(\.editColorWheelsEnabled)) {
                // Wheel edge = darktable's own GUI "soft range" per zone, not the parameter's
                // hard 0...1 max — see ColorWheelControl's doc comment.
                // Negative: each wheel's own bounding box now includes empty margin on all
                // sides to fit the luminance arc (which only actually draws on the right side),
                // so naive positive HStack spacing double-counts that margin between wheels and
                // reads as a huge gap. This pulls the boxes back together to what's visually a
                // normal gap between the arcs and the next wheel, then opens it up by 10pt more
                // than the tightest fit. It's a constant regardless of `wheelDiameter` — the
                // per-wheel margin `wheelDiameter` bakes in (`ColorWheelControl.containerSize -
                // diameter`) doesn't depend on diameter.
                HStack(spacing: -10) {
                    wheel(
                        "Global",
                        y: \.editColorBalanceGlobalY, c: \.editColorBalanceGlobalC, h: \.editColorBalanceGlobalH, off: \.editColorBalanceGlobalOff,
                        maxChroma: 0.01, yRange: -0.05...0.05
                    )
                    wheel(
                        "Shadows",
                        y: \.editColorBalanceShadowsY, c: \.editColorBalanceShadowsC, h: \.editColorBalanceShadowsH, off: \.editColorBalanceShadowsOff,
                        maxChroma: 0.5, yRange: -1...1
                    )
                    wheel(
                        "Midtones",
                        y: \.editColorBalanceMidtonesY, c: \.editColorBalanceMidtonesC, h: \.editColorBalanceMidtonesH, off: \.editColorBalanceMidtonesOff,
                        maxChroma: 0.1, yRange: -0.25...0.25
                    )
                    wheel(
                        "Highlights",
                        y: \.editColorBalanceHighlightsY, c: \.editColorBalanceHighlightsC, h: \.editColorBalanceHighlightsH, off: \.editColorBalanceHighlightsOff,
                        maxChroma: 0.2, yRange: -0.5...0.5
                    )
                }
            }
            // Developer Mode only — swaps the wheels' face between the `ColorWheelStyle`
            // candidates, live on the real photo. Sits in the header row's empty trailing corner.
            .overlay(alignment: .topTrailing) {
                if developerMode {
                    Picker("Wheel Style", selection: $wheelStyle) {
                        ForEach(ColorWheelStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
            }

        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Wraps `content` with a section label centered above it, in a header row pinned to
    /// `colorZonesToolbarHeight` so every section's title sits on the same line. `.center`, not
    /// `.leading`: `content` (e.g. the 4-wheel row) is the widest child and defines the `VStack`'s
    /// width, and only `.center` actually centers the shorter title over the whole row.
    ///
    /// `onReset`, `enabled`, and `accessory` trail the title in that order (matching each wheel's
    /// own "title ⟲ ●" row). Each gets an equal-width invisible spacer on the title's leading side,
    /// so the title itself stays centered over `content` rather than the title+controls block
    /// being centered as a unit (which drags the title off-center to the left).
    ///
    /// `spread: true` is the full-width variant for the wide single-control sections (Color Zones,
    /// Film Simulation): title pinned leading, and `accessory`, reset, stoplight pinned trailing —
    /// stoplight last, flush with the section's right edge. Same row height either way, so the
    /// titles still share one line with the centered sections.
    private func titledGroup<Content: View>(
        _ title: String, spread: Bool = false, onReset: (() -> Void)? = nil, resetDisabled: Bool = true,
        enabled: Binding<Bool>? = nil, accessory: (some View)? = nil as EmptyView?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .center, spacing: 8) {
            if spread {
                HStack(spacing: 4) {
                    sectionTitle(title, enabled: enabled, font: .scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                        .fixedSize()
                    Spacer(minLength: 8)
                    if let accessory {
                        accessory
                    }
                    if let onReset {
                        resetButton(disabled: resetDisabled, action: onReset)
                            .frame(width: headerAccessoryWidth, height: headerAccessoryWidth)
                    }
                    if let enabled {
                        StoplightToggle(isOn: enabled)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: colorZonesToolbarHeight)
            } else {
                HStack(spacing: 4) {
                    if onReset != nil {
                        Color.clear.frame(width: headerAccessoryWidth, height: headerAccessoryWidth)
                    }
                    if enabled != nil {
                        Color.clear.frame(width: stoplightHitDiameter, height: stoplightHitDiameter)
                    }
                    if accessory != nil {
                        Color.clear.frame(width: headerAccessoryWidth, height: headerAccessoryWidth)
                    }
                    sectionTitle(title, enabled: enabled, font: .scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                    if let onReset {
                        resetButton(disabled: resetDisabled, action: onReset)
                            .frame(width: headerAccessoryWidth, height: headerAccessoryWidth)
                    }
                    if let enabled {
                        StoplightToggle(isOn: enabled)
                    }
                    if let accessory {
                        accessory
                    }
                }
                .frame(height: colorZonesToolbarHeight)
            }
            content()
        }
    }

    /// `StoplightToggle`'s own outer hit-frame width at its default `diameter` (10) — `diameter +
    /// 12`, per its own layout, not configurable from outside. `titledGroup` uses this twice: once
    /// for the toggle itself, once for the invisible balancing spacer on the title's other side.
    private let stoplightHitDiameter: CGFloat = 22

    /// Width of an optional trailing header button (`titledGroup`'s reset/`accessory`, e.g. WB's
    /// eyedropper) — balanced by an equal invisible spacer on the title's other side, same as the
    /// toggle.
    private let headerAccessoryWidth: CGFloat = 18

    private func wheel(
        _ title: String,
        y: ReferenceWritableKeyPath<Stage, Double?>,
        c: ReferenceWritableKeyPath<Stage, Double?>,
        h: ReferenceWritableKeyPath<Stage, Double?>,
        off: ReferenceWritableKeyPath<Stage, Bool?>,
        maxChroma: Double,
        yRange: ClosedRange<Double>
    ) -> some View {
        ColorWheelHost(
            title: title,
            hue: stage[keyPath: h] ?? 0,
            chroma: stage[keyPath: c] ?? 0,
            luminance: stage[keyPath: y] ?? 0,
            maxChroma: maxChroma,
            yRange: yRange,
            diameter: wheelDiameter,
            style: wheelStyle,
            isEnabled: stage[keyPath: off] != true,
            onEnabledChange: { isOn in
                stage[keyPath: off] = isOn ? nil : true
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            },
            onHueChange: { newValue in
                let hadAdjustments = colorWheelsGate.hasAdjustments()
                let hadMasterAdjustments = outerColorBalanceGate.hasAdjustments()
                stage[keyPath: h] = newValue
                syncModuleEnabled(colorWheelsGate, hadAdjustments: hadAdjustments)
                syncModuleEnabled(outerColorBalanceGate, hadAdjustments: hadMasterAdjustments)
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            },
            onChromaChange: { newValue in
                let hadAdjustments = colorWheelsGate.hasAdjustments()
                let hadMasterAdjustments = outerColorBalanceGate.hasAdjustments()
                stage[keyPath: c] = newValue
                syncModuleEnabled(colorWheelsGate, hadAdjustments: hadAdjustments)
                syncModuleEnabled(outerColorBalanceGate, hadAdjustments: hadMasterAdjustments)
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            },
            onLuminanceChange: { newValue in
                let hadAdjustments = colorWheelsGate.hasAdjustments()
                let hadMasterAdjustments = outerColorBalanceGate.hasAdjustments()
                stage[keyPath: y] = newValue
                syncModuleEnabled(colorWheelsGate, hadAdjustments: hadAdjustments)
                syncModuleEnabled(outerColorBalanceGate, hadAdjustments: hadMasterAdjustments)
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
        .equatable()
    }

    private func formattedTint(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    /// `module`, when passed, keeps that module's own bypass switch synced to whether it still has
    /// adjustments after this particular field's write — see `syncModuleEnabled`'s doc comment.
    private func bind(
        _ keyPath: ReferenceWritableKeyPath<PhotoAsset, Double?>, fallback: Double, module: ModuleGate? = nil
    ) -> Binding<Double> {
        Binding(
            get: { asset[keyPath: keyPath] ?? fallback },
            set: { newValue in
                let hadAdjustments = module?.hasAdjustments()
                asset[keyPath: keyPath] = newValue
                if let module, let hadAdjustments {
                    syncModuleEnabled(module, hadAdjustments: hadAdjustments)
                }
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
    }

    /// `masterModule`, when passed, is synced *in addition to* `module` — for the Color Wheels/
    /// Balance sub-groups, which each have their own inner bypass switch (`module`) but also need
    /// to keep the whole Color Balance RGB module's outer switch (`editColorBalanceEnabled`,
    /// `masterModule`) in sync, since `colorBalanceParameters(for:)` gates on that outer switch
    /// before even looking at the inner ones. Previously only "Contrast" (in `EditorSidebarView`,
    /// the one field with no inner sub-group of its own) synced the outer switch — dragging a wheel
    /// or a Chr/Vib/Sat slider without ever touching Contrast stored the value and moved the UI but
    /// left `editColorBalanceEnabled` false, so the render's own top-level guard silently dropped
    /// the whole module. Both gates read `hasAdjustments()` *before* the mutation, same as the
    /// single-gate case below.
    private func stageBind(
        _ keyPath: ReferenceWritableKeyPath<Stage, Double?>, fallback: Double, module: ModuleGate? = nil,
        masterModule: ModuleGate? = nil
    ) -> Binding<Double> {
        Binding(
            get: { stage[keyPath: keyPath] ?? fallback },
            set: { newValue in
                let hadAdjustments = module?.hasAdjustments()
                let hadMasterAdjustments = masterModule?.hasAdjustments()
                stage[keyPath: keyPath] = newValue
                if let module, let hadAdjustments {
                    syncModuleEnabled(module, hadAdjustments: hadAdjustments)
                }
                if let masterModule, let hadMasterAdjustments {
                    syncModuleEnabled(masterModule, hadAdjustments: hadMasterAdjustments)
                }
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
    }

    /// The WB header's eyedropper — click something white/grey in the photo to neutralize it. Lit
    /// in the accent color while picking is on.
    private var whiteBalanceEyedropper: some View {
        Button {
            isPickingWhiteBalance.toggle()
        } label: {
            Image(systemName: "eyedropper")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isPickingWhiteBalance ? uiColors.accentColor : Color.secondary)
                .frame(width: headerAccessoryWidth, height: headerAccessoryWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pick a white or neutral grey in the photo to set white balance")
    }

    private var whiteBalanceTemperature: Binding<Double> {
        bind(\.editNeutralTemperature, fallback: coordinator.renderer.defaultNeutralTemperature, module: whiteBalanceGate)
    }

    private var whiteBalanceTint: Binding<Double> {
        bind(\.editNeutralTint, fallback: coordinator.renderer.defaultNeutralTint, module: whiteBalanceGate)
    }

    private var whiteBalanceAxes: WhiteBalanceAxes {
        WhiteBalanceAxes(
            defaultTemperature: coordinator.renderer.defaultNeutralTemperature,
            defaultTint: coordinator.renderer.defaultNeutralTint
        )
    }

    private var whiteBalanceGate: ModuleGate {
        ModuleGate(hasAdjustments: { whiteBalanceHasAdjustments(asset) }, setEnabled: { asset.editWhiteBalanceEnabled = $0 })
    }

    /// Temp/Tint are asset-level, not per-`Stage` (see `Stage`'s doc comment on why they can't
    /// stack), so there's no shared "scene" copy of them the way Filmic/Color Balance/Color Zones
    /// get for free by living on `PhotoScene.stage`. This is a one-time copy — like
    /// `StagesSidebarView`'s "Save as Default Stage" — onto every other photo's own WB fields, not a
    /// live-linked source of truth: a later WB tweak on any one photo doesn't re-propagate until
    /// this is invoked again. Only the currently-open `asset` gets a fresh render scheduled — the
    /// others aren't being previewed right now, and the grid's own thumbnails are decoded straight
    /// from each file rather than reflecting slider edits, so there's nothing else to invalidate.
    private func copyWhiteBalanceToScene() {
        guard let photos = asset.scene?.photos else { return }
        for photo in photos where photo.id != asset.id {
            photo.editNeutralTemperature = asset.editNeutralTemperature
            photo.editNeutralTint = asset.editNeutralTint
            photo.editWhiteBalanceEnabled = asset.editWhiteBalanceEnabled
        }
    }

    private var colorWheelsGate: ModuleGate {
        ModuleGate(hasAdjustments: { colorWheelsHasAdjustments(stage) }, setEnabled: { stage.editColorWheelsEnabled = $0 })
    }

    /// The whole Color Balance RGB module's outer bypass switch — see `stageBind`'s
    /// `masterModule` doc comment for why the Wheels/Balance sub-groups need to sync this in
    /// addition to their own inner gate above. Matches `EditorSidebarView`'s identically-defined
    /// `colorBalanceGate` (Contrast's own gate, since Contrast has no inner sub-group).
    private var outerColorBalanceGate: ModuleGate {
        ModuleGate(hasAdjustments: { colorBalanceHasAdjustments(stage) }, setEnabled: { stage.editColorBalanceEnabled = $0 })
    }

    private var colorZonesGate: ModuleGate {
        ModuleGate(hasAdjustments: { colorZonesHasAdjustments(stage) }, setEnabled: { stage.editColorZonesEnabled = $0 })
    }

    private func stageBoolBind(_ keyPath: ReferenceWritableKeyPath<Stage, Bool>) -> Binding<Bool> {
        Binding(
            get: { stage[keyPath: keyPath] },
            set: { newValue in
                stage[keyPath: keyPath] = newValue
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
    }

    private func assetBoolBind(_ keyPath: ReferenceWritableKeyPath<PhotoAsset, Bool>) -> Binding<Bool> {
        Binding(
            get: { asset[keyPath: keyPath] },
            set: { newValue in
                asset[keyPath: keyPath] = newValue
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
    }

    /// The EQ-style color zones interface: 3 curves (lightness/chroma/hue), each a function of
    /// the pixel's own hue — a tab per curve, one graph shown at a time. A sibling panel to
    /// `colorBalanceSection`, not nested inside it — still placed next to it since both are
    /// hue-driven grading tools (see `ColorZonesParameters`'s scope note: this always operates in
    /// darktable's "select by hue" mode). Same row structure as the other columns: the "Color
    /// Zones" header (title, reset, toggle) on the section-title line, the channel tabs on the
    /// per-control title line, then the graph centered in `contentSlotHeight`.
    private var colorZonesSection: some View {
        titledGroup(
            "Color Zones",
            spread: true,
            onReset: {
                resetColorZones(stage)
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            },
            resetDisabled: !colorZonesHasAdjustments(stage),
            enabled: stageBoolBind(\.editColorZonesEnabled),
            accessory: colorZonesDeveloperPickers
        ) {
            VStack(spacing: controlSubtitleSpacing) {
                colorZonesChannelSwitcher
                    .frame(height: controlSubtitleHeight)

                CurveEditorHost(
                    points: colorZonesPoints(for: stage, colorZonesActiveKeyPath),
                    title: colorZonesChannelTitle,
                    height: colorFaderTrackHeight,
                    identityPoints: ColorZonesParameters.identityPoints,
                    maxPoints: ColorZonesKernel.maxNodes,
                    splineType: .catmullRom,
                    referenceIsFlat: true,
                    histogram: coordinator.hueHistogram,
                    showHueAxis: true,
                    showHeader: false,
                    topCornersSquared: false,
                    lineColor: .white,
                    showGrid: true,
                    hueStyle: hueGraphStyle,
                    hueBackground: hueGraphBackground,
                    onPointsChange: { newPoints in
                        let hadAdjustments = colorZonesGate.hasAdjustments()
                        let keyPath = colorZonesActiveKeyPath
                        stage[keyPath: keyPath] = newPoints.flatMap { [$0.x, $0.y] }
                        syncModuleEnabled(colorZonesGate, hadAdjustments: hadAdjustments)
                        scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                    }
                )
                .equatable()
                .frame(height: contentSlotHeight)
            }
        }
        .frame(width: 620)
    }

    /// Developer Mode only — swaps the graph between the `HueGraphStyle`/`HueGraphBackground`
    /// candidates. Rides in the header's trailing controls, ahead of reset/stoplight.
    @ViewBuilder
    private var colorZonesDeveloperPickers: some View {
        if developerMode {
            HStack(spacing: 8) {
                Picker("Graph Style", selection: $hueGraphStyle) {
                    ForEach(HueGraphStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Graph Background", selection: $hueGraphBackground) {
                    ForEach(HueGraphBackground.allCases) { Text($0.label).tag($0) }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var colorZonesChannelTitle: String {
        switch colorZonesChannel {
        case 0: return "Lightness vs. Hue"
        case 1: return "Chroma vs. Hue"
        default: return "Hue vs. Hue"
        }
    }

    /// Full-width tabs — three equal-width tabs spanning the graph below, each a label plus a
    /// `StoplightToggle` dot (lit on the selected channel), the same "title ●" pairing as the
    /// wheels' own title rows. Plain text rather than a native segmented `Picker`, whose boxed
    /// chrome doesn't match the rest of the editor's low-chrome look (see `MinimalSlider`,
    /// `resetButton`).
    private var colorZonesChannelSwitcher: some View {
        HStack(spacing: 0) {
            channelTab("Lightness", 0)
            channelTab("Chroma", 1)
            channelTab("Hue", 2)
        }
    }

    private func channelTab(_ title: String, _ index: Int) -> some View {
        let isSelected = colorZonesChannel == index
        return Button {
            colorZonesChannel = index
        } label: {
            HStack(spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                StoplightToggle(
                    isOn: Binding(get: { isSelected }, set: { _ in colorZonesChannel = index }),
                    diameter: 8
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var colorZonesActiveKeyPath: ReferenceWritableKeyPath<Stage, [Double]?> {
        switch colorZonesChannel {
        case 0: return \.editColorZonesLightnessPoints
        case 1: return \.editColorZonesChromaPoints
        default: return \.editColorZonesHuePoints
        }
    }

    /// A LUT picker (`FilmSimulationPicker` — film roll + ‹ › stepping) + intensity knob, sibling to `colorBalanceSection`/
    /// `colorZonesSection` — "film simulation" is a color-grading tool same as those two, just one
    /// that composites last (see `StageParameters.lut3D`'s doc comment).
    ///
    /// Same three rows as every other column (see the type's doc comment): the "Film Simulation"
    /// header via `titledGroup` (full-width `spread` style), a "Film Stock" label on the per-control title line, then the
    /// picker (+ Intensity knob when a LUT is loaded) centered in `contentSlotHeight`. The Intensity knob, when a LUT is loaded, takes its
    /// natural height at the bottom and the list gets the rest.
    private var lut3DSection: some View {
        titledGroup(
            "Film Simulation",
            spread: true,
            onReset: {
                resetLUT3D(stage)
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            },
            resetDisabled: !lut3DHasAdjustments(stage),
            enabled: stage.lut3DData != nil ? stageBoolBind(\.editLUT3DEnabled) : nil,
            accessory: lutBrowseButton
        ) {
            VStack(spacing: controlSubtitleSpacing) {
                Text("Film Stock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(height: controlSubtitleHeight)

                VStack(spacing: 12) {
                    FilmSimulationPicker(
                        currentTitle: stage.lut3DTitle,
                        coordinator: coordinator,
                        onSelect: { entry in applyLUT(entry) }
                    )
                    if stage.lut3DData != nil {
                        // A knob instead of `slider(...)`'s usual horizontal bar — an experiment,
                        // scoped to just this one control for now (see `KnobControl`'s doc comment).
                        HStack(spacing: 8) {
                            KnobControl(value: stageBind(\.lut3DIntensity, fallback: 1), range: 0...1, resetValue: 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Intensity")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.0f%%", (stage.lut3DIntensity ?? 1) * 100))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
                .frame(height: contentSlotHeight)
            }
        }
        .frame(width: 180)
        .alert(
            "Couldn't Load LUT",
            isPresented: Binding(get: { lut3DImportError != nil }, set: { if !$0 { lut3DImportError = nil } })
        ) {
            Button("OK", role: .cancel) { lut3DImportError = nil }
        } message: {
            Text(lut3DImportError ?? "")
        }
    }

    /// Opens `LUTBrowserSidebar` in place of the right sidebar's controls — Film Simulation's
    /// header accessory. Lit in the accent color while the browser is open.
    private var lutBrowseButton: some View {
        Button {
            isBrowsingLUTs.toggle()
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isBrowsingLUTs ? Color.primary : Color.secondary)
                .frame(width: headerAccessoryWidth, height: headerAccessoryWidth)
                .background(
                    isBrowsingLUTs ? uiColors.accentColor.opacity(0.45) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
        .help("Browse film simulations with previews of this photo")
    }

    /// Parses `entry`'s `.cube` file and copies the result onto `stage`'s own fields — a copy, not
    /// a reference to the file, so the stage keeps rendering the same look even if the file is
    /// later edited, moved, or deleted from the LUT folder (see `LUTLibrary`'s doc comment).
    private func applyLUT(_ entry: LUTLibraryEntry) {
        do {
            let lut = try LUT3DLoader.load(contentsOf: entry.url)
            stage.lut3DData = lut.data
            stage.lut3DSize = lut.size
            stage.lut3DTitle = entry.name
            stage.editLUT3DEnabled = true
            scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
        } catch {
            lut3DImportError = "\(error)"
        }
    }
}
