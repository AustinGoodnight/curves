import SwiftUI
import PhotoCatalog

struct SidebarView: View, Equatable {
    let sessions: [Session]
    let scenes: [PhotoScene]
    @Binding var selectedSession: Session?
    @Binding var selectedScene: PhotoScene?
    var onNewScene: (Session) -> Void
    var onDeleteScene: (PhotoScene) -> Void

    static func == (lhs: SidebarView, rhs: SidebarView) -> Bool {
        lhs.sessions == rhs.sessions && lhs.scenes == rhs.scenes
            && lhs.selectedSession == rhs.selectedSession && lhs.selectedScene == rhs.selectedScene
    }

    var body: some View {
        List {
            Section("Library") {
                row(
                    title: "All Photos", systemImage: "photo.on.rectangle",
                    isSelected: selectedScene == nil && selectedSession == nil
                ) {
                    selectedScene = nil
                    selectedSession = nil
                }
            }
            ForEach(sessions) { session in
                Section(session.name) {
                    row(
                        title: "All in Session", systemImage: "calendar",
                        isSelected: selectedScene == nil && selectedSession?.id == session.id
                    ) {
                        selectedScene = nil
                        selectedSession = session
                    }
                    ForEach(scenesFor(session)) { scene in
                        row(title: scene.name, systemImage: "rectangle.stack", isSelected: selectedScene?.id == scene.id) {
                            selectedSession = session
                            selectedScene = scene
                        }
                        .contextMenu {
                            Button("Delete Scene", role: .destructive) {
                                onDeleteScene(scene)
                            }
                        }
                    }
                    Button {
                        onNewScene(session)
                    } label: {
                        Label("New Scene…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.sidebarBackground)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
    }

    private func scenesFor(_ session: Session) -> [PhotoScene] {
        scenes.filter { $0.session?.id == session.id }
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
