import SwiftUI

/// The full-width, filled-box "module button" look — accent-tinted fill with accent text when
/// enabled, a faint neutral fill with secondary text when not. Used by the culling grid's export
/// bar (`ExportBarView`)'s "Export Selection"/"Export All" buttons.
struct FilledActionButtonStyle: ButtonStyle {
    var isEnabled: Bool = true
    @Environment(ColorSchemeStore.self) private var uiColors

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(isEnabled ? uiColors.accentColor : Color.secondary)
            .background(
                isEnabled ? uiColors.accentColor.opacity(configuration.isPressed ? 0.25 : 0.15) : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}
