import Foundation
import PhotoCatalog

/// In-session undo/redo *and* a browsable running history — every slider, module bypass switch,
/// curve point, mask paint, LUT selection, "Reset"/"Reset All", and version restore touching the
/// asset's base params and its currently active stages. Backed by a plain, explicit
/// `[Entry]` + `currentIndex` rather than `Foundation.UndoManager`: Cmd+Z/Cmd+Shift+Z only need
/// "step back/forward one," but the history *list* (`EditHistoryListView`) needs to jump straight
/// to any past entry, not just walk one step at a time — `UndoManager`'s stack is opaque (no way
/// to enumerate it for display), so once a browsable list was the goal, a plain array was simpler
/// than maintaining an array in parallel with a black-box stack that duplicates it.
///
/// One instance lives per `EditorView` session (`EditorView`'s `@State`), reset on every photo
/// switch (`reset(asset:activeStages:)`) — history does not persist across photos or app restarts,
/// matching a standard in-app Cmd+Z stack rather than a permanent log.
///
/// Scope: structural changes — adding/deleting/renaming a stage, or flipping a stage's own
/// `isEnabled` switch in the Stages list — are **not** tracked here. Those change which `Stage`
/// objects are even part of the composite, which this snapshot-and-restore approach (built for
/// diffing a *fixed* set of stages' field values) isn't set up to reverse. `registerChange`'s
/// guard is what happens when one sneaks in between two tracked edits: history is just reset to a
/// fresh single-entry baseline, rather than attempting a diff it can't safely reverse.
@MainActor
@Observable
final class EditHistory {
    /// One committed point in the timeline. `label` is a best-effort description of what changed
    /// (`EditSnapshot.changeLabel(from:to:)`) — cosmetic only, never used to decide what to
    /// restore; `snapshot` is the actual source of truth for that.
    struct Entry: Identifiable {
        let id = UUID()
        let label: String
        let date: Date
        let snapshot: EditSnapshot
    }

    @ObservationIgnored private var asset: PhotoAsset?
    @ObservationIgnored private var activeStages: [Stage] = []
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var settleGeneration = 0

    /// Set by `EditorView` to re-schedule a render (through `EditorRenderCoordinator` directly,
    /// bypassing this same history) after a jump writes values straight onto the model objects —
    /// those writes don't go through the usual `bind`/`stageBind` setters that normally trigger a
    /// render.
    @ObservationIgnored var onRestore: (() -> Void)?

    /// Newest-last (append order) — `EditHistoryListView` reverses this for display. Always has
    /// at least one entry once `reset(asset:activeStages:)` has run.
    private(set) var entries: [Entry] = []
    /// Which `entries` index the live model objects currently reflect.
    private(set) var currentIndex = 0

    var canUndo: Bool { currentIndex > 0 }
    var canRedo: Bool { currentIndex < entries.count - 1 }

    /// Establishes a fresh single-entry baseline — loading a photo, or recovering from a
    /// structural change (see the type's doc comment), isn't itself a trackable edit.
    func reset(asset: PhotoAsset, activeStages: [Stage]) {
        settleTask?.cancel()
        self.asset = asset
        self.activeStages = activeStages
        let baseline = EditSnapshot(asset: asset, activeStages: activeStages)
        entries = [Entry(label: "Opened", date: Date(), snapshot: baseline)]
        currentIndex = 0
    }

    /// Called from the same `scheduleRender(for:activeStages:coordinator:history:)` chokepoint
    /// every value-level edit already goes through, right after the mutation. Debounced so a
    /// whole slider drag (many calls a frame apart) coalesces into a single history entry instead
    /// of one per tick.
    func registerChange(asset: PhotoAsset, activeStages: [Stage]) {
        guard entries.indices.contains(currentIndex),
              entries[currentIndex].snapshot.stageIDs == Set(activeStages.map(\.id))
        else {
            reset(asset: asset, activeStages: activeStages)
            return
        }
        self.asset = asset
        self.activeStages = activeStages
        settleGeneration += 1
        let generation = settleGeneration
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, generation == self.settleGeneration else { return }
            self.commit()
        }
    }

    /// The burst has settled — diff against the entry we're currently sitting at. Making a new
    /// edit after undoing discards the redo tail first, same as every editor's standard undo
    /// behavior (Lightroom, Photoshop, text editors): there's no meaningful "redo" once history
    /// has forked. Then, if what just changed is the *same* field/module the entry we're sitting
    /// at already represents, that entry's "after" state is updated in place instead of appending
    /// a new one — nudging the same slider three times in a row is one history step, not three,
    /// with the original before-state (whatever's one entry further back) staying put throughout.
    private func commit() {
        guard let asset else { return }
        let before = entries[currentIndex].snapshot
        let after = EditSnapshot(asset: asset, activeStages: activeStages)
        guard after != before else { return }
        let label = EditSnapshot.changeLabel(from: before, to: after)
        entries.removeLast(entries.count - 1 - currentIndex)
        if currentIndex > 0, entries[currentIndex].label == label {
            entries[currentIndex] = Entry(label: label, date: Date(), snapshot: after)
        } else {
            entries.append(Entry(label: label, date: Date(), snapshot: after))
            currentIndex = entries.count - 1
        }
    }

    func undo() {
        guard canUndo else { return }
        jump(to: currentIndex - 1)
    }

    func redo() {
        guard canRedo else { return }
        jump(to: currentIndex + 1)
    }

    /// Jumps straight to any entry — not just one step at a time — so `EditHistoryListView` can
    /// let a click land anywhere in the timeline, the same way Lightroom's History panel does.
    /// `undo()`/`redo()` are just `jump(to:)` with the adjacent index.
    func jump(to index: Int) {
        guard let asset, entries.indices.contains(index) else { return }
        settleTask?.cancel()
        entries[index].snapshot.apply(to: asset)
        currentIndex = index
        onRestore?()
    }
}
