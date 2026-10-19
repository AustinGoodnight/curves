import Foundation

/// One per asset (keyed by `PhotoAsset.filePath`), bumped whenever that asset's entry in
/// `ThumbnailCache` changes so a thumbnail view can notice without polling. A dedicated
/// `@Observable` box per key, rather than a single shared counter or dictionary read directly in
/// `body`, so that bumping one asset's thumbnail only invalidates whichever thumbnail views are
/// currently reading *that* box's `value` — not every visible thumbnail cell. Reading
/// `ThumbnailInvalidationBus.shared.box(for:)` itself never registers an Observation dependency
/// (it's a plain method on a non-`@Observable` class); only the returned box's `value` is tracked,
/// which is what keeps this scoped instead of falling into the "one `@State` invalidates everything
/// that reads it" trap `docs/PERFORMANCE.md` documents at length.
@Observable
final class ThumbnailVersionBox: @unchecked Sendable {
    var value = 0
}

/// Only ever touched from the main thread in practice (SwiftUI view bodies, and
/// `EditorRenderCoordinator`'s `@MainActor` render callbacks) — `@unchecked Sendable` rather than an
/// actor so `body` can read it synchronously without an `await`, matching `ThumbnailCache`'s own
/// concurrency story.
final class ThumbnailInvalidationBus: @unchecked Sendable {
    static let shared = ThumbnailInvalidationBus()

    private var boxes: [String: ThumbnailVersionBox] = [:]

    private init() {}

    func box(for key: String) -> ThumbnailVersionBox {
        if let existing = boxes[key] { return existing }
        let box = ThumbnailVersionBox()
        boxes[key] = box
        return box
    }

    func bump(_ key: String) {
        box(for: key).value += 1
    }
}
