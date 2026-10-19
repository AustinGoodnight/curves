import Foundation
import SwiftData

/// A day/shoot's worth of imported photos — the top-level grouping a photo belongs to. Picked or
/// created by the user at import time (see `LibraryImporter.importFiles(_:into:session:)`).
/// Unlike `PhotoScene` (which nests inside a session and groups photos that should be edited
/// together), a photo belongs to exactly one session for its whole life — re-importing the same
/// file into a different session creates a new, separate `PhotoAsset`.
///
/// Maps 1:1 to exactly one filesystem folder (`folderPath`/`folderBookmarkData`) — every photo in
/// this session lives under that one folder. This is what lets a `PhotoScene`/`PhotoStack`'s
/// `.scene`/`.stack` sidecar manifest (see the app target's sidecar-persistence types) be
/// authoritative for its membership without ambiguity: since every photo in a session shares one
/// folder, every scene/stack nested in it does too, so "the manifest living in this folder" always
/// has an unambiguous place to be. The app target enforces this at import time (a folder already
/// bound to a session imports straight into it; a new folder always creates a new session) rather
/// than this type validating it — same "structural invariant enforced by the one writer, not
/// defended against here" convention as `PhotoScene.photos`' doc comment.
@Model
public final class Session {
    public var id: UUID = UUID()
    public var name: String = ""
    public var createdDate: Date = Date()
    public var folderPath: String = ""
    public var folderBookmarkData: Data?

    @Relationship(deleteRule: .nullify, inverse: \PhotoAsset.session)
    public var photos: [PhotoAsset]? = []

    public init(name: String, folderURL: URL) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.photos = []
        self.folderPath = folderURL.path
        self.folderBookmarkData = try? folderURL.bookmarkData(options: [.minimalBookmark])
    }

    /// Bookmarks survive folder moves/renames within the same volume, same reasoning as
    /// `PhotoAsset.resolvedURL()`; the raw path is the fast-path fallback when no bookmark was
    /// captured (or it fails to resolve).
    public func resolvedFolderURL() -> URL {
        if let folderBookmarkData {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: folderBookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return url
            }
        }
        return URL(fileURLWithPath: folderPath)
    }

    /// Where a `PhotoScene`'s `.scene` manifest lives — flat at the session folder's root
    /// (never nested into subfolders, even when the import that populated this session recursed
    /// into subfolders to find its photos), named by the scene's UUID rather than its
    /// user-editable name so a rename never orphans or collides a manifest file.
    public func sceneManifestURL(sceneID: UUID) -> URL {
        resolvedFolderURL().appendingPathComponent("\(sceneID.uuidString).scene")
    }

    /// Where a `PhotoStack`'s `.stack` manifest lives — same placement/naming reasoning as
    /// `sceneManifestURL(sceneID:)`.
    public func stackManifestURL(stackID: UUID) -> URL {
        resolvedFolderURL().appendingPathComponent("\(stackID.uuidString).stack")
    }
}
