import Foundation
import PhotoCatalog

/// A `Session`'s folder identity, persisted *outside* SwiftData — see `KnownSessionFolders`'s doc
/// comment for why this has to exist at all.
struct KnownSessionFolderEntry: Codable {
    var id: UUID
    var name: String
    var bookmarkData: Data?
    var folderPath: String

    /// Same bookmark-first, path-fallback resolution as `Session.resolvedFolderURL()`.
    func resolvedURL() -> URL {
        if let bookmarkData {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return url
            }
        }
        return URL(fileURLWithPath: folderPath)
    }
}

/// A small file outside SwiftData listing every `Session`'s folder — `~/Library/Application
/// Support/PhotoCull/knownSessionFolders.json`. Needed because a post-wipe, freshly-created
/// `ModelContainer` has zero `Session` rows by definition, so nothing *inside* SwiftData can tell
/// `CacheRebuilder` which folders to rescan; this is that pointer, written every time a `Session` is
/// created (see `ContentView`'s session-creation call sites) and read only during a rebuild.
enum KnownSessionFolders {
    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("PhotoCull", isDirectory: true).appendingPathComponent("knownSessionFolders.json")
    }

    static func load() -> [KnownSessionFolderEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([KnownSessionFolderEntry].self, from: data) else { return [] }
        return entries
    }

    /// Idempotent — replaces any existing entry for this session's id rather than duplicating it,
    /// so calling this again after, say, a folder move (which updates `folderBookmarkData`) keeps
    /// the list current instead of accumulating stale rows.
    static func record(_ session: Session) {
        var entries = load()
        entries.removeAll { $0.id == session.id }
        entries.append(KnownSessionFolderEntry(
            id: session.id, name: session.name, bookmarkData: session.folderBookmarkData, folderPath: session.folderPath
        ))
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
