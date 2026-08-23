import SwiftUI
import AppKit

/// A rotary-dial alternative to `MinimalSlider`/`VerticalCircleSlider` — an experiment, currently
/// wired up only to the Film Simulation module's Intensity control, not (yet) adopted as the
/// standard fader shape everywhere else in the editor. Visual language still matches the rest of
/// the editor's controls: the same recessed dark track fill and glossy white thumb dot
/// `VerticalCircleSlider` uses, just arranged around a 270° arc instead of a straight track.
///
/// Interaction is a vertical drag (drag up to increase, down to decrease), not a literal
/// click-and-rotate-around-the-dial gesture — matching every other fader in this app, and matching
/// how real hardware/software knobs are actually driven with a mouse (circular-motion dragging is
/// notoriously fiddly; every DAW plugin UI uses vertical-drag-on-a-knob instead). Shift held during
/// a drag switches to fine adjustment, same convention as `VerticalCircleSlider`'s black-point
/// slider. Double-click resets to `resetValue`.
struct KnobControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var resetValue: Double? = nil
    var diameter: CGFloat = 52

    @State private var previousDragY: CGFloat? = nil

    /// Standard hardware-knob sweep: 270° of travel with a 90° gap centered at the bottom (6
    /// o'clock), so the two ends land at roughly 7:30 and 4:30. `trim`'s own angle space starts at
    /// 3 o'clock (0°) and sweeps clockwise as its fraction increases — well-established SwiftUI
    /// behavior (the same trim + `.rotationEffect` recipe every circular-progress-ring tutorial
    /// uses) — so rotating the whole trimmed shape by `90 + gapDegrees / 2` moves that trim's
    /// 0%-point from 3 o'clock down to the gap's actual start (7:30).
    private let gapDegrees: Double = 90
    private let lineWidth: CGFloat = 3
    private let fineFactor: CGFloat = 0.3

    private var sweepFraction: CGFloat {
        CGFloat((360 - gapDegrees) / 360)
    }

    private var valueFraction: CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private var trackRotation: Angle {
        .degrees(90 + gapDegrees / 2)
    }

    /// Where the thumb dot sits, in the same "0° = 3 o'clock, increasing clockwise" angle space
    /// `trackRotation` operates in — the value arc's own moving end, computed directly with
    /// trigonometry rather than reusing `trim`'s geometry, since a stroked dot needs a literal
    /// `CGPoint` offset, not another trimmable shape.
    private var thumbOffset: CGSize {
        let angleDegrees = 90 + gapDegrees / 2 + Double(sweepFraction) * Double(valueFraction) * 360
        let angleRadians = angleDegrees * .pi / 180
        let radius = diameter / 2 - lineWidth
        return CGSize(width: radius * CGFloat(cos(angleRadians)), height: radius * CGFloat(sin(angleRadians)))
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                .background(Circle().fill(Color.black.opacity(0.2)))
                .padding(lineWidth / 2)

            Circle()
                .trim(from: 0, to: sweepFraction)
                .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(trackRotation)

            Circle()
                .trim(from: 0, to: sweepFraction * valueFraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(trackRotation)

            Circle()
                .fill(thumbFill)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.75))
                .frame(width: diameter * 0.16, height: diameter * 0.16)
                .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                .offset(thumbOffset)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let previous = previousDragY ?? drag.startLocation.y
                    let factor = NSEvent.modifierFlags.contains(.shift) ? fineFactor * 0.3 : fineFactor
                    let deltaFraction = ((previous - drag.location.y) / diameter) * factor
                    let newFraction = min(max(valueFraction + deltaFraction, 0), 1)
                    value = range.lowerBound + Double(newFraction) * (range.upperBound - range.lowerBound)
                    previousDragY = drag.location.y
                }
                .onEnded { _ in previousDragY = nil }
        )
        // `.simultaneousGesture`, not `.onTapGesture` — see `MinimalSlider`'s doc comment on its
        // own reset gesture for why an exclusive tap recognizer never sees the double-click when a
        // zero-`minimumDistance` `DragGesture` is already attached.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                value = resetValue ?? (range.contains(0) ? 0 : range.lowerBound)
            }
        )
    }

    /// Same off-center highlight as `VerticalCircleSlider.thumbFill` — one consistent "glossy dial
    /// dot" language across every draggable thumb in the editor.
    private var thumbFill: RadialGradient {
        RadialGradient(
            colors: [.white, Color(white: 0.8)],
            center: UnitPoint(x: 0.35, y: 0.3),
            startRadius: 0,
            endRadius: diameter * 0.16 * 0.75
        )
    }
}
