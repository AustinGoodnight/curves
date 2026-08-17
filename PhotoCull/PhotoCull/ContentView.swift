import SwiftUI
import SwiftData
import AppKit
import PhotoCatalog

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PhotoAsset.captureDate, order: .reverse) private var allAssets: [PhotoAsset]
    @Query(sort: \PhotoScene.name) private var scenes: [PhotoScene]

    @State private var selectedScene: PhotoScene?
    @State private var selection: Set<UUID> = []
    @State private var ratingFilter: Int = 0
    @State private var flagFilter: FlagState?
    @State private var sortOption: SortOption = .captureDateDesc
    @State private var importStatus: String?
    @State private var isShowingNewSceneAlert = false
    @State private var newSceneName = ""
    @State private var addSelectionToNewScene = false
    @State private var refreshTrigger = 0

    enum SortOption: String, CaseIterable, Identifiable {
        case captureDateDesc = "Newest First"
        case captureDateAsc = "Oldest First"
        case ratingDesc = "Highest Rated"
        case fileName = "File Name"
        var id: String { rawValue }
    }

    private var filteredAssets: [PhotoAsset] {
        var result = allAssets
        if let selectedScene {
            result = result.filter { asset in asset.scenes?.contains(where: { $0.id == selectedScene.id }) == true }
        }
        if ratingFilter > 0 {
            result = result.filter { $0.rating >= ratingFilter }
        }
        if let flagFilter {
            result = result.filter { $0.flag == flagFilter }
        }
        switch sortOption {
        case .captureDateDesc:
            result.sort { ($0.captureDate ?? $0.importDate) > ($1.captureDate ?? $1.importDate) }
        case .captureDateAsc:
            result.sort { ($0.captureDate ?? $0.importDate) < ($1.captureDate ?? $1.importDate) }
        case .ratingDesc:
            result.sort { $0.rating > $1.rating }
        case .fileName:
            result.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        }
        return result
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                scenes: scenes,
                selectedScene: $selectedScene,
                onNewScene: { addSelectionToNewScene = false; newSceneName = ""; isShowingNewSceneAlert = true },
                onDeleteScene: deleteScene
            )
        } detail: {
            NavigationStack {
                CullingGridView(
                    assets: filteredAssets,
                    selection: $selection,
                    onGroupStack: groupSelectedIntoStack,
                    onUnstack: unstackSelected
                )
                .id(refreshTrigger)
                .navigationTitle(selectedScene?.name ?? "PhotoCull")
                .toolbar { toolbarContent }
                .overlay {
                    if allAssets.isEmpty {
                        ContentUnavailableView(
                            "No Photos",
                            systemImage: "photo.on.rectangle.angled",
                            description: Text("Import a folder of RAW files to get started.")
                        )
                    } else if filteredAssets.isEmpty {
                        ContentUnavailableView(
                            "No Matches",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("No photos match the current filter.")
                        )
                    }
                }
            }
        }
        .alert("Import", isPresented: Binding(
            get: { importStatus != nil },
            set: { if !$0 { importStatus = nil } }
        ), presenting: importStatus) { _ in
            Button("OK") { importStatus = nil }
        } message: { status in
            Text(status)
        }
        .alert("New Scene", isPresented: $isShowingNewSceneAlert) {
            TextField("Scene Name", text: $newSceneName)
            Button("Cancel", role: .cancel) { newSceneName = "" }
            Button("Create") { createScene(named: newSceneName, addSelection: addSelectionToNewScene) }
        } message: {
            Text("Enter a name for the new scene.")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                importFolder()
            } label: {
                Label("Import Folder", systemImage: "folder.badge.plus")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Group Selected into Stack (G)") { groupSelectedIntoStack() }
                    .disabled(selection.count < 2)
                Button("Unstack Selected (⇧G)") { unstackSelected() }
                    .disabled(selection.isEmpty)
                Divider()
                Menu("Add Selected to Scene") {
                    ForEach(scenes) { scene in
                        Button(scene.name) { addSelected(to: scene) }
                    }
                    if !scenes.isEmpty { Divider() }
                    Button("New Scene…") {
                        addSelectionToNewScene = true
                        newSceneName = ""
                        isShowingNewSceneAlert = true
                    }
                }
                .disabled(selection.isEmpty)
                if selectedScene != nil {
                    Button("Remove Selected from This Scene") { removeSelectedFromCurrentScene() }
                        .disabled(selection.isEmpty)
                }
            } label: {
                Label("Organize", systemImage: "square.stack.3d.up")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort", selection: $sortOption) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Minimum Rating", selection: $ratingFilter) {
                    Text("All Ratings").tag(0)
                    ForEach(1...5, id: \.self) { r in
                        Text("\(r)+ Stars").tag(r)
                    }
                }
                Divider()
                Picker("Flag", selection: $flagFilter) {
                    Text("All Flags").tag(FlagState?.none)
                    Text("Picked").tag(FlagState?.some(.pick))
                    Text("Rejected").tag(FlagState?.some(.reject))
                    Text("Unflagged").tag(FlagState?.some(.none))
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    private func importFolder() {
        let recursiveOption = RecursiveImportOption()
        let accessory = NSHostingView(
            rootView: Toggle("Include Subfolders", isOn: Binding(
                get: { recursiveOption.recursive },
                set: { recursiveOption.recursive = $0 }
            ))
            .padding(10)
        )
        accessory.frame = NSRect(x: 0, y: 0, width: 240, height: 36)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let importer = LibraryImporter()
        let files = importer.scanFolder(at: url, recursive: recursiveOption.recursive)
        do {
            let count = try importer.importFiles(files, into: modelContext)
            importStatus = "Imported \(count) new file\(count == 1 ? "" : "s") (\(files.count) RAW file\(files.count == 1 ? "" : "s") found)."
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
        }
    }

    private func groupSelectedIntoStack() {
        let selected = allAssets.filter { selection.contains($0.id) }
        guard selected.count >= 2 else { return }

        var touchedStacks = Set<PhotoStack>()
        for asset in selected {
            if let old = asset.stack {
                touchedStacks.insert(old)
                asset.stack = nil
            }
        }
        let newStack = PhotoStack()
        modelContext.insert(newStack)
        for asset in selected {
            asset.stack = newStack
        }
        for old in touchedStacks where (old.photos?.isEmpty ?? true) {
            modelContext.delete(old)
        }
        try? modelContext.save()
        refreshTrigger += 1
    }

    private func unstackSelected() {
        // Selecting a collapsed stack only selects its cover photo, so unstacking must
        // dissolve every member of any touched stack — not just the selected asset —
        // or the other members are silently left behind in an orphaned singleton stack.
        let selected = allAssets.filter { selection.contains($0.id) }
        var touchedStacks = Set<PhotoStack>()
        for asset in selected {
            if let stack = asset.stack {
                touchedStacks.insert(stack)
            }
        }
        for stack in touchedStacks {
            for member in stack.photos ?? [] {
                member.stack = nil
            }
            modelContext.delete(stack)
        }
        try? modelContext.save()
        refreshTrigger += 1
    }

    private func addSelected(to scene: PhotoScene) {
        let selected = allAssets.filter { selection.contains($0.id) }
        for asset in selected where asset.scenes?.contains(where: { $0.id == scene.id }) != true {
            asset.scenes?.append(scene)
        }
        try? modelContext.save()
        refreshTrigger += 1
    }

    private func removeSelectedFromCurrentScene() {
        guard let selectedScene else { return }
        let selected = allAssets.filter { selection.contains($0.id) }
        for asset in selected {
            asset.scenes?.removeAll { $0.id == selectedScene.id }
        }
        try? modelContext.save()
        refreshTrigger += 1
    }

    private func createScene(named name: String, addSelection: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let scene = PhotoScene(name: trimmed)
        modelContext.insert(scene)
        if addSelection {
            let selected = allAssets.filter { selection.contains($0.id) }
            for asset in selected {
                asset.scenes?.append(scene)
            }
        }
        try? modelContext.save()
        newSceneName = ""
        selectedScene = scene
        refreshTrigger += 1
    }

    private func deleteScene(_ scene: PhotoScene) {
        if selectedScene?.id == scene.id {
            selectedScene = nil
        }
        modelContext.delete(scene)
        try? modelContext.save()
        refreshTrigger += 1
    }
}

private final class RecursiveImportOption {
    var recursive = true
}
