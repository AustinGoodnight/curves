# Performance notes

Hard-won rules for keeping the grid and editor responsive on a large (1,700+ photo) library.
Read this before adding anything to a SwiftUI `body` in this app.

## Known performance trap: computed properties read in `body`

Hit five times now (twice on the same "just gate it" half-fix, once inside a helper function
rather than `body` itself) — read this before adding anything to `ContentView.body`/
`toolbarContent`, `CullingGridView.body`, or any other SwiftUI `body` or the functions it calls.

**The rule, stated plainly: a `var` computed property that does real work (filters/scans/sorts an
`@Query` array, walks a relationship) must never be read directly inside `body`. Cache it in
`@State` and recompute only from `.onChange(of:)` on the specific inputs that can actually change
the answer.** A computed property re-runs on *every* re-render of the view it's declared on, for
*any* reason — not just the reason you had in mind when you wrote it. "It's just a filter, that's
cheap" is exactly what went wrong all three times; verify against a real, large library (1000+
photos here), not a handful of test photos, and don't reason about it from how often you *expect*
`body` to run — that number is always higher than it looks.

### Why `body` reruns more than you'd guess

`ContentView` (`Curves/Curves/ContentView.swift`) is pushed to a `NavigationStack`, and
`EditorView` is pushed on top of it via `navigationDestination` — `ContentView` is never dismissed
while the editor is open, it's just visually covered, and it keeps re-rendering underneath.
SwiftData's `@Query` also re-fires broadly: editing *any* tracked entity anywhere in the store
(including several relationship-hops away from `PhotoAsset`, e.g. a `Stage`'s own fields) is
enough to re-invoke `ContentView.body`. And of course any plain `@State` change (e.g. `selection`
on every click) reruns `body` too — that one's obvious, but it's easy to forget that a computed
property sitting in `toolbarContent` pays its full cost on *that* rerun as well, not just on the
`@Query`-driven ones.

### The five incidents

1. `CullingGridView`/`filteredAssets`'s O(n²)-ish stack-grouping pass, run on every editor slider
   tick even though the grid was hidden. Fixed by gating `CullingGridView`'s *construction* behind
   `if editingAsset == nil` — a legitimate fix here because the grid is a `View`, not a plain
   computed property, and constructing-but-not-showing it was the actual waste.
2. `commonSessionForSelection`/`scenesInCommonSession` (added for the Stages feature) scanning all
   of `allAssets` on every editor slider tick. **First attempt: gated the two computed properties
   behind `editingAsset == nil`** — this only patched the editor-open trigger and left them running
   full-cost on every plain grid click, because a computed property doesn't know or care *why*
   `body` reran.
3. Same two properties, still laggy on plain selection clicks (not just in the editor) — because
   the gate from #2 didn't address the root cause. **Real fix:** converted them to `@State`,
   recomputed only via `.onChange(of: selection)` / `.onChange(of: editingAsset)`. This is the
   pattern to copy — not the gate from #2, which is now redundant but harmless.
4. `CullingGridView.displayItems` — a computed property that rebuilds the *entire* grid's worth of
   items (with an O(n) inner scan per stack) from scratch on every access, same shape as incident
   #1. Adding the scene-border-wrapping feature introduced `currentScene(at:)`/
   `sceneBorderInfo(at:)`, called once per *visible cell* and internally reading `displayItems`
   (via the computed property, not a cached value) up to 10 times each — roughly 10 full rebuilds
   of a 1000+ item list, per visible cell, on every render. **Fix:** compute it **once per `body`
   evaluation** into a local `let items`, and thread it through every helper (`cell(for:at:in:)`,
   `sceneBorderInfo(at:in:)`, `currentScene(at:in:)`) as a parameter instead of letting them each
   read the computed property independently.
5. `ContentView.filteredAssets` — a plain computed property (filter by scene/session/rating/flag,
   then sort) read directly at the `CullingGridView(assets: filteredAssets, ...)` call site in
   `body`. Selecting a photo mutates `selection`, a `ContentView` `@State` var, which reruns
   `body`, which re-filtered and re-sorted the whole library on *every single click*. **Fix:**
   cached in `@State`, recomputed via `refreshFilteredAssets()` called from `onChange` on the real
   filter/sort inputs and explicitly after every mutation that can change the answer.

### Rule going forward

Before adding a new computed property, toolbar item, or sidebar row that reads `allAssets`/
`displayItems` (or `scenes`/`sessions` at nontrivial size) inside `body` **or in a function called
from `body` per-cell/per-row**: either make it `@State` populated from `.onChange(of:)` on its real
inputs, or compute it once per `body` pass into a local `let` and pass that down explicitly. Only
skip both if the computation is genuinely O(1) or O(selection.count) — and if you're not sure which
it is, assume it isn't. And when a per-cell helper calls another per-cell helper, multiply the cost
by both the fan-out *and* the number of visible cells before deciding it's fine.

## Known performance trap: frequently-mutated state living on the wrong view

A second, distinct performance trap, hit chasing the same underlying symptom ("selecting a photo
is laggy", then "editing a photo is laggy") after every fix above landed and it *still* wasn't
fast. Found in sequence via temporary `print`-based timing
instrumentation (bracket the suspect code with wall-clock marks, rebuild, reproduce, read the log):

1. **`@State` invalidates the *entire* view that declares it, not just the part that visually
   changed.** `selection`/`editingAsset`/filters used to be plain `@State` directly on
   `ContentView`, which also builds the `NavigationSplitView` (sidebar + macOS window toolbar).
   Every click mutated `selection`, which reran *all* of `ContentView.body`, which meant fully
   re-diffing the sidebar and toolbar on every click — measured at a **fixed ~180-200ms cost,
   identical whether the current filter showed 12 or 1708 photos**. **Fix:** moved all of it into
   `DetailStore`, an `@Observable` reference type (`DetailPaneView.swift`) held by `ContentView`
   via `@State private var detailStore = DetailStore()`. Swift's Observation framework scopes
   invalidation to whichever view's `body` actually *read* a property, not to who owns the object
   reference — as long as `ContentView.body` never reads a `detailStore.x` property's *value*
   directly (only forwards `Binding`s or the object reference itself to children), a `selection`
   change only invalidates the small child view that actually reads it. A Menu inside the toolbar
   reading `commonSessionForSelection`/`scenesInCommonSession` (derived state, mutated a beat after
   `selection` via `.onChange`) had to be pulled into its own `OrganizeMenu: View` for the same
   reason — a distinct `View` type gets its own independently-tracked `body`.
2. **`@Model` (SwiftData) properties participate in Observation too — reading them inside a tracked
   `body` registers a dependency on *that object*, not just on the containing array.**
   `CullingGridView`'s `displayItems` computed property touched `.stack`/`.id`/`.photos` on every
   asset in the current filter, read directly at the top of `CullingGridView.body`. On a
   1708-asset library that's ~3000+ dependency edges rebuilt on *every* render, and meant
   `CullingGridView` could be invalidated a second time by *unrelated* SwiftData background
   activity touching any of those objects. **Fix:** moved the grouping computation into
   `DetailStore.rebuildDisplayItems()` — an ordinary (untracked) method, only ever called from
   `.onChange`/action closures, never from a tracked `body` — and gave `CullingGridView` the
   *result* as a plain `let [DisplayItem]` parameter instead.
3. **`GeometryReader` forces a full second layout pass of everything inside it, on every render,
   regardless of whether the measured size actually changed** — confirmed by temporarily deleting
   it entirely and watching a mysterious second `CullingGridView.body` pass disappear completely.
   For a 1708-item `LazyVGrid`, that second pass cost ~150-200ms on *every single click or
   arrow-key press*. **Fix:** replaced the `GeometryReader`-driven responsive column count with a
   fixed `let columnCount = 7`. A real trade (no more reflow on window resize), not a free
   optimization.
4. Every slider in the editor writes live to a `PhotoAsset`/`Stage` field on every single drag
   tick (not debounced, by design — see `EditorRenderCoordinator.scheduleRender`'s doc comment).
   `ContentView` holds `@Query var allAssets`/`scenes`/`sessions`, and SwiftData's broad
   change-tracking means *any* of those queries can be considered "possibly changed" by a
   completely unrelated field mutation, re-invoking `ContentView.body` on every tick. **Fix:** made
   `SidebarView` and the grid-only content `Equatable` (comparing their actual inputs — `sessions`/
   `scenes`/`allAssets` — not their closures) and applied `.equatable()` at their call sites.
   `PhotoAsset`/`Session`/`PhotoScene` all have SwiftData-synthesized `Equatable` based on
   *persistent identity*, not field values, so `[PhotoAsset] == [PhotoAsset]` for the same objects
   stays `true` even after a slider mutates one of their fields — `.equatable()` uses that to let
   SwiftUI skip re-invoking `body` entirely when nothing in the comparison actually changed.
5. **`.equatable()` must never wrap a view that contains an active `.navigationDestination` push —
   attach `NavigationStack`/`.toolbar`/`.navigationDestination` to a plain, non-equatable `Group`,
   with the equatable-wrapped content nested *inside* it, not the other way around.** Hit twice:
   first by pulling the grid *and* the `NavigationStack`/toolbar/`.navigationDestination` into one
   view type and wrapping the whole thing in `.equatable()` — `.equatable()` correctly stopped
   that view's `body` from re-running, but `ContentView.body`'s own reconciliation cost was
   *unaffected*. Second attempt kept `NavigationStack`/toolbar/`.navigationDestination` inline in
   `ContentView.body` but still attached them directly to `GridPane(...).equatable()` instead of a
   plain wrapping `Group` — same regression, reproduced immediately. **Real fix:**
   `Group { GridPane(...).equatable() }.navigationTitle(...).toolbar { ... }.navigationDestination(...)`
   — the equatable wrapper must be *inside* the modifier chain that includes `.navigationDestination`,
   never the direct target of it.
6. **The actual, final root cause, and the one that mattered most: reading `@Query var allAssets`
   — even just to pass it as a value parameter to a child view, never touching its contents inside
   this view — costs real time (~250ms measured on this 1708-asset library) on this SDK,
   independent of what's done with the value.** This is *not* about SwiftUI diffing,
   `.equatable()`, or Observation bookkeeping — confirmed by bisecting `ContentView` down to a
   single, completely inert, unused `@State private var dummy = 0`, which did *not* reproduce any
   lag, ruling those out cleanly. The actual mechanism: every editor slider tick makes `@Query`
   consider `allAssets` "possibly changed" and forces `ContentView.body` to re-run (as documented
   above) — and if *anything* in that body reads `allAssets`'s value unconditionally (not gated
   behind `editingAsset == nil`, and not deferred into a closure/action-handler that only runs on
   user interaction), that read alone pays the cost, every tick, regardless of `.equatable()`/
   gating anywhere else in the view. Two separate call sites did this and **both** had to be fixed
   before the editor stopped lagging: `GridPane(allAssets: allAssets, ...)` being constructed
   unconditionally in `ContentView.body` (gating moved to wrap its *construction* —
   `if editingAsset == nil { GridPane(...) }` — not just a check inside `GridPane.body`, which
   still let the parent's construction read `allAssets` every tick even though the grid itself
   never rendered), and the toolbar's `EditButton` taking `allAssets` as a stored value parameter
   instead of a closure that captures it lazily (a closure referencing `allAssets` only reads it
   when the closure actually *executes* — i.e. on tap — not when it's constructed).
   **False lead worth recording precisely because it was so convincing:** partway through this
   investigation, several hours of continuous rebuilding produced enough host-machine memory
   pressure (confirmed via `vm_stat`/`sysctl vm.swapusage`: ~1.3GB swap, ~100MB free pages) that
   even the *literal unmodified original code*, checked out fresh via `git stash`, reproduced an
   apparently identical ~250ms lag — which looked like conclusive proof the bug was environmental,
   not code. **It wasn't.** The tell, in hindsight: that memory-pressure symptom was *system-wide*
   and non-specific (any expensive operation was slow, including a one-time RAW render spiking to
   2.5 seconds). The real bug is a *specific, narrow, always-reproducible* code pattern — confirmed
   by testing on a freshly restarted machine (zero memory pressure) where the *actual* fixed
   architecture still lagged and the original still didn't, which is what finally forced a real,
   correct bisection instead of accepting the environmental explanation. **Lesson: a plausible
   environmental explanation that "resolves" a symptom on restart is not proof the code is
   innocent — it may just mean the environmental noise was drowning out a real, smaller, code-level
   effect that a clean machine makes newly visible.** Re-test the actual claim (does *this specific
   code change* reproduce the symptom on a clean baseline?) before accepting "the machine was
   under load" as the final answer.

### Rule going forward (state ownership and `@Query` reads)

Before adding new `@State` to a view that also owns "expensive to re-diff" content (a toolbar, a
sidebar, a large list/grid): ask whether that `@State` changes on a high-frequency event (every
click/keystroke) or a low-frequency one. High-frequency state belongs on the *smallest* view that
actually needs to react to it. Before wrapping a large scrollable/lazy list in `GeometryReader` for
responsive sizing, weigh that against the cost of a full re-layout pass on every state change. If a
view's parent is forced to re-run for reasons unrelated to what that view displays, and the view's
real inputs are otherwise `Equatable`, make the view `Equatable` and call `.equatable()` at its use
site — but never on a view that itself hosts `NavigationStack`/`.navigationDestination` (incident
#5); wrap it in a plain `Group` instead and put `.equatable()` on the content nested inside.

**Most importantly: never pass `allAssets`/`scenes`/`sessions` (or any `@Query` property) as a
plain value parameter to anything that gets constructed on every `body` pass, unless that
construction is already gated behind something that makes it genuinely necessary.** Every such
parameter is a read of the `@Query` property at construction time, and on this SDK/library size
that read alone costs real time (~250ms), independent of whether anything is done with the value
and independent of `.equatable()` anywhere downstream. Two ways to avoid it: gate the *construction
site* itself (`if editingAsset == nil { SomeView(allAssets: allAssets, ...) }`, not a check inside
`SomeView.body`), or hand over a closure that captures the property and reads it lazily, only when
the closure actually executes (e.g. a button's action, not its construction). If a symptom that
looks exactly like this keeps recurring no matter how much `.equatable()`/state-extraction gets
applied, stop and grep every call site in the suspect `body` for a `@Query` property passed as a
bare value — that's a stronger signal than another round of Observation-framework theorizing.
