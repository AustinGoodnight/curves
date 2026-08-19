import SwiftUI

/// Wraps `ColorWheelControl` with plain `Double` value inputs and `Equatable` conformance, so
/// `.equatable()` lets SwiftUI skip re-invoking this wheel's `body` — and with it, the
/// `AngularGradient`/`RadialGradient` and the two 21-point arc `Path` builds inside
/// `ColorWheelControl` — when its own hue/chroma/luminance haven't changed. Without this,
/// `ColorBalanceBarView` reconstructing all 4 wheels (because *one* of them changed) would force
/// every wheel to redo that work, not just the one actually being dragged.
///
/// The inputs must be plain `Double`s captured by the caller at construction time, not a `Binding`
/// or an `asset` reference read lazily inside `==` — comparing against a live, still-mutable
/// object would always see the object's *current* value on both sides of the comparison and never
/// detect a change. The 3 `onXChange` closures are excluded from equality — they're excluded
/// deliberately, not an oversight: they always write to the same fixed asset property, so their
/// identity never carries meaningful state.
struct ColorWheelHost: View, Equatable {
    var title: String
    var hue: Double
    var chroma: Double
    var luminance: Double
    var maxChroma: Double = 0.5
    var yRange: ClosedRange<Double> = -1...1
    var diameter: CGFloat = 92
    var onHueChange: (Double) -> Void
    var onChromaChange: (Double) -> Void
    var onLuminanceChange: (Double) -> Void

    static func == (lhs: ColorWheelHost, rhs: ColorWheelHost) -> Bool {
        lhs.title == rhs.title && lhs.hue == rhs.hue && lhs.chroma == rhs.chroma && lhs.luminance == rhs.luminance
            && lhs.maxChroma == rhs.maxChroma && lhs.yRange == rhs.yRange && lhs.diameter == rhs.diameter
    }

    var body: some View {
        ColorWheelControl(
            title: title,
            hue: Binding(get: { hue }, set: onHueChange),
            chroma: Binding(get: { chroma }, set: onChromaChange),
            luminance: Binding(get: { luminance }, set: onLuminanceChange),
            maxChroma: maxChroma,
            luminanceRange: yRange,
            diameter: diameter
        )
    }
}
