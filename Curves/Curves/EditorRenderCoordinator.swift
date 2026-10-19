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
    private(set) var rgbHistogram = RGBHistogramData()
    private(set) var colorDensity: [Float] = []
    /// Clipping fractions and mean color of the current render — see `ImageToneStats`.
    private(set) var toneStats = ImageToneStats()
    /// Rendered scope images for `PhotoDataPanel`'s Waveform/Vectorscope tabs — see `PhotoScopes`.
    private(set) var waveformImage: CGImage?
    private(set) var vectorscopeImage: CGImage?
    private(set) var isReady = false

    /// Called with a freshly-rendered, non-draft preview whenever one finishes — `EditorView` uses
    /// this only to refresh the cached grid/filmstrip thumbnail so it reflects the edit (see
    /// `updateSessionThumbnail(for:from:)`). Never fired for a draft (mid-drag) render — regenerating
    /// a thumbnail on every slider tick would be exactly the per-tick cost `docs/PERFORMANCE.md`
    /// warns against; the settle pass in `startRenderLoopIfNeeded` already gives one crisp render per
    /// pause, which is the right cadence for this too.
    var onSettledRender: ((CGImage) -> Void)?

    /// A base-params + stage-stack pair — everything one render needs. Bundled into one struct
    /// rather than two parallel optionals so `latestParams`/`lastRenderedParams` can't desync.
    struct RenderRequest: Equatable {
        var baseParams: RawBaseParameters
        var stageStack: [StageParameters]
        var maxPixelSize: CGFloat
    }

    /// The preview resolution used while unzoomed — sized for a comfortable editor pane, not for
    /// pixel peeping. `ZoomableImagePane` requests a larger decode via `updateZoomResolution` once
    /// the user zooms past 1x; see that method's doc comment for why stretching this fixed decode
    /// instead would look soft at high zoom.
    static let basePreviewPixelSize: CGFloat = 1600

    /// The target `maxPixelSize` for the *next* render — distinct from what's currently on screen
    /// (`lastRenderedParams.maxPixelSize`), since a zoom change should take effect on the next
    /// render pass without needing every other render call site to know about zoom. Reset to
    /// `basePreviewPixelSize` on every photo switch (`loadAndRender`) so a new photo always opens
    /// at base resolution regardless of how zoomed in the previous one was.
    private var targetMaxPixelSize: CGFloat = EditorRenderCoordinator.basePreviewPixelSize

    private var histogramGeneration = 0
    /// Bumped on every `scheduleRender` call — used only to detect "input has actually gone
    /// quiet" for the crisp settle pass in `startRenderLoopIfNeeded`, not to gate the first
    /// render of a burst (see that method's doc comment for why a pre-render debounce doesn't
    /// belong here).
    private var debounceGeneration = 0
    private var isRenderLoopRunning = false
    /// The newest request queued but not yet rendered. Overwritten, never queued — a burst of
    /// slider ticks during an in-flight render collapses to "render whatever's newest once it's
    /// free," never a backlog of stale, superseded renders.
    private var latestParams: RenderRequest?
    private var lastRenderedParams: RenderRequest?

    func loadAndRender(url: URL, baseParams: RawBaseParameters, stageStack: [StageParameters]) async {
        targetMaxPixelSize = Self.basePreviewPixelSize
        let request = RenderRequest(baseParams: baseParams, stageStack: stageStack, maxPixelSize: targetMaxPixelSize)
        let (loaded, image) = await Task.detached(priority: .userInitiated) { [renderer] () -> (Bool, CGImage?) in
            let loaded = renderer.load(url: url)
            guard loaded else { return (false, nil) }
            return (true, renderer.renderPreview(baseParams: request.baseParams, stageStack: request.stageStack, maxPixelSize: request.maxPixelSize))
        }.value
        isReady = loaded
        previewImage = image
        lastRenderedParams = request
        if let image {
            updateHistograms(from: image)
            onSettledRender?(image)
        }
    }

    /// Starts rendering immediately — a debounce here (waiting for a gap of silence before doing
    /// *anything*) sounds harmless but isn't: a genuinely continuous drag has no such gap, so a
    /// "wait for quiet, then render" gate never fires until the user releases the mouse, which is
    /// exactly the "doesn't render mid-slide at all" bug this replaced. There's no need for one
    /// anyway — `startRenderLoopIfNeeded` already coalesces a burst of calls down to "render
    /// whatever's newest once the previous render is free," which is the actual throttling this
    /// needs.
    func scheduleRender(baseParams: RawBaseParameters, stageStack: [StageParameters]) {
        debounceGeneration += 1
        latestParams = RenderRequest(baseParams: baseParams, stageStack: stageStack, maxPixelSize: targetMaxPixelSize)
        startRenderLoopIfNeeded()
    }

    /// Called by `ZoomableImagePane` as the user pinch-zooms the (non-editing) preview. The plain
    /// preview `Image` just stretches `previewImage` via `.scaleEffect` — fine up to 1x, but past
    /// that it's visibly soft, since `renderPreview` decoded at only `basePreviewPixelSize` to keep
    /// editing snappy. Re-decoding at a size that matches the current zoom (still capped by
    /// `renderPreview`'s own "never upscale past native" tail-scale, and by `decodedImage`'s RAW
    /// `scaleFactor` clamp) fixes that without changing the base (unzoomed) editing resolution.
    ///
    /// Reuses `latestParams`/`startRenderLoopIfNeeded` — the same "coalesce a burst down to the
    /// newest request, one render in flight at a time" loop slider drags already go through — so a
    /// continuous pinch gesture doesn't queue up a backlog of superseded high-res re-decodes.
    /// Gated behind a 10% change so trackpad jitter mid-pinch doesn't retrigger a render for a
    /// pixel size that's effectively unchanged.
    func updateZoomResolution(scale: CGFloat) {
        let desired = scale > 1.01 ? Self.basePreviewPixelSize * scale : Self.basePreviewPixelSize
        guard abs(desired - targetMaxPixelSize) / targetMaxPixelSize > 0.1, let lastRenderedParams else {
            targetMaxPixelSize = desired
            return
        }
        targetMaxPixelSize = desired
        debounceGeneration += 1
        latestParams = RenderRequest(
            baseParams: lastRenderedParams.baseParams, stageStack: lastRenderedParams.stageStack, maxPixelSize: targetMaxPixelSize
        )
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

    private func render(params: RenderRequest, draft: Bool) async {
        lastRenderedParams = params
        let renderer = renderer
        let image = await Task.detached(priority: .userInitiated) {
            renderer.renderPreview(baseParams: params.baseParams, stageStack: params.stageStack, maxPixelSize: params.maxPixelSize, draft: draft)
        }.value
        if let image {
            previewImage = image
            updateHistograms(from: image)
            if !draft { onSettledRender?(image) }
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
            // Higher resolution than the shared 64-bin default (`RGBHistogramView`'s own card is
            // the one place in the editor a histogram is the main attraction, not a curve-graph
            // backdrop) — `maxSamples` scaled up to match so each of the extra bins still gets a
            // reasonable sample count instead of getting noisier for the same total budget.
            // 128 bins, not an arbitrary count — it divides the 256 levels of the 8-bit preview
            // evenly (2 levels per bin); an uneven ratio (e.g. 192) gives some bins 2 levels and
            // their neighbors 1, which draws as alternating tall/short spikes.
            let rgb = Histogram.rgbChannels(from: image, bins: 128, maxSamples: 120_000)
            let density = Histogram.colorDensity(from: image)
            let stats = Histogram.toneStats(from: image)
            let waveform = PhotoScopes.waveform(from: image)
            let vectorscope = PhotoScopes.vectorscope(from: image)
            await MainActor.run { [weak self] in
                guard let self, generation == self.histogramGeneration else { return }
                self.luminanceHistogram = luminance
                self.hueHistogram = hue
                self.rgbHistogram = rgb
                self.colorDensity = density
                self.toneStats = stats
                self.waveformImage = waveform
                self.vectorscopeImage = vectorscope
            }
        }
    }
}
