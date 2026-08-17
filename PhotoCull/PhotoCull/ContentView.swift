import SwiftUI
import SwiftData
import AppKit
import PhotoCatalog

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PhotoAsset.captureDate, order: .reverse) private var allAssets: [PhotoAsset]

    @State private var ratingFilter: Int = 0
    @State private var flagFilter: FlagState?
    @State private var sortOption: SortOption = .captureDateDesc
    @State private var importStatus: String?

    enum SortOption: String, CaseIterable, Identifiable {
        case captureDateDesc = "Newest First"
        case captureDateAsc = "Oldest First"
        case ratingDesc = "Highest Rated"
        case fileName = "File Name"
        var id: String { rawValue }
    }

    private var filteredAssets: [PhotoAsset] {
        var result = allAssets
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
        NavigationStack {
            CullingGridView(assets: filteredAssets)
                .navigationTitle("PhotoCull")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            importFolder()
                        } label: {
                            Label("Import Folder", systemImage: "folder.badge.plus")
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
        .alert("Import", isPresented: Binding(
            get: { importStatus != nil },
            set: { if !$0 { importStatus = nil } }
        ), presenting: importStatus) { _ in
            Button("OK") { importStatus = nil }
        } message: { status in
            Text(status)
        }
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let importer = LibraryImporter()
        let files = importer.scanFolder(at: url)
        do {
            let count = try importer.importFiles(files, into: modelContext)
            importStatus = "Imported \(count) new file\(count == 1 ? "" : "s") (\(files.count) RAW file\(files.count == 1 ? "" : "s") found)."
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
        }
    }
}
