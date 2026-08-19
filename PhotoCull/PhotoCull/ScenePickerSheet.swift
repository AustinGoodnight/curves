import SwiftUI
import PhotoCatalog

/// Quick "assign selection to a scene" popover, triggered by ⌘S in the culling grid. Scenes are
/// pre-scoped by the caller to the session the current selection shares (a scene lives inside one
/// session — see `ContentView.commonSessionForSelection`).
struct ScenePickerSheet: View {
    let scenes: [PhotoScene]
    @Binding var newSceneName: String
    var onPick: (PhotoScene) -> Void
    var onCreate: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to Scene")
                .font(.headline)
            Text("Choose an existing scene or create a new one for the selected photos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !scenes.isEmpty {
                List(scenes) { scene in
                    Button {
                        onPick(scene)
                    } label: {
                        Label(scene.name, systemImage: "rectangle.stack")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .listStyle(.inset)
            }

            HStack {
                TextField("New Scene Name", text: $newSceneName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onCreate(newSceneName) }
                Button("Create") { onCreate(newSceneName) }
                    .disabled(newSceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
