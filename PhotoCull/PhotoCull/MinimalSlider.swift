import AppKit
import SwiftUI

/// A thin-track slider with a small pill thumb, plus a filled colored segment running from the
/// range's implicit zero point out to the thumb (or from the range's minimum, if the range
/// doesn't span zero) — the filled-progress affordance of a capsule slider with the minimal,
/// low-chrome look the rest of the editor uses (no borders, no thick track).
///
/// Double-click resets to `resetValue` (defaulting to 0, or `range.lowerBound` if the range
/// doesn't span 0) — this writes that literal number into the bound value, not `nil`, so it's a
/// visual/numeric reset only; it won't clear an edited field back to "no edit" the way the
/// per-module reset buttons do (those go through `resetXxx(asset)` functions with access to the
/// actual optional field). Holding Shift while dragging switches from absolute (click-anywhere-
/// to-jump) positioning to relative fine movement at `fineFactor` sensitivity, computed from the
/// immediately preceding drag event rather than the gesture's start — so Shift can be pressed or
/// released mid-drag and it still tracks correctly from wherever the pointer currently is.
struct MinimalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var resetValue: Double? = nil

    @State private var previousDragX: CGFloat? = nil

    private let trackHeight: CGFloat = 2
    private let thumbDiameter: CGFloat = 10
    private let hitHeight: CGFloat = 20
    private let fineFactor: CGFloat = 0.2

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fillStart = range.contains(0) ? 0 : range.lowerBound
            let valueFraction = fraction(for: value)
            let fillFraction = fraction(for: fillStart)
            let lo = min(valueFraction, fillFraction)
            let hi = max(valueFraction, fillFraction)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: trackHeight)
                    .clipShape(Capsule())

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: max(0, (hi - lo) * width), height: trackHeight)
                    .offset(x: lo * width)
                    .clipShape(Capsule())

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(radius: 1)
                    .offset(x: valueFraction * width - thumbDiameter / 2)
            }
            .frame(height: hitHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if NSEvent.modifierFlags.contains(.shift), let previousDragX {
                            let deltaFraction = ((drag.location.x - previousDragX) / width) * fineFactor
                            let newFraction = min(max(fraction(for: value) + deltaFraction, 0), 1)
                            value = range.lowerBound + Double(newFraction) * (range.upperBound - range.lowerBound)
                        } else {
                            let f = min(max(drag.location.x / width, 0), 1)
                            value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        }
                        previousDragX = drag.location.x
                    }
                    .onEnded { _ in previousDragX = nil }
            )
            // `.simultaneousGesture`, not `.onTapGesture` — a zero-`minimumDistance` `DragGesture`
            // already fully resolves every individual click (jump-then-release), so a separately
            // *exclusive* tap recognizer never gets a chance to see two of those as a double-click.
            // Running them simultaneously lets both actually receive the touch sequence.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    value = resetValue ?? (range.contains(0) ? 0 : range.lowerBound)
                }
            )
        }
        .frame(height: hitHeight)
    }

    private func fraction(for v: Double) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}
