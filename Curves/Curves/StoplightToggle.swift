import SwiftUI

/// A small lit-indicator dot standing in for the module enable/disable switches (Color Zones,
/// Filmic RGB, RGB Curve) — the app's accent color when on, grey when off, with a soft glow when
/// lit so it actually reads as "lit" rather than just a flat colored circle. Simpler at a glance
/// than a pill-shaped `Toggle`.
struct StoplightToggle: View {
    @Binding var isOn: Bool
    var diameter: CGFloat = 10

    @Environment(ColorSchemeStore.self) private var uiColors
    private static let offColor = Color(white: 0.4)

    private var color: Color {
        isOn ? uiColors.accentColor : Self.offColor
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .shadow(color: isOn ? color.opacity(0.35) : .clear, radius: diameter * 0.2)
            .frame(width: diameter + 12, height: diameter + 12)
            .contentShape(Circle())
            .onTapGesture { isOn.toggle() }
    }
}
