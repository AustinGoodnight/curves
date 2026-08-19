import SwiftUI
import PhotoCatalog

/// Shown after picking a folder to import — the user must pick an existing `Session` (e.g. a
/// second card from the same shoot day) or name a new one before the import actually runs, since
/// every `PhotoAsset` belongs to exactly one session for its whole life.
struct SessionPickerSheet: View {
    let sessions: [Session]
    @Binding var newSessionName: String
    var onPick: (Session) -> Void
    var onCreate: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Into Session")
                .font(.headline)
            Text("Choose an existing session or create a new one for these photos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !sessions.isEmpty {
                List(sessions) { session in
                    Button {
                        onPick(session)
                    } label: {
                        Label(session.name, systemImage: "calendar")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .listStyle(.inset)
            }

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
