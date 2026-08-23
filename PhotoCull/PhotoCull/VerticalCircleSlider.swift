import AppKit
import SwiftUI

/// An alternate vertical fader style being tried for Sharp/Dehaze — identical in form to
/// `VerticalGradientSlider` (confirmed pixel-identical track width/height via screenshot
/// measurement, not just matching constants) except for two things: the track has no *color*
/// fill (a flat neutral tone instead of `VerticalGradientSlider`'s per-parameter gradient), and
/// the thumb is a circular dot instead of a thin bar.
///
/// Getting the width to actually match took two false starts, both worth recording because the
/// root cause was non-obvious:
/// 1. A hairline stroke alone (no fill at all) looked visibly thinner than the gradient sliders'
///    filled track, even at an identical `frame` — a stroke's only visible ink is its ~1pt edges,
///    and with the sidebar background showing through the middle, the eye doesn't register the
///    gap between them as part of the track. Fixed by giving the track a flat fill.
/// 2. Even with a fill, and even with the *exact* same shape composition as
///    `VerticalGradientSlider`'s track, it still measured narrower (18px vs 24px, confirmed by
///    scanning rendered screenshot pixels) — because neither track shape has an explicit
///    `.frame()`, so both take the enclosing `ZStack`'s own resolved width, which is the *union*
///    of its children's sizes, not the `trackWidth` constant alone. `VerticalGradientSlider`'s
///    thumb *bar* is `trackWidth + 6` wide, which is what actually determines its track's
///    rendered width — the `trackWidth` constant alone understates it. `thumbDiameter` below
///    matches that same `trackWidth + 6` for exactly this reason, not because a 24pt dot was the
///    intended visual size.
///
/// See `VerticalGradientSlider`'s doc comment for why double-click writes a literal number and
/// Shift-fine-drag is computed from the previous drag event. Bottom of the track is
/// `range.lowerBound`, top is `range.upperBound`.
struct VerticalCircleSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var resetValue: Double? = nil

    @State private var previousDragY: CGFloat? = nil

    private let trackWidth: CGFloat = 18
    // Matches `VerticalGradientSlider`'s thumb *bar* width (`trackWidth + 6`) exactly, not just
    // some visually-reasonable dot size — see the doc comment above for why: neither shape in
    // this `ZStack` has an explicit frame, so both take the `ZStack`'s own resolved width, which
    // is the *union* of its children's sizes, not the `trackWidth` constant alone. Whatever the
    // thumb's width is becomes the track's rendered width too. Matching the bar's exact width is
    // what makes this track measure the same as the gradient sliders' track next to it.
    private let thumbDiameter: CGFloat = 24
    private let fineFactor: CGFloat = 0.2

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let thumbY = (1 - fraction(for: value)) * height

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: trackWidth / 2)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                    .background(
                        Color.white.opacity(0.12)
                            .clipShape(RoundedRectangle(cornerRadius: trackWidth / 2))
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(radius: 1)
                    .offset(y: thumbY - thumbDiameter / 2)
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
