import SwiftUI

/// The "Save Preset" prompt behind both of `StagesSidebarView`'s save actions. A sheet rather than
/// the plain `.alert` it used to be because it needs toggles alongside the name field, which a
/// macOS alert can't host. Exposure is always saved (see `Preset.captureAssetFields`), so it's
/// stated rather than offered as a toggle; white balance and session scoping are opt-in.
struct SavePresetSheet: View {
    struct Options {
        var name: String
        var includeWhiteBalance: Bool
        var keepWithinSession: Bool
    }

    /// `nil` when the open photo somehow has no session — "Keep Within Session" is then disabled.
    let sessionName: String?
    @State var name: String
    var onSave: (Options) -> Void
    var onCancel: () -> Void

    @State private var includeWhiteBalance = false
    @State private var keepWithinSession = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Preset")
                .font(.headline)
            TextField("Preset Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            VStack(alignment: .leading, spacing: 8) {
                Label("Exposure is always included", systemImage: "plusminus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Include White Balance", isOn: $includeWhiteBalance)
                Toggle(isOn: $keepWithinSession) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep Within Session")
                        Text(sessionName.map { "Only shown while editing photos in \u{201C}\($0)\u{201D}" }
                             ?? "This photo isn't in a session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(sessionName == nil)
            }
            .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        onSave(Options(name: trimmedName, includeWhiteBalance: includeWhiteBalance, keepWithinSession: keepWithinSession && sessionName != nil))
    }
}
