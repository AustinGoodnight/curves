import SwiftUI
import RawEngine

/// Wraps `CurveEditorControl` with plain value inputs and `Equatable` conformance, so
/// `.equatable()` lets SwiftUI skip re-invoking this curve's `body` — and with it, the
/// monotone-Hermite/Catmull-Rom spline fit plus the 96-point `Path` build inside
/// `CurveEditorControl` — when its own points/histogram haven't changed.
///
/// This is what `ColorWheelHost` already does for the color wheels, applied to the two curve
/// editors: without it, the RGB Curve editor sits in the same `EditorSidebarView.body` as
/// Exposure/White Balance/Filmic, so *every* tick of *any* of those sliders was re-fitting the
/// curve and rebuilding its Path — on the main thread, synchronously, once per mouse-move event.
/// That's what produced the "slider doesn't visibly move until you release it" symptom: enough
/// per-event main-thread cost that AppKit's queued drag events (which can arrive faster than the
/// UI can redraw) never caught up to the screen until the queue drained at mouse-up. See
/// `ColorWheelHost`'s doc comment for why the inputs must be plain values, not a `Binding` or a
/// live object read lazily inside `==`.
struct CurveEditorHost: View, Equatable {
    var points: [SIMD2<Double>]
    var title: String = "Curve"
    var height: CGFloat = 220
    var identityPoints: [SIMD2<Double>] = RGBCurveParameters.identityPoints
    var maxPoints: Int = RGBCurveKernel.maxNodes
    var splineType: RGBCurveSpline.SplineType = .monotoneHermite
    var referenceIsFlat = false
    var histogram: [Float]? = nil
    var showHueAxis: Bool = false
    var showHeader: Bool = true
    var topCornersSquared: Bool = false
    var lineColor: Color = .accentColor
    /// See `CurveEditorControl`'s own doc comment — off by default; RGB Curve's call site turns
    /// it on, Color Zones leaves it off.
    var showEndpointControls: Bool = false
    /// See `CurveEditorControl`'s own doc comment — off by default; Color Zones' call site turns
    /// it on.
    var showGrid: Bool = false
    var onPointsChange: ([SIMD2<Double>]) -> Void

    /// `splineType` is excluded deliberately: it's a fixed constant per call site (RGB Curve is
    /// always `.monotoneHermite`, Color Zones always `.catmullRom`), never actually differs
    /// between an "old" and "new" instance of the same curve, and isn't `Equatable` itself.
    static func == (lhs: CurveEditorHost, rhs: CurveEditorHost) -> Bool {
        lhs.points == rhs.points && lhs.title == rhs.title && lhs.height == rhs.height
            && lhs.identityPoints == rhs.identityPoints && lhs.maxPoints == rhs.maxPoints
            && lhs.referenceIsFlat == rhs.referenceIsFlat && lhs.histogram == rhs.histogram
            && lhs.showHueAxis == rhs.showHueAxis && lhs.showHeader == rhs.showHeader
            && lhs.topCornersSquared == rhs.topCornersSquared && lhs.lineColor == rhs.lineColor
            && lhs.showEndpointControls == rhs.showEndpointControls && lhs.showGrid == rhs.showGrid
    }

    var body: some View {
        CurveEditorControl(
            points: Binding(get: { points }, set: onPointsChange),
            title: title,
            height: height,
            identityPoints: identityPoints,
            maxPoints: maxPoints,
            splineType: splineType,
            referenceIsFlat: referenceIsFlat,
            histogram: histogram,
            showHueAxis: showHueAxis,
            showHeader: showHeader,
            topCornersSquared: topCornersSquared,
            lineColor: lineColor,
            showEndpointControls: showEndpointControls,
            showGrid: showGrid
        )
    }
}
