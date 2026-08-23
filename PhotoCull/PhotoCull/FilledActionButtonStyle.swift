import SwiftUI

/// The full-width, filled-box "module button" look — same visual weight as `EditorSidebarView`'s
/// Filmic toggle: accent-tinted fill with accent text when enabled, a faint neutral fill with
/// secondary text when not. Shared by `EditorFooterActions`'s Reset All/Export… buttons and the
/// culling grid's export bar (`ExportBarView`) so both read as the same primary-action language
/// instead of each rolling its own button chrome.
struct FilledActionButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .background(
                isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.25 : 0.15) : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}
