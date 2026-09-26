import Foundation
import Observation

/// One `.cube` file found under the LUT folder. `id` is its path relative to the folder, which is
/// also what the hidden-set persists — stable across rescans, and survives the folder itself being
/// moved and re-chosen as long as its internal layout doesn't change.
struct LUTLibraryEntry: Identifiable, Hashable {
    let id: String
    /// The relative path minus `.cube` — just the file name for top-level files, `"Kodak/Portra
    /// 400"` for ones in subfolders, so same-named files in different subfolders stay distinct.
    /// Also what's copied onto `Stage.lut3DTitle` when applied, which is what `FilmSimulationPicker`/`LUTBrowserSidebar`
    /// compares against to highlight the selected row.
    let name: String
    let url: URL
}

/// The film-simulation LUT library — every `.cube` file under a user-chosen folder (Settings >
/// LUTs), minus any the user has hidden there. Replaces the old import-one-file-at-a-time flow
/// (`LUT3DPreset` rows in SwiftData, still in the schema so existing stores don't need a
/// migration, but no longer read anywhere): dropping a file into the folder is all it takes to add
/// one. Files are only listed on scan, never parsed — parsing happens once, on selection, in
/// `ColorBalanceBarView.applyLUT(_:)`, which copies the parsed cube onto the `Stage` exactly as
/// before, so a stage keeps rendering its LUT even if the file later moves or is deleted.
///
/// Shared app-wide via `.environment(_:)` from `PhotoCullApp`, same as `ColorSchemeStore`.
@Observable
final class LUTLibrary {
    private(set) var folderURL: URL?
    /// Every `.cube` under `folderURL`, hidden ones included — Settings lists all of them so they
    /// can be unhidden. Sorted by `name`, case-insensitively.
    private(set) var entries: [LUTLibraryEntry] = []
    private(set) var hiddenIDs: Set<String>

    private static let folderBookmarkKey = "lutFolderBookmark"
    private static let folderPathKey = "lutFolderPath"
    private static let hiddenIDsKey = "lutHiddenIDs"

    init() {
        hiddenIDs = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenIDsKey) ?? [])
        folderURL = Self.loadFolderURL()
        rescan()
    }

    /// What the editor's picker shows.
    var visibleEntries: [LUTLibraryEntry] {
        entries.filter { !hiddenIDs.contains($0.id) }
    }

    func setFolder(_ url: URL) {
        folderURL = url
        let defaults = UserDefaults.standard
        defaults.set(url.path, forKey: Self.folderPathKey)
        defaults.set(try? url.bookmarkData(options: [.minimalBookmark]), forKey: Self.folderBookmarkKey)
        rescan()
    }

    func isHidden(_ entry: LUTLibraryEntry) -> Bool {
        hiddenIDs.contains(entry.id)
    }

    func setHidden(_ hidden: Bool, for entry: LUTLibraryEntry) {
        if hidden { hiddenIDs.insert(entry.id) } else { hiddenIDs.remove(entry.id) }
        UserDefaults.standard.set(hiddenIDs.sorted(), forKey: Self.hiddenIDsKey)
    }

    /// Re-lists the folder. Cheap (a directory walk, no file reads), so it's called whenever the
    /// picker appears, not just on launch — a file dropped into the folder mid-session shows up the
    /// next time the editor opens. Only assigns `entries` when the listing actually changed, so a
    /// no-op rescan doesn't invalidate every view reading it.
    func rescan() {
        let scanned = folderURL.map(Self.scan) ?? []
        if scanned != entries { entries = scanned }
    }

    private static func scan(_ folder: URL) -> [LUTLibraryEntry] {
        let folder = folder.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        var found: [LUTLibraryEntry] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "cube" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            let name = (relative as NSString).deletingPathExtension
            found.append(LUTLibraryEntry(id: relative, name: name, url: url))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Same bookmark-first, path-fallback resolution as `KnownSessionFolderEntry.resolvedURL()`.
    private static func loadFolderURL() -> URL? {
        let defaults = UserDefaults.standard
        if let bookmark = defaults.data(forKey: folderBookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return url
            }
        }
        return defaults.string(forKey: folderPathKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
