import AppKit
import SwiftUI

/// A vertical fader whose full track is always painted with a fixed 3-stop gradient (cool→neutral
/// →warm, or green→neutral→magenta) rather than a value-driven fill — the color itself communicates
/// direction before the reader even looks at the number, matching how Lightroom/Capture One paint
/// their own White Balance sliders. Unlike `MinimalSlider` there's no separate filled segment,
/// since the whole track's color already encodes position; the thumb is just a thin bar riding on
/// top. Bottom of the track is `range.lowerBound`, top is `range.upperBound`.
///
/// Double-click and Shift-drag work the same way as `MinimalSlider` — see its doc comment for why
/// double-click writes a literal number rather than clearing the field, and why Shift-fine-drag is
/// computed from the previous drag event rather than the gesture's start.
struct VerticalGradientSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let gradient: Gradient
    var resetValue: Double? = nil

    @State private var previousDragY: CGFloat? = nil

    private let trackWidth: CGFloat = 18
    private let thumbHeight: CGFloat = 6
    private let fineFactor: CGFloat = 0.2

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let thumbY = (1 - fraction(for: value)) * height

            ZStack(alignment: .top) {
                // A hairline border on the track itself — without it, a gradient whose end color
                // sits close to `Color.sidebarBackground` (e.g. `detailIntensity`'s dark-gray
                // bottom stop) visually blends into the background near that end, reading as a
                // shorter track than a vivid-end gradient's (e.g. `colorIntensity`'s reds/blues)
                // even though both render at the exact same `frame(height:)`. The border keeps
                // every fader's full top/bottom extent equally legible regardless of which
                // gradient it uses.
                RoundedRectangle(cornerRadius: trackWidth / 2)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    .background(
                        LinearGradient(gradient: gradient, startPoint: .bottom, endPoint: .top)
                            .clipShape(RoundedRectangle(cornerRadius: trackWidth / 2))
                    )

                RoundedRectangle(cornerRadius: thumbHeight / 2)
                    .fill(Color.white)
                    .frame(width: trackWidth + 6, height: thumbHeight)
                    .shadow(radius: 1)
                    .offset(y: thumbY - thumbHeight / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if NSEvent.modifierFlags.contains(.shift), let previousDragY {
                            let deltaFraction = ((previousDragY - drag.location.y) / height) * fineFactor
                            let newFraction = min(max(fraction(for: value) + deltaFraction, 0), 1)
                            value = range.lowerBound + Double(newFraction) * (range.upperBound - range.lowerBound)
                        } else {
                            let f = min(max(1 - drag.location.y / height, 0), 1)
                            value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        }
                        previousDragY = drag.location.y
                    }
                    .onEnded { _ in previousDragY = nil }
            )
            // `.simultaneousGesture`, not `.onTapGesture` — see `MinimalSlider`'s doc comment on
            // its own reset gesture for why an exclusive tap recognizer never sees the double-
            // click when a zero-`minimumDistance` `DragGesture` is already attached.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    value = resetValue ?? (range.contains(0) ? 0 : range.lowerBound)
                }
            )
        }
        .frame(width: trackWidth)
    }

    private func fraction(for v: Double) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

extension Gradient {
    /// Bottom = cool (low Kelvin reading on the slider), top = warm — matches
    /// `RawBaseParameters.neutralTemperature`'s 2000...12000 range. Same vivid Apple system-color
    /// saturation level as `colorIntensity`'s red/green/blue, rather than the original muted take.
    static let neutralTemperature = Gradient(stops: [
        .init(color: Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255), location: 0),
        .init(color: Color(red: 154 / 255, green: 154 / 255, blue: 156 / 255), location: 0.35),
        .init(color: Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255), location: 1),
    ])
    /// Bottom = green, top = magenta — matches `RawBaseParameters.neutralTint`'s -150...150 range.
    static let neutralTint = Gradient(stops: [
        .init(color: Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255), location: 0),
        .init(color: Color(red: 154 / 255, green: 154 / 255, blue: 156 / 255), location: 0.5),
        .init(color: Color(red: 255 / 255, green: 45 / 255, blue: 210 / 255), location: 1),
    ])
    /// Bottom-to-top red → green → blue — a more vivid experiment for Chroma/Vibrance/Saturation
    /// than the earlier muted-to-vivid single-hue version. Not meant to encode direction/meaning
    /// the way `neutralTemperature`/`neutralTint` do; it's decorative, just something more
    /// colorful for these three "more colorfulness" sliders to sit next to.
    static let colorIntensity = Gradient(stops: [
        .init(color: Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255), location: 0),
        .init(color: Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255), location: 0.5),
        .init(color: Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255), location: 1),
    ])
}
