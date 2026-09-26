import SwiftUI
import SwiftData
import PhotoCatalog
import RawEngine

/// Marks each of `ColorBalanceBarView`'s two side-by-side sections' *actual content* (the fader/
/// wheel row; the Color Zones graph) so `body`'s `HStack` can align on that instead of on
/// whichever section happens to have taller header chrome above its content. See `body`'s doc
/// comment for why plain `.top` alignment doesn't work here.
private struct ContentTopAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.top] }
}

private extension VerticalAlignment {
    static let contentTop = VerticalAlignment(ContentTopAlignment.self)
}

/// White Balance + Color Balance RGB (4 wheels) side by side with Color Zones EQ — two sibling
/// panels, each with its own reset/enabled-toggle, rather than one nested under the other,
/// separated by spacing alone (no `Divider` — see the `.fixedSize` note on `body` for why).
/// Color Balance RGB keeps a text header; Color Zones doesn't — its channel switcher carries the
/// reset/toggle instead, see `colorZonesSection`'s doc comment.
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

    @Environment(ColorSchemeStore.self) private var uiColors

    /// Set in Settings (`SettingsView`) — whether the WB group below renders as the classic
    /// Temp/Tint fader pair or the single `XYWhiteBalanceControl` pad. Not per-photo state.
    @AppStorage(AppSettingsKey.whiteBalanceControlStyle) private var whiteBalanceStyle: WhiteBalanceControlStyle = .classic

    /// Which of the 3 color-zones curves is currently shown in the EQ graph. 2 (hue) matches
    /// darktable's own default "select by" channel.
    @State private var colorZonesChannel = 2
    /// Set when `LUT3DLoader` throws while loading a `.cube` file from the LUT folder, surfaced via `.alert`; `nil`
    /// means no error is showing.
    @State private var lut3DImportError: String?

    /// Height of `colorZonesSection`'s picker/reset/toggle toolbar row — a segmented `Picker` at
    /// default control size. Purely cosmetic now (a stable row height rather than one that shifts
    /// with control metrics); cross-section vertical alignment is handled by `.contentTop`
    /// instead, not by matching this number against anything. Back to this file's original 24pt —
    /// Scoutie Sans's headers are back to the system font's own 12-13pt sizes too (unlike Marmelad,
    /// a display face that needed real size to read as intended, Scoutie Sans is a proper UI face
    /// and holds up fine at small sizes), so there's no longer anything taller to fit in this row.
    private let colorZonesToolbarHeight: CGFloat = 24

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
        // `.contentTop`, not `.top` — `colorZonesSection` has a toolbar row above its graph that
        // `colorBalanceSection` has no equivalent of, so aligning on each section's outer `.top`
        // lines the faders/wheels up with that toolbar instead of with the graph next to them.
        // `.contentTop` is a custom alignment (see below) each section tags onto its *actual*
        // content — the fader/wheel row, the graph — so the two line up regardless of how tall
        // either section's own header chrome happens to be.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .contentTop, spacing: 32) {
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
            titledGroup("WB", enabled: assetBoolBind(\.editWhiteBalanceEnabled)) {
                switch whiteBalanceStyle {
                case .classic:
                    HStack(alignment: .top, spacing: 20) {
                        verticalGradientSlider(
                            "Temp", value: bind(
                                \.editNeutralTemperature, fallback: coordinator.renderer.defaultNeutralTemperature,
                                module: whiteBalanceGate
                            ),
                            range: 2000...12000, gradient: .neutralTemperature,
                            valueText: "\(Int((asset.editNeutralTemperature ?? coordinator.renderer.defaultNeutralTemperature).rounded()))K",
                            resetValue: coordinator.renderer.defaultNeutralTemperature
                        )
                        verticalGradientSlider(
                            "Tint", value: bind(
                                \.editNeutralTint, fallback: coordinator.renderer.defaultNeutralTint, module: whiteBalanceGate
                            ),
                            range: -150...150, gradient: .neutralTint,
                            valueText: formattedTint(asset.editNeutralTint ?? coordinator.renderer.defaultNeutralTint),
                            resetValue: coordinator.renderer.defaultNeutralTint
                        )
                    }
                case .xy:
                    xyWhiteBalanceControl(
                        temperature: bind(
                            \.editNeutralTemperature, fallback: coordinator.renderer.defaultNeutralTemperature,
                            module: whiteBalanceGate
                        ),
                        tint: bind(\.editNeutralTint, fallback: coordinator.renderer.defaultNeutralTint, module: whiteBalanceGate),
                        temperatureRange: 2000...12000, tintRange: -150...150,
                        defaultTemperature: coordinator.renderer.defaultNeutralTemperature,
                        defaultTint: coordinator.renderer.defaultNeutralTint,
                        temperatureText: "\(Int((asset.editNeutralTemperature ?? coordinator.renderer.defaultNeutralTemperature).rounded()))K",
                        tintText: formattedTint(asset.editNeutralTint ?? coordinator.renderer.defaultNeutralTint)
                    )
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
                        y: \.editColorBalanceGlobalY, c: \.editColorBalanceGlobalC, h: \.editColorBalanceGlobalH,
                        maxChroma: 0.01, yRange: -0.05...0.05
                    )
                    wheel(
                        "Shadows",
                        y: \.editColorBalanceShadowsY, c: \.editColorBalanceShadowsC, h: \.editColorBalanceShadowsH,
                        maxChroma: 0.5, yRange: -1...1
                    )
                    wheel(
                        "Midtones",
                        y: \.editColorBalanceMidtonesY, c: \.editColorBalanceMidtonesC, h: \.editColorBalanceMidtonesH,
                        maxChroma: 0.1, yRange: -0.25...0.25
                    )
                    wheel(
                        "Highlights",
                        y: \.editColorBalanceHighlightsY, c: \.editColorBalanceHighlightsC, h: \.editColorBalanceHighlightsH,
                        maxChroma: 0.2, yRange: -0.5...0.5
                    )
                }
            }

        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Wraps `content` with a small group label centered above it — lighter than a module's own
    /// `sectionTitle` (e.g. "Color Zones"), since this is a sub-group *within* Color Balance RGB,
    /// not a module of its own. `.center`, not `.leading`: `content` (e.g. the 4-wheel row) is the
    /// widest child and so defines the `VStack`'s own width regardless of alignment, but a
    /// `.leading` title only ever sits flush with `content`'s *leading* edge (over "Global" alone,
    /// not the wheel row as a whole) — `.center` is what actually centers the shorter title over
    /// the wider row below it.
    ///
    /// The `.contentTop` guide goes on `content` itself, not the outer `VStack`, same technique
    /// `colorZonesSection` uses for its own toolbar-row-plus-graph split — but unlike that graph,
    /// every `content` passed here (`verticalGradientSlider`/`ColorWheelControl`) bundles its own
    /// per-control mini-title (e.g. "Temp", "Global") *inside* the same view as its track/dial, so
    /// `content`'s own `.top` lands on that mini-title, not the track/dial itself. `+
    /// perControlTitleHeight` is what skips past it — dropping this (as an earlier pass here did)
    /// still produces three `.contentTop` values that agree with each other, but all three land on
    /// the mini-titles instead of the actual controls, which visibly landed the wheels/faders lower
    /// than Color Zones' graph (whose `content` has no such inner label to skip).
    ///
    /// `enabled`, when passed, adds the same red/grey `StoplightToggle` "is this on" dot the other
    /// modules (Color Zones, Film Simulation) show next to their own header — tap either the dot or
    /// the title (via `sectionTitle`'s own tap-to-toggle) to flip it. The header row is pinned to
    /// `colorZonesToolbarHeight`, same as those other modules' header rows, so adding the toggle
    /// doesn't change this row's height across groups that do/don't have one — keeping every
    /// section's header the same height is what keeps `perControlTitleHeight`'s tuned offset (below
    /// this row, on `content`) still landing in the same place regardless of which groups opt in.
    ///
    /// The title stays centered over `content` below it even with the toggle attached — a leading
    /// `Color.clear` spacer, exactly `stoplightHitDiameter` wide (matching `StoplightToggle`'s own
    /// hit-frame width) with the same `spacing: 4` gap on both sides, balances the trailing dot out.
    /// Without it, the `HStack` (title+dot) is centered as one block, which visibly drags the title
    /// itself off-center to the left; this way only the dot ends up off-center, which is what
    /// actually matches Color Zones/Film Simulation's own headers (title leading/centered, toggle
    /// trailing, not the *pair* centered as a unit).
    private func titledGroup<Content: View>(_ title: String, enabled: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .center, spacing: 8) {
            HStack(spacing: 4) {
                if enabled != nil {
                    Color.clear.frame(width: stoplightHitDiameter, height: stoplightHitDiameter)
                }
                sectionTitle(title, enabled: enabled, font: .scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                if let enabled {
                    StoplightToggle(isOn: enabled)
                }
            }
            .frame(height: colorZonesToolbarHeight)
            content()
                .alignmentGuide(.contentTop) { d in d[.top] + perControlTitleHeight }
        }
    }

    /// `StoplightToggle`'s own outer hit-frame width at its default `diameter` (10) — `diameter +
    /// 12`, per its own layout, not configurable from outside. `titledGroup` uses this twice: once
    /// for the toggle itself, once for the invisible balancing spacer on the title's other side.
    private let stoplightHitDiameter: CGFloat = 22

    /// Single-line `.caption` title + the 8pt spacing above every fader's track and every wheel's
    /// dial (`verticalGradientSlider`'s and `ColorWheelControl`'s own `VStack(spacing: 8)`) — the
    /// offset `titledGroup`'s `.contentTop` guide needs to point past each control's own title and
    /// land on its actual track/dial.
    private let perControlTitleHeight: CGFloat = 22

    private func wheel(
        _ title: String,
        y: ReferenceWritableKeyPath<Stage, Double?>,
        c: ReferenceWritableKeyPath<Stage, Double?>,
        h: ReferenceWritableKeyPath<Stage, Double?>,
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
    /// darktable's "select by hue" mode). The channel switcher's toolbar row carries the "Color
    /// Zones" title (tap-to-toggle, see `sectionTitle`) alongside the reset/enabled controls, all
    /// in one row instead of a separate header above it. That row no longer shares a background
    /// with the graph below it (that grey box read as mismatched once the graph itself became a
    /// hue-spectrum card, not grey) — it sits directly on `Color.sidebarBackground` instead, and
    /// the graph is a fully-rounded standalone card again (`topCornersSquared: false`, since
    /// there's no seam left to keep flush). The graph carries the `.contentTop` alignment guide
    /// (see file top) — that's what lines it up with `colorBalanceSection`'s fader/wheel row
    /// despite this toolbar row sitting above it.
    private var colorZonesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Three independent regions instead of one packed `HStack` — "Color Zones" pinned
            // leading, the switcher truly centered on the row's full width (not just centered in
            // whatever's left after the label), reset/toggle pinned trailing. A `ZStack` with
            // each region as its own `HStack` + `Spacer` gets this right where a single `HStack`
            // with `Spacer()`s in between wouldn't: the switcher would center in the space
            // *between* the label and the trailing controls, not on the row itself, so it'd drift
            // depending on how wide "Color Zones" happens to render.
            ZStack {
                HStack(spacing: 8) {
                    sectionTitle("Color Zones", enabled: stageBoolBind(\.editColorZonesEnabled), font: .scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                colorZonesChannelSwitcher
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    resetButton(disabled: !colorZonesHasAdjustments(stage), action: {
                        resetColorZones(stage)
                        scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                    })
                    StoplightToggle(isOn: stageBoolBind(\.editColorZonesEnabled))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: colorZonesToolbarHeight)

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
                onPointsChange: { newPoints in
                    let hadAdjustments = colorZonesGate.hasAdjustments()
                    let keyPath = colorZonesActiveKeyPath
                    stage[keyPath: keyPath] = newPoints.flatMap { [$0.x, $0.y] }
                    syncModuleEnabled(colorZonesGate, hadAdjustments: hadAdjustments)
                    scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                }
            )
            .equatable()
            .alignmentGuide(.contentTop) { d in d[.top] }
        }
        .frame(width: 620)
    }

    private var colorZonesChannelTitle: String {
        switch colorZonesChannel {
        case 0: return "Lightness vs. Hue"
        case 1: return "Chroma vs. Hue"
        default: return "Hue vs. Hue"
        }
    }

    /// A plain-text tab row standing in for what used to be a `Picker(.segmented)` — that native
    /// control's own boxed/pill chrome was the one place left in this bar that didn't match the
    /// rest of the editor's low-chrome look (no borders, no default AppKit control backgrounds,
    /// just text/accent-color state changes — see `MinimalSlider`, `resetButton`). The selected
    /// tab gets a filled pill in the same `Color.primary.opacity(0.08)` used for value pills
    /// elsewhere; unselected tabs are bare secondary-colored text.
    private var colorZonesChannelSwitcher: some View {
        HStack(spacing: 2) {
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
            Text(title)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isSelected ? Color.primary.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
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

    /// A LUT picker (`LUT3DPresetMenu`) + intensity slider, sibling to `colorBalanceSection`/
    /// `colorZonesSection` — "film simulation" is a color-grading tool same as those two, just one
    /// that composites last (see `StageParameters.lut3D`'s doc comment).
    ///
    /// Deliberately *not* built on the shared `section(...)` helper the sidebar uses: that bundles
    /// the title/reset/toggle header row and the content into one `VStack` with no seam to hook a
    /// `.contentTop` guide into partway down, so wrapping the whole thing pinned `.contentTop` to
    /// the *title's* own top — one entire header-row's height above where `colorZonesSection`'s
    /// guide actually sits (on its content, below its own toolbar row) — which visibly shoved this
    /// whole section down, reading as nested under `colorZonesSection` instead of a sibling next to
    /// it. Matching `colorZonesSection`'s own structure instead — a fixed-height header row (reusing
    /// its exact `colorZonesToolbarHeight`, so both sections' headers line up pixel-for-pixel), then
    /// content with the guide on it — fixes that.
    ///
    /// No "LUT" mini-title above the list anymore — the list itself starts where every other
    /// column's mini-title sits (`.contentTop` still offset by `perControlTitleHeight`) and runs
    /// the full `perControlTitleHeight + colorFaderTrackHeight`, so it spans the bar's whole
    /// height instead of a short 3-4 row box. The Intensity knob, when a LUT is loaded, takes its
    /// natural height at the bottom and the list gets the rest.
    private var lut3DSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                sectionTitle(
                    "Film Simulation", enabled: stage.lut3DData != nil ? stageBoolBind(\.editLUT3DEnabled) : nil,
                    font: .scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption)
                )
                resetButton(disabled: !lut3DHasAdjustments(stage), action: {
                    resetLUT3D(stage)
                    scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                })
                if stage.lut3DData != nil {
                    Spacer(minLength: 0)
                    StoplightToggle(isOn: stageBoolBind(\.editLUT3DEnabled))
                }
            }
            .frame(height: colorZonesToolbarHeight)

            VStack(alignment: .leading, spacing: 8) {
                LUT3DPresetMenu(
                    currentTitle: stage.lut3DTitle,
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
            .frame(height: perControlTitleHeight + colorFaderTrackHeight, alignment: .top)
            .alignmentGuide(.contentTop) { d in d[.top] + perControlTitleHeight }
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
