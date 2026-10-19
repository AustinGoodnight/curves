import SwiftUI

/// Small view builders shared across the editor's control clusters (`EditorSidebarView`,
/// `ColorBalanceBarView`). Free functions rather than methods on any one view, since more than one
/// of those clusters uses them.

extension Font {
    /// The app's own brand face for UI chrome — registered for this process at launch
    /// (`CurvesApp.AppDelegate.registerBundledFonts`) from a variable font (weight 200...800).
    /// Used for every module/section header (`sectionTitle`) so the editor's own chrome reads as a
    /// distinct type family from the system font. Unrelated to the toolbar wordmark (a static SVG
    /// built from a different face — see `ContentView.toolbarContent`'s `.principal` item) —
    /// there's no requirement the two match. `relativeTo:` keeps these scaling with Dynamic Type
    /// the same way the system text style they're replacing (`.subheadline`/`.caption`) would have.
    ///
    /// Pass a real named-instance PostScript name (`"ScoutieSans-Regular"`, `"ScoutieSans-
    /// SemiBold"`, etc. — see the font's own `fvar` table for the full list) rather than
    /// `.custom("ScoutieSans-Regular", ...).weight(.semibold)`: this predecessor's replaced face
    /// (Marmelad) only shipped one weight, so getting a bolder header meant asking macOS to
    /// synthesize a faux-bold by artificially thickening strokes — passable at display sizes, ugly
    /// at small ones. Scoutie Sans actually ships a SemiBold instance, so asking for it directly
    /// gives a real, properly hinted bold design instead of a synthesized one.
    static func scoutieSans(_ postScriptName: String, size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom(postScriptName, size: size, relativeTo: style)
    }
}

func resetButton(disabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "arrow.counterclockwise.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
}

/// A section/module title that also toggles `enabled` when tapped — a bigger, more convenient
/// target than the switch alone, which stays put right next to it as the actual state indicator
/// (tapping the title doesn't remove the visual "is this on" feedback, it just gives a second way
/// to flip it). Plain, non-interactive text when `enabled` is `nil` — a title with nothing to
/// toggle shouldn't look/feel clickable. `font` defaults to the size every full module header uses
/// (Filmic RGB, Curve, Color Balance RGB, …) — `ColorBalanceBarView` overrides it smaller for
/// "Color Zones"/"Film Simulation" so they read as the same weight as its own `titledGroup` labels
/// (WB/Color Wheels/Balance) sharing that row, rather than needing a second near-duplicate helper.
func sectionTitle(
    _ title: String, enabled: Binding<Bool>?, font: Font = .scoutieSans("ScoutieSans-Regular", size: 13, relativeTo: .subheadline)
) -> some View {
    Text(title)
        .font(font)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture {
            enabled?.wrappedValue.toggle()
        }
        .allowsHitTesting(enabled != nil)
}

/// Flat, borderless replacement for `Form`'s boxed `Section` — a plain header + content stack,
/// no background/chrome. `title == nil` renders content alone (used for a trailing button row
/// that doesn't want a header). Passing `onReset` adds a small reset icon next to the header;
/// passing `enabled` adds a module bypass stoplight (see `PhotoAsset.editColorBalanceEnabled` and
/// its siblings — skips the module's `CIColorKernel` pass entirely when off, not just at its
/// no-op defaults) and makes the title itself tap-to-toggle (see `sectionTitle`).
func section<Content: View>(
    _ title: String?,
    resetDisabled: Bool = true,
    onReset: (() -> Void)? = nil,
    enabled: Binding<Bool>? = nil,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        if let title {
            HStack(spacing: 4) {
                sectionTitle(title, enabled: enabled)
                if let onReset {
                    resetButton(disabled: resetDisabled, action: onReset)
                }
                if let enabled {
                    Spacer()
                    StoplightToggle(isOn: enabled)
                }
            }
        }
        content()
    }
}

/// `resetValue` is what double-clicking the slider sets it to — pass the same value used as the
/// binding's own fallback wherever that fallback isn't 0 (`MinimalSlider`'s default), e.g. a
/// camera-dependent default like `coordinator.renderer.defaultExposure`.
func slider(
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>, resetValue: Double? = nil, ticks: [Double] = [],
    trackStyle: MinimalSlider.TrackStyle = .capsule, thumbShape: MinimalSlider.ThumbShape = .circle
) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack {
            Text(title)
                .font(.scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
        MinimalSlider(value: value, range: range, resetValue: resetValue, ticks: ticks, trackStyle: trackStyle, thumbShape: thumbShape)
    }
}

/// The Temp/Tint faders' fixed height — `EditorView.wheelDiameter` is derived from this (not the
/// other way around) so the color wheels come out the same height as these, not vice versa.
let colorFaderTrackHeight: CGFloat = 200

/// Height of the per-control title row directly above each control in `ColorBalanceBarView`
/// ("Global ⟲ ●" over a wheel, "White Balance" over the WB pad, Color Zones' channel tabs) —
/// fixed rather than each control's own natural text height, so that row lines up across every
/// column regardless of whether it carries a stoplight, a reset button, or just text. Fits
/// `StoplightToggle`'s 8pt-diameter hit frame (20pt) plus room for the tabs' underline.
let controlSubtitleHeight: CGFloat = 22

/// Gap between that title row and the control below it — shared for the same reason.
let controlSubtitleSpacing: CGFloat = 6

/// Fixed width for every vertical fader's title-plus-track column (`verticalGradientSlider`/
/// `verticalCircleSlider`) — wide enough to fit the longest label ("Dehaze") without wrapping.
/// Without this, each column's `VStack` sizes itself to its own widest child, and since the
/// track itself is only 18pt wide, that child is the title `Text` — so "Chr"/"Sharp"/"Dehaze"
/// each produced a different column width purely from their own label's character count, even
/// though every track underneath rendered at the same 18pt. Pinning one shared width here is
/// what actually makes every fader column read as the same size next to its neighbors.
let faderColumnWidth: CGFloat = 48

/// Labeled wrapper around `VerticalGradientSlider` — title above, value pill below, matching the
/// chrome `slider()` puts around `MinimalSlider`. `valueText` empty skips the pill entirely
/// rather than rendering an empty box.
func verticalGradientSlider(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    gradient: Gradient,
    valueText: String,
    trackHeight: CGFloat = colorFaderTrackHeight,
    resetValue: Double? = nil,
    diamondThumb: Bool = false
) -> some View {
    VStack(spacing: 8) {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
        VerticalGradientSlider(value: value, range: range, gradient: gradient, resetValue: resetValue, diamondThumb: diamondThumb)
            .frame(height: trackHeight)
        if !valueText.isEmpty {
            Text(valueText)
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
    }
    .frame(width: faderColumnWidth)
}

/// Labeled wrapper around `VerticalCircleSlider` — same title-above/value-pill-below chrome as
/// `verticalGradientSlider`, for the outline-track/circle-thumb style instead.
func verticalCircleSlider(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    valueText: String,
    trackHeight: CGFloat = colorFaderTrackHeight,
    resetValue: Double? = nil,
    diamondThumb: Bool = false
) -> some View {
    VStack(spacing: 8) {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
        VerticalCircleSlider(value: value, range: range, resetValue: resetValue, diamondThumb: diamondThumb)
            .frame(height: trackHeight)
        if !valueText.isEmpty {
            Text(valueText)
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
    }
    .frame(width: faderColumnWidth)
}
