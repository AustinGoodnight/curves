import AppKit
import SwiftUI

/// The horizontal counterpart to `VerticalCircleSlider` (Sharp/Dehaze's style in
/// `ColorBalanceBarView`), loosely — a dark, recessed capsule track (reads as a groove cut into
/// the sidebar's own background rather than a panel sitting on top of it) with a small glossy
/// circular thumb recessed inside it (see `thumbFill`), no color-mapped gradient and no filled
/// "progress" segment (the thumb's position alone reads as the value, same as Sharp/Dehaze).
/// Replaces this control's earlier design (a thin accent-color-filled capsule), which read as a
/// visually thinner, quieter control than everything in the bottom bar despite living in the same
/// editor. A thin-bar-thumb variant (matching `VerticalGradientSlider`'s own thumb shape) was
/// tried in between and dropped — didn't read as clearly as a "value indicator" as a dot does.
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
    /// Small reference marks drawn along the track at these value positions — e.g. whole-EV marks
    /// on the Exposure slider. Empty (the default) draws nothing; values outside `range` are
    /// skipped rather than clamped into view. `0`, if present, draws taller/brighter than the
    /// rest, same "zero reads as neutral" convention the vertical faders/wheels use elsewhere
    /// (`XYWhiteBalanceControl`'s dashed crosshair, `ColorWheelControl`'s arc fill origin).
    var ticks: [Double] = []
    /// `.capsule` (default) is this control's long-standing look — see the struct doc comment,
    /// still used by every slider that hasn't opted into `.hairline`. `.hairline` is Exposure/
    /// Contrast's current pick, a callback to the even-earlier thin-capsule design mentioned there;
    /// `EditorSidebarView`'s "Slider Styles" comparison row also keeps it alongside `.capsule` for
    /// the still-open track-style question.
    var trackStyle: TrackStyle = .capsule
    /// `.circle` (default) is the "glossy dot" every slider that hasn't opted into `.diamond`
    /// still uses. `.diamond` won the shape round of `EditorSidebarView`'s "Slider Styles"
    /// comparison (over circle/triangle/bar, since dropped) and is now live on Exposure/Contrast.
    var thumbShape: ThumbShape = .circle

    enum TrackStyle {
        case capsule
        case hairline
    }

    enum ThumbShape {
        case circle
        case diamond
    }

    @State private var previousDragX: CGFloat? = nil
    @Environment(ColorSchemeStore.self) private var uiColors

    // 24, not 18 — this is the track's actual visible size from before the thumb/fill rework
    // below (a pre-existing framing bug had it rendering at the outer container's height, 24 at
    // the time, rather than the `trackHeight` constant's then-value of 18; once that bug was
    // fixed to make the track size deterministic, it had to be pinned to the size it was already
    // visibly established at, not the stale, never-actually-rendered 18 the constant used to say).
    private let trackHeight: CGFloat = 24
    // Back to a dot (the bar-thumb experiment didn't land) — recessed inside the track like
    // before, but with a bit more presence than a flat white disc: see `thumbFill`/`thumbRim`.
    private let thumbDiameter: CGFloat = 14
    private let fineFactor: CGFloat = 0.2

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = fraction(for: value) * width

            ZStack(alignment: .leading) {
                track
                if !ticks.isEmpty {
                    tickMarks(width: width)
                }
                thumb
                    .offset(x: thumbX - thumbDiameter / 2)
            }
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
        // `trackHeight`, not `thumbDiameter` — the thumb sits recessed inside the track, not
        // overflowing past it, so the track determines this control's footprint.
        .frame(height: trackHeight)
    }

    /// `.capsule`: a fill *darker* than the surrounding background (`uiColors.recessedTrackBackground`,
    /// a fixed opaque gray, not a lighter translucent-white one) — reads as a groove recessed into
    /// the sidebar rather than a lighter panel sitting raised on top of it, same idea for
    /// `VerticalCircleSlider`'s track in `ColorBalanceBarView`, and matches
    /// `CurveEditorControl`'s own graph fill/border exactly (see that color's own doc comment).
    /// Explicit `.frame(height: trackHeight)`, not left to inherit whatever height the outer
    /// container proposes — without it, the track silently rendered at the *outer* frame's height
    /// instead of its own `trackHeight` constant (24pt, back when the outer frame was sized to the
    /// bigger old thumb), so shrinking the thumb and its outer frame to fit inside the track also
    /// shrank the track itself to match, which wasn't the intent — only the thumb was meant to
    /// change size.
    ///
    /// `.hairline`: a thin line instead of a filled groove — same footprint (`trackHeight`, for
    /// consistent hit-testing/layout across every slider regardless of style) but only a 2pt line
    /// actually draws, callback to the even-earlier design mentioned in the struct doc comment.
    @ViewBuilder
    private var track: some View {
        switch trackStyle {
        case .capsule:
            RoundedRectangle(cornerRadius: trackHeight / 2)
                .strokeBorder(uiColors.recessedTrackBackground, lineWidth: 1)
                .background(
                    uiColors.recessedTrackBackground
                        .clipShape(RoundedRectangle(cornerRadius: trackHeight / 2))
                )
                .frame(height: trackHeight)
        case .hairline:
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(height: 2)
                .frame(height: trackHeight)
        }
    }

    /// One "control dial" shape experiment per `thumbShape` case — `.circle` is the established
    /// glossy-dot look (`thumbFill`'s off-center radial gradient); the others are flatter, plain
    /// white for now since they're still being tried rather than adopted.
    @ViewBuilder
    private var thumb: some View {
        switch thumbShape {
        case .circle:
            Circle()
                .fill(thumbFill)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.75))
                .frame(width: thumbDiameter, height: thumbDiameter)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        case .diamond:
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.black.opacity(0.18), lineWidth: 0.75))
                .frame(width: thumbDiameter * 0.72, height: thumbDiameter * 0.72)
                .rotationEffect(.degrees(45))
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
    }

    /// A slightly off-center highlight (rather than a flat, uniform white fill) — reads as a
    /// small glossy bead catching light from the upper-left, instead of a flat painted disc.
    /// Paired with `thumbRim`-equivalent stroke + a slightly heavier drop shadow than before for
    /// more physical presence, since a flat fill read as visually inert next to the wheels'
    /// own puck (which gets similar dimensionality from `ColorWheelControl`'s hue-spectrum fill).
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

    /// Drawn *inside* the track (between its background fill and the thumb), not below it as a
    /// separate ruler row — keeps this control's overall footprint identical whether `ticks` is
    /// used or not, rather than growing taller only for Exposure.
    private func tickMarks(width: CGFloat) -> some View {
        Canvas { context, _ in
            for tick in ticks where range.contains(tick) {
                let x = fraction(for: tick) * width
                let isZero = tick == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: 6))
                path.addLine(to: CGPoint(x: x, y: trackHeight - 6))
                context.stroke(path, with: .color(.white.opacity(isZero ? 0.32 : 0.16)), lineWidth: isZero ? 1 : 0.75)
            }
        }
        .frame(height: trackHeight)
        .allowsHitTesting(false)
    }
}
