import SwiftUI
import AppKit

/// Shared pinch-to-zoom + trackpad-scroll-to-pan state for the editor's various mask/removal
/// overlays (`AssistedMaskEditorOverlay`, `GradientMaskEditorOverlay`, `ColorRangeMaskEditorOverlay`,
/// `ObjectMaskEditorOverlay`, `SpotRemovalEditorOverlay`, `RemoveObjectEditorOverlay`,
/// `PaintedFillEditorOverlay`) — every one of these hosts its own click/paint/drag interaction
/// directly on the image, so panning can't reuse `ZoomableImagePane`'s own "drag empty space to
/// pan" gesture the way the plain (non-editing) preview does — drag is already the tool. Pinch
/// (via `MagnifyCatcher`, not SwiftUI's `MagnificationGesture` — see its own doc comment for why)
/// zooms, anchored on the cursor; two-finger trackpad scroll (via `ScrollWheelCatcher`, since
/// SwiftUI has no built-in scroll gesture for an arbitrary view either) pans — the same split every
/// macOS image viewer/editor uses, needing no modifier key to remember.
///
/// Deliberately works by handing back an already-zoomed/panned `fitRect`, rather than touching each
/// overlay's own click/paint coordinate math: every overlay already converts between view-space and
/// image-space purely through a `fitRect` (the plain aspect-fit rect at 1x) fed into pure geometry
/// helpers (`imagePointNormalized`/`viewPoint`/etc). Feeding those same helpers a `fitRect` already
/// adjusted for the current zoom/pan (`apply(to:)`) keeps every overlay's existing coordinate logic
/// correct completely unchanged — only the `fitRect` computation and the image's own display frame
/// need to change at each call site. **Every view that reads a zoomed `fitRect` for display must
/// also use it (not `.aspectRatio(contentMode: .fit)`, which silently ignores `fitRect` and falls
/// back to fitting within whatever size its parent proposes) — a mismatch here is exactly what
/// caused the "painted mask shows up at the un-zoomed position" bug once zoom was first added: two
/// call sites (`RemoveObjectEditorOverlay`/`PaintedFillEditorOverlay`'s `overlayMarkers` helpers)
/// updated their main image but missed a second, separately-defined mask-alpha image still using
/// `.aspectRatio(.fit)`.**
@Observable
final class ZoomPanState {
    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 8

    var isZoomed: Bool { scale > minScale + 0.001 }

    /// The rect the image is actually drawn in, given the plain 1x aspect-fit `base` rect and the
    /// current zoom/pan — scales/pans outward from `base`'s own center, so at `scale == 1` this is
    /// exactly `base` unchanged.
    func apply(to base: CGRect) -> CGRect {
        guard base.width > 0, base.height > 0 else { return base }
        let scaledSize = CGSize(width: base.width * scale, height: base.height * scale)
        let center = CGPoint(x: base.midX + offset.width, y: base.midY + offset.height)
        return CGRect(x: center.x - scaledSize.width / 2, y: center.y - scaledSize.height / 2, width: scaledSize.width, height: scaledSize.height)
    }

    /// `delta` is `NSEvent.magnification` from `MagnifyCatcher` — an *incremental* fractional
    /// change per event (e.g. ~0.02 for one small pinch tick), not a cumulative factor the way
    /// SwiftUI's `MagnificationGesture` reports it, so `scale` compounds by `(1 + delta)` on every
    /// call rather than being reassigned outright. `anchor` is the cursor position (view space,
    /// same frame as `baseFitRect`) at the moment of this event — solved for the new `offset` that
    /// keeps the image point currently under `anchor` fixed on screen: writing `u` for `anchor`'s
    /// fractional position within the *old* `fitRect`, the new center must satisfy
    /// `newCenter + newSize*(0.5 - u) == anchor`, i.e. `newCenter = anchor + newSize*(0.5 - u)`.
    func magnify(by delta: CGFloat, anchor: CGPoint, baseFitRect: CGRect) {
        guard baseFitRect.width > 0, baseFitRect.height > 0 else { return }
        let oldFitRect = apply(to: baseFitRect)
        guard oldFitRect.width > 0, oldFitRect.height > 0 else { return }
        let u = CGPoint(x: (anchor.x - oldFitRect.minX) / oldFitRect.width, y: (anchor.y - oldFitRect.minY) / oldFitRect.height)
        scale = min(maxScale, max(minScale, scale * (1 + delta)))
        guard isZoomed else {
            offset = .zero
            return
        }
        let newSize = CGSize(width: baseFitRect.width * scale, height: baseFitRect.height * scale)
        let newCenter = CGPoint(x: anchor.x + newSize.width * (0.5 - u.x), y: anchor.y + newSize.height * (0.5 - u.y))
        offset = CGSize(width: newCenter.x - baseFitRect.midX, height: newCenter.y - baseFitRect.midY)
    }

    /// `delta` is a raw trackpad scroll delta (`NSEvent.scrollingDeltaX/Y`, from `ScrollWheelCatcher`)
    /// — a no-op at 1x so a plain scroll over an unzoomed overlay does nothing surprising (matches
    /// `ZoomableImagePane`'s own "only meaningful once zoomed" convention).
    func pan(by delta: CGSize) {
        guard isZoomed else { return }
        offset.width += delta.width
        offset.height += delta.height
    }

    /// A small "123%" pill, bottom-trailing over `containerSize` — shown only while zoomed, same
    /// role as `ZoomableImagePane`'s own zoom-percent pill for the plain (non-editing) preview.
    @ViewBuilder
    func percentPill(containerSize: CGSize) -> some View {
        if isZoomed {
            Text("\(Int(scale * 100))%")
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(12)
                .frame(width: containerSize.width, height: containerSize.height, alignment: .bottomTrailing)
                .allowsHitTesting(false)
        }
    }
}

/// Installs a local `NSEvent` monitor for `.scrollWheel` while this (invisible — see `hitTest`)
/// view is in the hierarchy, calling `onScroll` with the event's raw delta whenever the scroll
/// happens inside this view's bounds. Deliberately *not* done via the usual "override `hitTest` to
/// return `self` and handle the event directly" approach: that would also intercept mouse-down/drag
/// routing, stealing clicks from the SwiftUI paint/click gesture layered in the same `ZStack`. A
/// local event monitor observes independently of hit-test-based routing, so `hitTest` here always
/// returns `nil` (making this view invisible to normal click/scroll routing) while the monitor still
/// sees every scroll event reaching the app's windows and filters by location itself.
struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitoringView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitoringView)?.onScroll = onScroll
    }

    final class MonitoringView: NSView {
        var onScroll: ((CGSize) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// AppKit's default coordinate space is y-up (origin bottom-left) — every `fitRect`/
        /// `CGPoint` this catcher's location gets fed into is SwiftUI's y-down space (origin
        /// top-left), so without this override, a converted location's y coordinate would be
        /// measured from the wrong edge, inverting anything computed from it (e.g. pinch-zoom's
        /// cursor anchor landing mirrored vertically).
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let locationInView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(locationInView) else { return event }
                self.onScroll?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Same "local `NSEvent` monitor, `hitTest` always `nil`" shape as `ScrollWheelCatcher`, for
/// `.magnify` (trackpad pinch) instead of `.scrollWheel` — used instead of SwiftUI's own
/// `MagnificationGesture` specifically because that gesture's `onChanged`/`onEnded` callbacks carry
/// only a scale factor, with no location, so it has no way to support anchoring the zoom on the
/// cursor. Raw `NSEvent.magnify` events carry `locationInWindow` alongside `magnification`, which is
/// all `ZoomPanState.magnify(by:anchor:baseFitRect:)` needs.
struct MagnifyCatcher: NSViewRepresentable {
    var onMagnify: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitoringView()
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitoringView)?.onMagnify = onMagnify
    }

    final class MonitoringView: NSView {
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// AppKit's default coordinate space is y-up (origin bottom-left) — every `fitRect`/
        /// `CGPoint` this catcher's location gets fed into is SwiftUI's y-down space (origin
        /// top-left), so without this override, a converted location's y coordinate would be
        /// measured from the wrong edge, inverting anything computed from it (e.g. pinch-zoom's
        /// cursor anchor landing mirrored vertically).
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let locationInView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(locationInView) else { return event }
                self.onMagnify?(event.magnification, locationInView)
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
