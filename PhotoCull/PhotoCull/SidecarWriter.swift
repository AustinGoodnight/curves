import Foundation

/// Encodes and writes sidecar files off the main actor, so a slider drag's debounced settle (see
/// `EditHistory.commit()`) never blocks rendering. Callers build the `Sendable` sidecar struct
/// synchronously on `@MainActor` (a cheap copy of already-loaded `@Model` field values — SwiftData's
/// `@Model` reference types aren't `Sendable` and can't cross the actor boundary themselves), then
/// hand it to this actor for the actually expensive part: JSON encoding and disk I/O.
actor SidecarWriter {
    static let shared = SidecarWriter()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Pretty-printed + sorted keys: sidecars are meant to be human-inspectable (that's the
        // whole point of moving off an opaque SQLite store), and stable key order keeps a diff of
        // two versions of the same file readable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Atomic write: a crash or interrupted write can never leave a half-written, corrupt sidecar
    /// in place — the rebuild path already treats a failed *decode* as "missing" (see
    /// `SidecarModels.swift`'s doc comment), but that convention only holds if a write itself is
    /// all-or-nothing.
    private func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
    }

    func write(_ sidecar: CurveSidecar, to url: URL) {
        guard let data = try? encoder.encode(sidecar) else { return }
        write(data, to: url)
    }

    func write(_ sidecar: SceneSidecar, to url: URL) {
        guard let data = try? encoder.encode(sidecar) else { return }
        write(data, to: url)
    }

    func write(_ sidecar: StackSidecar, to url: URL) {
        guard let data = try? encoder.encode(sidecar) else { return }
        write(data, to: url)
    }
}
