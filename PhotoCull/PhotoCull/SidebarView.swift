import SwiftUI
import PhotoCatalog

struct SidebarView: View {
    let scenes: [PhotoScene]
    @Binding var selectedScene: PhotoScene?
    var onNewScene: () -> Void
    var onDeleteScene: (PhotoScene) -> Void

    var body: some View {
        List {
            Section("Library") {
                row(title: "All Photos", systemImage: "photo.on.rectangle", isSelected: selectedScene == nil) {
                    selectedScene = nil
                }
            }
            Section("Scenes") {
                ForEach(scenes) { scene in
                    row(title: scene.name, systemImage: "rectangle.stack", isSelected: selectedScene?.id == scene.id) {
                        selectedScene = scene
                    }
                    .contextMenu {
                        Button("Delete Scene", role: .destructive) {
                            onDeleteScene(scene)
                        }
                    }
                }
                Button {
                    onNewScene()
                } label: {
                    Label("New Scene…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }

    private func row(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}
