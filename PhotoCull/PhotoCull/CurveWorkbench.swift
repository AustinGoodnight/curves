import SwiftUI
import RawEngine

/// The RGB Curve editor in the sidebar — the combination picked from the Developer Mode concepts
/// (`CurveEditorConcepts.swift`):
/// - **Drag** (default): Targeted Drag — hover a tone, drag it up/down; no points to hunt for.
/// - **Points**: Refined Points — visible-on-hover points with a big hit radius, in→out bubble,
///   diagonal snap, Shift for fine, double-click to remove. For precise multi-point shaping and
///   moving the black/white output ends.
/// In both modes the black/white endpoints are `CurveEdgeHandles` riding the box edges (input
/// black/white point along bottom/top, output levels along left/right).
/// Both draw on the Zone Grid (zone boundaries, 0–X labels under the graph, readouts in zones),
/// with the Ramp Preview underneath showing what the curve does to tones. Presets live behind the
/// section header's Presets button (`EditorSidebarView`), not in here.
struct CurveWorkbench: View {
    enum Mode: String {
        case drag, points
    }

    @Binding var points: [SIMD2<Double>]
    let histogram: [Float]
    var height: CGFloat = 220

    @AppStorage("curveEditMode") private var mode: Mode = .drag
    /// Compact view, toggled from the Curve section header (`EditorSidebarView`): just the curve
    /// graph at about half height — no zone labels, readout/mode row, or ramp preview underneath.
    /// Editing (drag mode or points, edge handles) keeps working exactly as in the full view.
    @AppStorage(Self.collapsedKey) private var isCollapsed = false
    static let collapsedKey = "curveCollapsed"
    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var focusX: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                switch mode {
                case .drag:
                    TargetedCurveGraph(points: $points, histogram: histogram, height: graphHeight, grid: .zones, focusX: $focusX)
                case .points:
                    PointCurveEditor(
                        points: $points, histogram: histogram, height: graphHeight,
                        pointsOnlyOnHover: true, showsReadout: true, snapsToDiagonal: true, hitRadius: 20, grid: .zones,
                        readout: { x, y in "Zone \(CurveZones.numeral(ofDisplay: x)) → \(CurveZones.numeral(ofDisplay: y))" },
                        focusX: $focusX, editsEndpoints: false
                    )
                }
                CurveEdgeHandles(points: $points)
            }
            .frame(height: graphHeight)
            if !isCollapsed {
            CurveZoneAxisLabels()
            HStack(spacing: 8) {
                Text(caption)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                modeSwitch
            }
            CurveRampStrip(points: points)
                .padding(.top, 4)
            }
        }
        .animation(.snappy(duration: 0.2), value: isCollapsed)
    }

    private var graphHeight: CGFloat {
        isCollapsed ? max(110, height * 0.5) : height
    }

    private var caption: String {
        if focusX == nil, mode == .points {
            return "Drag to add · ⇧ fine · double-click removes"
        }
        return curveFocusCaption(points: points, histogram: histogram, focusX: focusX, withZones: true)
    }

    /// "Drag | Points" — small text pills in a recessed capsule, same selected-pill language as
    /// the rest of the editor's plain-text switchers.
    private var modeSwitch: some View {
        HStack(spacing: 0) {
            modeButton("Drag", .drag)
            modeButton("Points", .points)
        }
        .padding(2)
        .background(uiColors.recessedTrackBackground, in: Capsule())
    }

    private func modeButton(_ title: String, _ value: Mode) -> some View {
        Button {
            mode = value
            focusX = nil
        } label: {
            Text(title)
                .font(.caption2.weight(mode == value ? .semibold : .regular))
                .foregroundStyle(mode == value ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(mode == value ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(value == .drag ? "Hover a tone and drag it up or down" : "Place and move individual curve points")
    }
}
