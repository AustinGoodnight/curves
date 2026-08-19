import SwiftUI
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
/// than cramped into a 320pt-wide column.
struct ColorBalanceBarView: View {
    let asset: PhotoAsset
    let coordinator: EditorRenderCoordinator
    let wheelDiameter: CGFloat

    /// Which of the 3 color-zones curves is currently shown in the EQ graph. 2 (hue) matches
    /// darktable's own default "select by" channel.
    @State private var colorZonesChannel = 2

    /// Height of `colorZonesSection`'s picker/reset/toggle toolbar row — a segmented `Picker` at
    /// default control size. Purely cosmetic now (a stable row height rather than one that shifts
    /// with control metrics); cross-section vertical alignment is handled by `.contentTop`
    /// instead, not by matching this number against anything.
    private let colorZonesToolbarHeight: CGFloat = 24

    var body: some View {
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
        HStack(alignment: .contentTop, spacing: 32) {
            colorBalanceSection
            colorZonesSection
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .toggleStyle(.switch)
        .disabled(!coordinator.isReady)
        .background(Color.sidebarBackground)
    }

    /// No title/reset/enabled-toggle row anymore — Color Balance RGB is always active now (each
    /// wheel and fader already double-click-resets individually, so the module-wide reset button
    /// stopped earning its keep once that landed). But every individual fader/wheel still has its
    /// own small title *above* its track/dial (`verticalGradientSlider`, `ColorWheelControl`), so
    /// this section's real content — the tracks/dials themselves — doesn't start at its own top
    /// edge; it starts `perControlTitleHeight` below it. The `.contentTop` guide accounts for
    /// that explicitly rather than assuming `.top` already points at the right place.
    ///
    /// `.fixedSize(horizontal:)` pins this to its own ideal content width — without it, a
    /// `Spacer()`-bearing row here would make this whole section report an unbounded/flexible
    /// width upward to `body`'s `HStack`, the same failure mode as the `Divider` height bug noted
    /// on `body` but on the width axis: in a wide (e.g. full-screen) window this section would
    /// eat the leftover width meant for the trailing `Spacer`, shoving `colorZonesSection` far to
    /// the right with a dead gap in between. No such row remains now that the header's gone, but
    /// this stays as cheap insurance against the same failure mode returning.
    private var colorBalanceSection: some View {
        HStack(alignment: .top, spacing: 28) {
                HStack(alignment: .top, spacing: 20) {
                    verticalGradientSlider(
                        "Temp", value: bind(\.editNeutralTemperature, fallback: coordinator.renderer.defaultNeutralTemperature),
                        range: 2000...12000, gradient: .neutralTemperature,
                        valueText: "\(Int((asset.editNeutralTemperature ?? coordinator.renderer.defaultNeutralTemperature).rounded()))K",
                        resetValue: coordinator.renderer.defaultNeutralTemperature
                    )
                    verticalGradientSlider(
                        "Tint", value: bind(\.editNeutralTint, fallback: coordinator.renderer.defaultNeutralTint),
                        range: -150...150, gradient: .neutralTint,
                        valueText: formattedTint(asset.editNeutralTint ?? coordinator.renderer.defaultNeutralTint),
                        resetValue: coordinator.renderer.defaultNeutralTint
                    )
                }

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

                HStack(alignment: .top, spacing: 26) {
                    // No value pill for now — see `verticalGradientSlider`'s doc comment; an
                    // empty `valueText` skips it rather than rendering a blank box. Their 2-
                    // decimal-place values ("−0.50", "45.00") were overflowing the pill and
                    // wrapping; Temp/Tint above don't have that problem, so they keep theirs.
                    verticalGradientSlider(
                        "Chr", value: bind(\.editColorBalanceChromaGlobal, fallback: 0),
                        range: -0.5...0.5, gradient: .colorIntensity,
                        valueText: ""
                    )
                    verticalGradientSlider(
                        "Vib", value: bind(\.editColorBalanceVibrance, fallback: 0),
                        range: -0.5...0.5, gradient: .colorIntensity,
                        valueText: ""
                    )
                    verticalGradientSlider(
                        "Sat", value: bind(\.editFilmicSaturation, fallback: FilmicRGBParameters.darktableDefault.saturation),
                        range: -100...100, gradient: .colorIntensity,
                        valueText: "", resetValue: FilmicRGBParameters.darktableDefault.saturation
                    )
                }
        }
        .alignmentGuide(.contentTop) { d in d[.top] + perControlTitleHeight }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Single-line `.caption` title + the 8pt spacing above every fader's track and every wheel's
    /// dial (`verticalGradientSlider`'s and `ColorWheelControl`'s own `VStack(spacing: 8)`) — the
    /// offset `colorBalanceSection`'s `.contentTop` guide needs to point past each control's own
    /// title and land on its actual track/dial.
    private let perControlTitleHeight: CGFloat = 22

    private func wheel(
        _ title: String,
        y: ReferenceWritableKeyPath<PhotoAsset, Double?>,
        c: ReferenceWritableKeyPath<PhotoAsset, Double?>,
        h: ReferenceWritableKeyPath<PhotoAsset, Double?>,
        maxChroma: Double,
        yRange: ClosedRange<Double>
    ) -> some View {
        ColorWheelHost(
            title: title,
            hue: asset[keyPath: h] ?? 0,
            chroma: asset[keyPath: c] ?? 0,
            luminance: asset[keyPath: y] ?? 0,
            maxChroma: maxChroma,
            yRange: yRange,
            diameter: wheelDiameter,
            onHueChange: { newValue in
                asset[keyPath: h] = newValue
                coordinator.scheduleRender(params: rawEditParameters(for: asset))
            },
            onChromaChange: { newValue in
                asset[keyPath: c] = newValue
                coordinator.scheduleRender(params: rawEditParameters(for: asset))
            },
            onLuminanceChange: { newValue in
                asset[keyPath: y] = newValue
                coordinator.scheduleRender(params: rawEditParameters(for: asset))
            }
        )
        .equatable()
    }

    private func formattedTint(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<PhotoAsset, Double?>, fallback: Double) -> Binding<Double> {
        Binding(
            get: { asset[keyPath: keyPath] ?? fallback },
            set: { newValue in
                asset[keyPath: keyPath] = newValue
                coordinator.scheduleRender(params: rawEditParameters(for: asset))
            }
        )
    }

    private func boolBind(_ keyPath: ReferenceWritableKeyPath<PhotoAsset, Bool>) -> Binding<Bool> {
        Binding(
            get: { asset[keyPath: keyPath] },
            set: { newValue in
                asset[keyPath: keyPath] = newValue
                coordinator.scheduleRender(params: rawEditParameters(for: asset))
            }
        )
    }

    /// The EQ-style color zones interface: 3 curves (lightness/chroma/hue), each a function of
    /// the pixel's own hue — a tab per curve, one graph shown at a time. A sibling panel to
    /// `colorBalanceSection`, not nested inside it — still placed next to it since both are
    /// hue-driven grading tools (see `ColorZonesParameters`'s scope note: this always operates in
    /// darktable's "select by hue" mode). No standalone "Color Zones" title: the channel switcher
    /// carries the reset/enabled controls that title's row used to hold. The switcher no longer
    /// shares a background with the graph below it (that grey box read as mismatched once the
    /// graph itself became a hue-spectrum card, not grey) — it sits directly on
    /// `Color.sidebarBackground` instead, and the graph is a fully-rounded standalone card again
    /// (`topCornersSquared: false`, since there's no seam left to keep flush). The graph carries
    /// the `.contentTop` alignment guide (see file top) — that's what lines it up with
    /// `colorBalanceSection`'s fader/wheel row despite this toolbar row sitting above it.
    private var colorZonesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                colorZonesChannelSwitcher

                resetButton(disabled: !colorZonesHasEdits(asset), action: {
                    resetColorZones(asset)
                    coordinator.scheduleRender(params: rawEditParameters(for: asset))
                })
                Toggle("", isOn: boolBind(\.editColorZonesEnabled))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .frame(height: colorZonesToolbarHeight)

            CurveEditorHost(
                points: colorZonesPoints(for: asset, colorZonesActiveKeyPath),
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
                onPointsChange: { newPoints in
                    let keyPath = colorZonesActiveKeyPath
                    asset[keyPath: keyPath] = newPoints.flatMap { [$0.x, $0.y] }
                    coordinator.scheduleRender(params: rawEditParameters(for: asset))
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

    private var colorZonesActiveKeyPath: ReferenceWritableKeyPath<PhotoAsset, [Double]?> {
        switch colorZonesChannel {
        case 0: return \.editColorZonesLightnessPoints
        case 1: return \.editColorZonesChromaPoints
        default: return \.editColorZonesHuePoints
        }
    }
}
