import SwiftUI
import AppKit

/// Third round of Sharpness / Dehaze / Denoise / Lens concepts ("Detail Styles" dev panel). The
/// two earlier rounds (illustrated knob faces/tracks, decorative diagrams) were scrapped for
/// breaking the app's visual language; these use only its existing vocabulary — recessed boxes,
/// hairline sliders, stoplight dots, plain-text pills — and show the *real photo* only where it
/// earns the space: a close-up, because these effects are invisible at fit-to-window size.

/// The four real bindings (all 0…1).
struct DetailBindings {
    /// `nil` when the renderer can't sharpen this file (non-RAW / unsupported camera).
    let sharpness: Binding<Double>?
    let sharpnessDefault: Double
    let dehaze: Binding<Double>
    let denoise: Binding<Double>
    let lens: Binding<Double>
}

enum DetailKind: CaseIterable {
    case sharpness, dehaze, denoise, lens

    var title: String {
        switch self {
        case .sharpness: "Sharpness"
        case .dehaze: "Dehaze"
        case .denoise: "Denoise"
        case .lens: "Lens"
        }
    }

    /// Monochrome SF Symbol, used small and secondary beside the name.
    var icon: String {
        switch self {
        case .sharpness: "triangle.lefthalf.filled"
        case .dehaze: "sun.haze"
        case .denoise: "circle.dotted"
        case .lens: "camera.aperture"
        }
    }

    /// Where this control's effect shows — which close-up spot to look at.
    var spot: DetailCloseUpSpots.Spot {
        switch self {
        case .sharpness, .dehaze: .detailed
        case .denoise: .smooth
        case .lens: .corner
        }
    }
}

extension DetailBindings {
    var kinds: [DetailKind] { DetailKind.allCases.filter { $0 != .sharpness || sharpness != nil } }

    func binding(for kind: DetailKind) -> Binding<Double> {
        switch kind {
        case .sharpness: sharpness ?? .constant(0)
        case .dehaze: dehaze
        case .denoise: denoise
        case .lens: lens
        }
    }

    func resetValue(for kind: DetailKind) -> Double {
        switch kind {
        case .sharpness: sharpnessDefault
        case .lens: 1
        case .dehaze, .denoise: 0
        }
    }
}

// MARK: - Close-up spots

struct DetailCloseUpSpots: Equatable {
    var detailed = CGPoint(x: 0.5, y: 0.5)
    var smooth = CGPoint(x: 0.5, y: 0.5)
    var corner = CGPoint(x: 0.08, y: 0.1)

    func center(for kind: DetailKind) -> CGPoint {
        switch kind {
        case .sharpness, .dehaze: detailed
        case .denoise: smooth
        case .lens: corner
        }
    }

    static func find(in image: CGImage) -> DetailCloseUpSpots {
        let width = 96
        let height = max(8, Int(Double(width) * Double(image.height) / Double(max(image.width, 1))))
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return DetailCloseUpSpots() }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let cols = 8, rows = 6
        var energy = [Double](repeating: 0, count: cols * rows)
        var brightness = [Double](repeating: 0, count: cols * rows)
        var counts = [Double](repeating: 0, count: cols * rows)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let gx = Double(pixels[i + 1]) - Double(pixels[i - 1])
                let gy = Double(pixels[i + width]) - Double(pixels[i - width])
                let cell = min(rows - 1, y * rows / height) * cols + min(cols - 1, x * cols / width)
                energy[cell] += (gx * gx + gy * gy).squareRoot()
                brightness[cell] += Double(pixels[i])
                counts[cell] += 1
            }
        }
        func center(_ cell: Int) -> CGPoint {
            CGPoint(x: (Double(cell % cols) + 0.5) / Double(cols), y: (Double(cell / cols) + 0.5) / Double(rows))
        }
        var spots = DetailCloseUpSpots()
        var busiest = 0, calmest: Int?
        for cell in 0..<(cols * rows) where counts[cell] > 0 {
            let e = energy[cell] / counts[cell]
            let b = brightness[cell] / counts[cell]
            if e > energy[busiest] / max(counts[busiest], 1) { busiest = cell }
            if b > 40, b < 215, calmest == nil || e < energy[calmest!] / max(counts[calmest!], 1) { calmest = cell }
        }
        spots.detailed = center(busiest)
        if let calmest { spots.smooth = center(calmest) }
        return spots
    }
}

extension DetailCloseUpSpots {
    enum Spot: String, CaseIterable, Identifiable {
        case detailed = "Detail", smooth = "Smooth", corner = "Corner"
        var id: Self { self }
    }

    func point(_ spot: Spot) -> CGPoint {
        switch spot {
        case .detailed: detailed
        case .smooth: smooth
        case .corner: corner
        }
    }
}

// MARK: - Close-up view

/// A magnified crop of the live render in a recessed panel — nearest-neighbor, so halos and grain
/// stay honest. Styled like the other graph panels (8pt corners, recessed fill, a tertiary caption).
private struct DetailCloseUp: View {
    let image: CGImage?
    let center: CGPoint
    var caption: String?
    var height: CGFloat = 130
    /// Source pixels across the panel's width — smaller = more magnified.
    var sourceWidth: CGFloat = 120
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(uiColors.recessedTrackBackground)
                if let crop = crop(aspect: geo.size.width / max(geo.size.height, 1)) {
                    Image(decorative: crop, scale: 1).resizable().interpolation(.none)
                }
                if let caption {
                    Text(caption)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(height: height)
    }

    private func crop(aspect: CGFloat) -> CGImage? {
        guard let image else { return nil }
        let w = min(sourceWidth, CGFloat(image.width))
        let h = min(w / max(aspect, 0.1), CGFloat(image.height))
        let x = min(max(center.x * CGFloat(image.width) - w / 2, 0), CGFloat(image.width) - w)
        let y = min(max(center.y * CGFloat(image.height) - h / 2, 0), CGFloat(image.height) - h)
        return image.cropping(to: CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded()))
    }
}

// MARK: - Shared rows

/// Hairline row matching Exposure/Contrast: icon + name, % readout, hairline track, diamond thumb.
/// Reports drags via `onEditing` (for close-ups).
private struct DetailHairlineRow: View {
    let kind: DetailKind
    @Binding var value: Double
    let resetValue: Double
    var onEditing: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: kind.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                Text(kind.title)
                    .font(.scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
            MinimalSlider(value: $value, range: 0...1, resetValue: resetValue, ticks: [0, 0.25, 0.5, 0.75, 1],
                          trackStyle: .hairline, thumbShape: .diamond)
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in onEditing(true) }
                    .onEnded { _ in onEditing(false) })
        }
    }
}

// MARK: - Layouts

struct DetailStyleLayout: View {
    enum Style { case knobsCloseUp, hairlineRows, strengthSteps, closeUpHeader }

    let style: Style
    let bindings: DetailBindings
    let previewImage: CGImage?
    @Environment(ColorSchemeStore.self) private var uiColors

    @State private var spots = DetailCloseUpSpots()
    @State private var editing: DetailKind?
    /// Keeps the close-up open briefly after release, so the settled render can be seen.
    @State private var lingering: DetailKind?
    @State private var headerSpot: DetailCloseUpSpots.Spot = .detailed
    /// Close-Up Header only: whether the close-up (and its spot dots) is showing — remembered.
    @AppStorage("detailCloseUpVisible") private var isCloseUpVisible = true

    var body: some View {
        Group {
            switch style {
            case .knobsCloseUp: knobsCloseUp
            case .hairlineRows: hairlineRows
            case .strengthSteps: strengthSteps
            case .closeUpHeader: closeUpHeader
            }
        }
        .task(id: "\(previewImage.map { ObjectIdentifier($0).hashValue } ?? 0)|\(isCloseUpVisible)") {
            guard style == .knobsCloseUp || (style == .closeUpHeader && isCloseUpVisible), let previewImage else { return }
            spots = await Task.detached(priority: .utility) { DetailCloseUpSpots.find(in: previewImage) }.value
        }
    }

    // A — the current knob row; a close-up panel opens above it while a knob is dragged.
    private var knobsCloseUp: some View {
        let shown = editing ?? lingering
        return VStack(spacing: 10) {
            if let shown {
                DetailCloseUp(image: previewImage, center: spots.point(shown.spot),
                              caption: "\(shown.title) · \(shown.spot.rawValue.lowercased()) area", height: 120)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(bindings.kinds, id: \.self) { kind in
                    let value = bindings.binding(for: kind)
                    VStack(spacing: 6) {
                        KnobControl(value: value, range: 0...1, resetValue: bindings.resetValue(for: kind))
                            .simultaneousGesture(DragGesture(minimumDistance: 0)
                                .onChanged { _ in setEditing(kind) }
                                .onEnded { _ in setEditing(nil) })
                        VStack(spacing: 1) {
                            Text(kind.title).font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.0f%%", value.wrappedValue * 100)).font(.caption.monospacedDigit())
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: shown)
    }

    // B — hairline rows in the recessed box, same style as Exposure/Contrast.
    private var hairlineRows: some View {
        VStack(spacing: 14) {
            ForEach(bindings.kinds, id: \.self) { kind in
                DetailHairlineRow(kind: kind, value: bindings.binding(for: kind), resetValue: bindings.resetValue(for: kind))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    // C — Off / Low / Med / High per control; an off-step value shows its own % instead.
    private var strengthSteps: some View {
        VStack(spacing: 10) {
            ForEach(bindings.kinds, id: \.self) { kind in
                let value = bindings.binding(for: kind)
                let steps: [(String, Double)] = kind == .lens
                    ? [("Off", 0), ("Low", 0.5), ("Med", 0.75), ("Full", 1)]
                    : [("Off", 0), ("Low", 0.25), ("Med", 0.5), ("High", 0.75)]
                HStack(spacing: 8) {
                    Image(systemName: kind.icon).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 14)
                    Text(kind.title)
                        .font(.scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    HStack(spacing: 0) {
                        ForEach(steps, id: \.0) { step in
                            let isOn = abs(value.wrappedValue - step.1) < 0.01
                            Button {
                                withAnimation(.snappy(duration: 0.15)) { value.wrappedValue = step.1 }
                            } label: {
                                Text(step.0)
                                    .font(.caption2.weight(isOn ? .semibold : .regular))
                                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 3)
                                    .background(isOn ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(uiColors.recessedTrackBackground, in: Capsule())
                    Text(steps.contains { abs(value.wrappedValue - $0.1) < 0.01 } ? "" : String(format: "%.0f%%", value.wrappedValue * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
    }

    // D — a standing close-up (like the data panel), spot chosen with stoplight dots; dragging a
    // slider jumps it to that control's spot.
    private var closeUpHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            // On/off for the close-up, same stoplight dot + tappable label as module toggles.
            HStack(spacing: 4) {
                sectionTitle("Close-Up", enabled: $isCloseUpVisible,
                             font: .scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                Spacer()
                StoplightToggle(isOn: $isCloseUpVisible)
            }
            if isCloseUpVisible {
            HStack(spacing: 0) {
                ForEach(DetailCloseUpSpots.Spot.allCases) { spot in
                    let isSelected = headerSpot == spot
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isSelected ? uiColors.accentColor : Color(white: 0.4))
                            .frame(width: 8, height: 8)
                            .shadow(color: isSelected ? uiColors.accentColor.opacity(0.5) : .clear, radius: 2.5)
                        Text(spot.rawValue)
                            .font(.scoutieSans("ScoutieSans-Regular", size: 12, relativeTo: .caption))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { headerSpot = spot } }
                }
            }
            DetailCloseUp(image: previewImage, center: spots.point(headerSpot), height: 140)
            }
            VStack(spacing: 14) {
                ForEach(bindings.kinds, id: \.self) { kind in
                    DetailHairlineRow(kind: kind, value: bindings.binding(for: kind), resetValue: bindings.resetValue(for: kind)) { active in
                        if active, headerSpot != kind.spot { withAnimation(.easeOut(duration: 0.15)) { headerSpot = kind.spot } }
                    }
                }
            }
            .padding(.top, 4)
        }
        .animation(.easeOut(duration: 0.18), value: isCloseUpVisible)
    }

    private func setEditing(_ kind: DetailKind?) {
        if let kind {
            editing = kind
            lingering = nil
        } else if let finished = editing {
            editing = nil
            lingering = finished
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                if editing == nil, lingering == finished { lingering = nil }
            }
        }
    }
}
