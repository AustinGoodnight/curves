import SwiftUI

/// Small view builders shared across the editor's control clusters (`EditorSidebarView`,
/// `ColorBalanceBarView`, `EditorFooterActions`). Free functions rather than methods on any one
/// view, since more than one of those clusters uses them.

func resetButton(disabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "arrow.counterclockwise.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
}

/// Flat, borderless replacement for `Form`'s boxed `Section` — a plain header + content stack,
/// no background/chrome. `title == nil` renders content alone (used for a trailing button row
/// that doesn't want a header). Passing `onReset` adds a small reset icon next to the header;
/// passing `enabled` adds a module bypass switch (see `PhotoAsset.editColorBalanceEnabled` and
/// its siblings — skips the module's `CIColorKernel` pass entirely when off, not just at its
/// no-op defaults).
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
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let onReset {
                    resetButton(disabled: resetDisabled, action: onReset)
                }
                if let enabled {
                    Spacer()
                    Toggle("", isOn: enabled)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
        }
        content()
    }
}

/// `resetValue` is what double-clicking the slider sets it to — pass the same value used as the
/// binding's own fallback wherever that fallback isn't 0 (`MinimalSlider`'s default), e.g. a
/// camera-dependent default like `coordinator.renderer.defaultExposure`.
func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, resetValue: Double? = nil) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack {
            Text(title)
            Spacer()
            Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
        MinimalSlider(value: value, range: range, resetValue: resetValue)
    }
}

/// The Temp/Tint faders' fixed height — `EditorView.wheelDiameter` is derived from this (not the
/// other way around) so the color wheels come out the same height as these, not vice versa.
let colorFaderTrackHeight: CGFloat = 200

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
    resetValue: Double? = nil
) -> some View {
    VStack(spacing: 8) {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
        VerticalGradientSlider(value: value, range: range, gradient: gradient, resetValue: resetValue)
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
}
