import AppKit
import ObjectiveC

/// The app's own scroll bar — no track, just a slim rounded knob in translucent white, so every
/// scrollable area (sidebars, the grid, the LUT list, Settings, sheets) matches the editor's flat
/// dark chrome instead of showing the system's grey scrollers.
///
/// SwiftUI has no scroll-bar styling API on macOS; every `ScrollView`/`List` is backed by an AppKit
/// `NSScrollView` whose `NSScroller`s draw the bars. `ThemedScrollers.install()` (called once at
/// launch from `AppDelegate`) hooks `NSScrollView.tile()` — which AppKit runs whenever a scroll
/// view lays out — to swap in this subclass on every scroll view in the app, present and future,
/// without touching each call site. Still an overlay scroller, so AppKit's own behavior is kept:
/// it fades in while scrolling, fades out when idle, and widens on hover.
final class ThemedScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// No track in overlay style (the content shows through, like the rest of the UI). The legacy
    /// "always show scroll bars" system setting gets a barely-there dark groove instead of the
    /// system's light slot, so it still reads as part of the same dark palette.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard scrollerStyle == .legacy else { return }
        NSColor(white: 0, alpha: 0.2).setFill()
        slotRect.fill()
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard knobRect.width > 0, knobRect.height > 0 else { return }
        let isVertical = bounds.height >= bounds.width
        // Inset across the thin axis so the knob floats clear of the window/sidebar edge, and a
        // touch along the long axis so it doesn't butt into the ends.
        let inset = isVertical ? NSSize(width: 3, height: 2) : NSSize(width: 2, height: 3)
        let pill = knobRect.insetBy(dx: inset.width, dy: inset.height)
        guard pill.width > 0, pill.height > 0 else { return }
        let radius = min(pill.width, pill.height) / 2
        NSColor(white: 1, alpha: 0.28).setFill()
        NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
    }
}

enum ThemedScrollers {
    private static var isInstalled = false

    /// Swizzles `NSScrollView.tile()` so each scroll view replaces its scrollers with
    /// `ThemedScroller` the first time it lays out. `tile()` is implemented by `NSScrollView`
    /// itself (not inherited), so exchanging it only affects scroll views, never other `NSView`s.
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let cls: AnyClass = NSScrollView.self
        guard let original = class_getInstanceMethod(cls, #selector(NSScrollView.tile)),
              let replacement = class_getInstanceMethod(cls, #selector(NSScrollView.themedScrollers_tile))
        else { return }
        method_exchangeImplementations(original, replacement)
    }
}

extension NSScrollView {
    /// After swizzling this *is* `tile()`; calling `themedScrollers_tile()` inside runs the
    /// original implementation.
    @objc fileprivate func themedScrollers_tile() {
        applyThemedScrollersIfNeeded()
        themedScrollers_tile()
    }

    private func applyThemedScrollersIfNeeded() {
        if let vertical = verticalScroller, !(vertical is ThemedScroller) {
            verticalScroller = makeThemedScroller(replacing: vertical)
        }
        if let horizontal = horizontalScroller, !(horizontal is ThemedScroller) {
            horizontalScroller = makeThemedScroller(replacing: horizontal)
        }
    }

    private func makeThemedScroller(replacing old: NSScroller) -> ThemedScroller {
        let scroller = ThemedScroller(frame: old.frame)
        scroller.scrollerStyle = old.scrollerStyle
        scroller.controlSize = old.controlSize
        scroller.knobStyle = .light
        return scroller
    }
}
