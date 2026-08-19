import CoreGraphics
import Foundation
import RawEngine

/// Owns the renderer, the current preview image, and the histograms — split out of `EditorView`
/// so it's a single stable reference (`@Observable` class identity) that every control cluster
/// can hold without forcing a reconstruction of the *other* clusters every time a render
/// completes. Before this split, all of that state lived as top-level `@State` on `EditorView`
/// itself, and every SwiftUI view lives in one flat `body` unless it's a genuinely separate
/// `View` type — so any single slider tick invalidated the entire editor (all 4 color wheels,
/// both curve editors, every section) on every mouse-move event, not just the control being
/// dragged. See `EditorSidebarView`/`ColorBalanceBarView` for the other half of that split.
@MainActor
@Observable
final class EditorRenderCoordinator {
    let renderer = RawImageRenderer()

    private(set) var previewImage: CGImage?
    private(set) var luminanceHistogram: [Float] = []
    private(set) var hueHistogram: [Float] = []
    private(set) var isReady = false

    private var histogramGeneration = 0
    /// Bumped on every `scheduleRender` call — used only to detect "input has actually gone
    /// quiet" for the crisp settle pass in `startRenderLoopIfNeeded`, not to gate the first
    /// render of a burst (see that method's doc comment for why a pre-render debounce doesn't
    /// belong here).
    private var debounceGeneration = 0
    private var isRenderLoopRunning = false
    /// The newest params requested but not yet rendered. Overwritten, never queued — a burst of
    /// slider ticks during an in-flight render collapses to "render whatever's newest once it's
    /// free," never a backlog of stale, superseded renders.
    private var latestParams: RawEditParameters?
    private var lastRenderedParams: RawEditParameters?

    func loadAndRender(url: URL, params: RawEditParameters) async {
        let (loaded, image) = await Task.detached(priority: .userInitiated) { [renderer] () -> (Bool, CGImage?) in
            let loaded = renderer.load(url: url)
            guard loaded else { return (false, nil) }
            return (true, renderer.renderPreview(params: params, maxPixelSize: 1600))
        }.value
        isReady = loaded
        previewImage = image
        lastRenderedParams = params
        if let image { updateHistograms(from: image) }
    }

    /// Starts rendering immediately — a debounce here (waiting for a gap of silence before doing
    /// *anything*) sounds harmless but isn't: a genuinely continuous drag has no such gap, so a
    /// "wait for quiet, then render" gate never fires until the user releases the mouse, which is
    /// exactly the "doesn't render mid-slide at all" bug this replaced. There's no need for one
    /// anyway — `startRenderLoopIfNeeded` already coalesces a burst of calls down to "render
    /// whatever's newest once the previous render is free," which is the actual throttling this
    /// needs.
    func scheduleRender(params: RawEditParameters) {
        debounceGeneration += 1
        latestParams = params
        startRenderLoopIfNeeded()
    }

    /// `CIRAWFilter`/`CIContext` are mutated in place per render (`RawImageRenderer.apply`) —
    /// calling into them concurrently from more than one thread is undefined, and in practice
    /// meant a fast slider drag could fire many overlapping `renderPreview` calls that fought
    /// each other for the same filter object instead of running one at a time. This loop drains
    /// `latestParams` — always the newest request, discarding anything superseded before its
    /// turn came — one render at a time, so there's never more than one call into `renderer` in
    /// flight. Once the drain empties out, it waits to see if that's a real pause (not just the
    /// gap between two mouse-move events mid-drag) before spending the extra time on a crisper
    /// non-draft pass.
    private func startRenderLoopIfNeeded() {
        guard !isRenderLoopRunning, latestParams != nil else { return }
        isRenderLoopRunning = true
        Task {
            while let params = latestParams {
                latestParams = nil
                await render(params: params, draft: true)
            }

            let settleGeneration = debounceGeneration
            try? await Task.sleep(nanoseconds: 200_000_000)
            if settleGeneration == debounceGeneration {
                let finalParams = latestParams ?? lastRenderedParams
                latestParams = nil
                if let finalParams {
                    await render(params: finalParams, draft: false)
                }
            }
            isRenderLoopRunning = false
            // Input that arrived while the settle wait/render above was in progress won't have
            // triggered its own `startRenderLoopIfNeeded` call if the loop still looked "running"
            // at the time — pick it back up here so it isn't stranded.
            if latestParams != nil { startRenderLoopIfNeeded() }
        }
    }

    private func render(params: RawEditParameters, draft: Bool) async {
        lastRenderedParams = params
        let renderer = renderer
        let image = await Task.detached(priority: .userInitiated) {
            renderer.renderPreview(params: params, maxPixelSize: 1600, draft: draft)
        }.value
        if let image {
            previewImage = image
            updateHistograms(from: image)
        }
    }

    /// Off the main thread — subsampled per `Histogram`'s own budget, so this is only a few ms,
    /// but every bit of slack matters during a rapid slider drag. Generation-guarded the same way
    /// as the render loop so a slow-to-finish computation from a stale drag position can't
    /// overwrite a newer one that finished first.
    private func updateHistograms(from image: CGImage) {
        histogramGeneration += 1
        let generation = histogramGeneration
        Task.detached(priority: .utility) {
            let luminance = Histogram.luminance(from: image)
            let hue = Histogram.hue(from: image)
            await MainActor.run { [weak self] in
                guard let self, generation == self.histogramGeneration else { return }
                self.luminanceHistogram = luminance
                self.hueHistogram = hue
            }
        }
    }
}
