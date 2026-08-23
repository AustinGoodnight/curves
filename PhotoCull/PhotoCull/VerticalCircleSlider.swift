import AppKit
import SwiftUI

/// An alternate vertical fader style being tried for Sharp/Dehaze — identical in form to
/// `VerticalGradientSlider` (confirmed pixel-identical track width/height via screenshot
/// measurement, not just matching constants), differing only in that the track has no *color*
/// fill (a flat, dark neutral tone instead of `VerticalGradientSlider`'s per-parameter gradient),
/// and the thumb is a small glossy dot recessed inside the track (see `thumbFill`) rather than a
/// thin full-width bar. A thin-bar-thumb variant (matching `VerticalGradientSlider`'s own thumb
/// shape) was tried in between and dropped — didn't read as clearly as a "value indicator" as a
/// dot does.
///
/// Getting the width to actually match took two false starts, both worth recording because the
/// root cause was non-obvious:
/// 1. A hairline stroke alone (no fill at all) looked visibly thinner than the gradient sliders'
///    filled track, even at an identical `frame` — a stroke's only visible ink is its ~1pt edges,
///    and with the sidebar background showing through the middle, the eye doesn't register the
///    gap between them as part of the track. Fixed by giving the track a flat fill.
/// 2. Even with a fill, and even with the *exact* same shape composition as
///    `VerticalGradientSlider`'s track, it still measured narrower (18px vs 24px, confirmed by
///    scanning rendered screenshot pixels) — because neither track shape had an explicit
///    `.frame()`, so both took the enclosing `ZStack`'s own resolved width, which is the *union*
///    of its children's sizes, not the `trackWidth` constant alone; whatever the thumb's width was
///    became the track's rendered width too. The track now has its own explicit
///    `.frame(width: trackWidth)`, independent of the thumb, so this no longer matters — but
///    `trackWidth` itself is still set to the width the track was *actually* rendering at back
///    then (24, not whatever a fresh guess might pick), so it stays pixel-matched with
///    `VerticalGradientSlider`'s track next to it.
///
/// See `VerticalGradientSlider`'s doc comment for why double-click writes a literal number and
/// Shift-fine-drag is computed from the previous drag event. Bottom of the track is
/// `range.lowerBound`, top is `range.upperBound`.
struct VerticalCircleSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var resetValue: Double? = nil

    @State private var previousDragY: CGFloat? = nil

    private let trackWidth: CGFloat = 24
    // Recessed inside the track, not overflowing past it — matches `MinimalSlider`'s own thumb.
    private let thumbDiameter: CGFloat = 14
    private let fineFactor: CGFloat = 0.2

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let thumbY = (1 - fraction(for: value)) * height

            ZStack(alignment: .top) {
                // A fill *darker* than the surrounding bar background, not lighter — same change
                // as `MinimalSlider`'s track, so a groove reads as recessed rather than raised
                // consistently across both the sidebar and the bar.
                RoundedRectangle(cornerRadius: trackWidth / 2)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                    .background(
                        Color.black.opacity(0.2)
                            .clipShape(RoundedRectangle(cornerRadius: trackWidth / 2))
                    )
                    .frame(width: trackWidth)

                Circle()
                    .fill(thumbFill)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.75))
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
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

    /// A slightly off-center highlight (rather than a flat, uniform white fill) — reads as a
    /// small glossy bead catching light from the upper-left, matching `MinimalSlider`'s own
    /// `thumbFill` exactly so the sidebar and the bar's faders read as the same control family.
    private var thumbFill: RadialGradient {
        RadialGradient(
            colors: [.white, Color(white: 0.8)],
            center: UnitPoint(x: 0.35, y: 0.3),
            startRadius: 0,
            endRadius: thumbDiameter * 0.75
        )
    }

    private func fraction(for v: Double) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}
