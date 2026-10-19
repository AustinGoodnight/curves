import SwiftUI
import PhotoCatalog

/// Shown after picking a folder to import, only when that folder isn't already bound to an
/// existing `Session` — `ContentView.importFolder()` resumes silently into an already-bound
/// session instead of showing this sheet. Since a `Session` maps 1:1 to a folder (see its doc
/// comment), there's never a valid *existing* session to offer for a folder that reaches this
/// sheet at all — naming a new one is the only choice.
struct SessionPickerSheet: View {
    @Binding var newSessionName: String
    var onCreate: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Into Session")
                .font(.headline)
            Text("Name a new session for these photos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                TextField("New Session Name", text: $newSessionName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onCreate(newSessionName) }
                Button("Create") { onCreate(newSessionName) }
                    .disabled(newSessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
