import SwiftUI
import RawEngine

/// The bottom bar's compact Film Simulation control: a drawn 35mm film roll for the loaded look,
/// with ‹ › stepping and a progress track through the LUT folder. Replaces the old scrolling name
/// list — the full visual picker is the sidebar browser (`LUTBrowserSidebar`, via the header's
/// Browse button); this is the quick "next look / previous look" control that stays small.
///
/// Its own `View` so the two frequently-changing things it reads — `LUTLibrary` and the live
/// `coordinator.previewImage` shown in the roll's film frame — only ever re-render this control,
/// not the whole color bar (same reasoning as `WhiteBalanceCastIndicator`).
struct FilmSimulationPicker: View {
    let currentTitle: String?
    let coordinator: EditorRenderCoordinator
    var onSelect: (LUTLibraryEntry) -> Void
    @Environment(LUTLibrary.self) private var library
    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        let entries = library.visibleEntries
        let index = entries.firstIndex { $0.name == currentTitle }
        VStack(spacing: 8) {
            FilmCanister(
                title: currentTitle.map(Self.displayName),
                frameImage: currentTitle == nil ? nil : coordinator.previewImage
            )
            .offset(x: dragOffset)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { dragOffset = $0.translation.width * 0.3 }
                    .onEnded { drag in
                        withAnimation(.snappy(duration: 0.2)) { dragOffset = 0 }
                        if drag.translation.width < -30 { step(1, entries: entries, index: index) }
                        if drag.translation.width > 30 { step(-1, entries: entries, index: index) }
                    }
            )
            .onAppear { library.rescan() }

            if entries.isEmpty {
                Text(library.folderURL == nil ? "No LUT Folder Set" : "No LUTs in Folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsLink {
                    Label("Choose in Settings…", systemImage: "folder").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    stepButton("chevron.left") { step(-1, entries: entries, index: index) }
                    Text(currentTitle.map(Self.displayName) ?? "No Film")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(currentTitle == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    stepButton("chevron.right") { step(1, entries: entries, index: index) }
                }
                progress(index: index, count: entries.count)
            }
        }
    }

    /// A thin track with a marker at the loaded look's position in the folder, plus "3 / 24".
    private func progress(index: Int?, count: Int) -> some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(uiColors.recessedTrackBackground).frame(height: 3)
                    if let index {
                        let fraction = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
                        Capsule().fill(Color.white.opacity(0.35)).frame(width: max(3, fraction * w), height: 3)
                        Circle().fill(.white).frame(width: 7, height: 7).offset(x: fraction * w - 3.5)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 8)
            Text(index.map { "\($0 + 1) / \(count)" } ?? "– / \(count)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    /// Next/previous look in the folder, wrapping; from "no film" the first step loads the first
    /// (→) or last (←) look.
    private func step(_ delta: Int, entries: [LUTLibraryEntry], index: Int?) {
        guard !entries.isEmpty else { return }
        let target = index.map { ($0 + delta + entries.count) % entries.count } ?? (delta > 0 ? 0 : entries.count - 1)
        onSelect(entries[target])
    }

    /// "Kodak/Portra 400" → "Portra 400" — the folder is a filing detail, the roll shows the stock.
    static func displayName(_ title: String) -> String {
        title.split(separator: "/").last.map(String.init) ?? title
    }
}

/// A 35mm film roll drawn in the app's own muted palette: a shaded metal cylinder with ribbed end
/// caps and spool, a wrap-around printed label in a color derived from the stock's name, and the
/// leader pulled out through the light-trap slot — a sprocketed strip whose frame shows the photo
/// (when a look is loaded). With nothing loaded it's a bare, label-less canister.
struct FilmCanister: View {
    let title: String?
    let frameImage: CGImage?

    private let bodyWidth: CGFloat = 44
    private let bodyHeight: CGFloat = 64

    /// Stable per-name hue (not `hashValue`, which is randomized per launch), kept fairly muted
    /// so a row of looks doesn't read as a candy shelf against the dark UI.
    private var labelColor: Color {
        guard let title else { return Color(white: 0.3) }
        let seed = title.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFF }
        return Color(hue: Double(seed % 360) / 360, saturation: 0.55, brightness: 0.62)
    }

    var body: some View {
        HStack(alignment: .center, spacing: -3) {
            canister.zIndex(1)
            if title != nil {
                leader.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(height: bodyHeight + 22)
        .animation(.snappy(duration: 0.25), value: title)
    }

    // MARK: Canister

    /// Horizontal shading that makes a flat rectangle read as a cylinder.
    private var cylinderShade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .black.opacity(0.1), location: 0.25),
                .init(color: .white.opacity(0.22), location: 0.42),
                .init(color: .clear, location: 0.6),
                .init(color: .black.opacity(0.6), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private var canister: some View {
        VStack(spacing: 0) {
            // Spool nub.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.34), Color(white: 0.14)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 12, height: 6)
            cap
            ZStack {
                // Metal shell.
                Rectangle().fill(Color(white: 0.55))
                // Printed label wrapping the middle.
                VStack(spacing: 0) {
                    Rectangle().fill(Color(white: 0.08)).frame(height: 6)
                    Rectangle().fill(labelColor)
                    Rectangle().fill(Color(white: 0.08)).frame(height: 6)
                }
                .padding(.vertical, 4)
                if let title {
                    Text(title.uppercased())
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.5)
                        .frame(width: bodyWidth - 8)
                    Text("35")
                        .font(.system(size: 6, weight: .black))
                        .foregroundStyle(labelColor)
                        .offset(y: bodyHeight / 2 - 11)
                }
                Rectangle().fill(cylinderShade)
                // Light-trap velvet along the right edge, where the leader exits.
                HStack {
                    Spacer()
                    Rectangle().fill(Color(red: 0.12, green: 0.05, blue: 0.06)).frame(width: 3)
                }
            }
            .frame(width: bodyWidth, height: bodyHeight)
            cap
        }
        .shadow(color: .black.opacity(0.45), radius: 4, y: 3)
    }

    /// Ribbed, slightly wider end cap.
    private var cap: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(white: 0.2))
            HStack(spacing: 2.5) {
                ForEach(0..<9, id: \.self) { _ in
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                }
            }
            .padding(.vertical, 1)
            RoundedRectangle(cornerRadius: 2).fill(cylinderShade)
        }
        .frame(width: bodyWidth + 4, height: 6)
    }

    // MARK: Leader

    private var leader: some View {
        let stripHeight: CGFloat = 50
        return ZStack {
            FilmLeaderShape()
                .fill(LinearGradient(
                    colors: [Color(red: 0.23, green: 0.14, blue: 0.08), Color(red: 0.32, green: 0.19, blue: 0.1), Color(red: 0.2, green: 0.12, blue: 0.07)],
                    startPoint: .top, endPoint: .bottom
                ))
            VStack(spacing: 0) {
                sprocketRow
                Spacer(minLength: 0)
                sprocketRow
            }
            .padding(.vertical, 3)
            .padding(.leading, 6)
            .padding(.trailing, 22)
            // The exposed frame.
            HStack {
                Group {
                    if let frameImage {
                        Image(decorative: frameImage, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.black.opacity(0.4))
                    }
                }
                .frame(width: 40, height: stripHeight - 20)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .padding(.leading, 8)
                Spacer(minLength: 0)
            }
        }
        .frame(width: 84, height: stripHeight)
    }

    private var sprocketRow: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 0.8)
                    .fill(Color(white: 0.06))
                    .frame(width: 4, height: 3.5)
            }
        }
    }
}

/// The film strip with a classic tapered leader cut on its free end: full height near the
/// canister, stepping down to a narrower, rounded tongue.
private struct FilmLeaderShape: Shape {
    func path(in rect: CGRect) -> Path {
        let tongueStart = rect.maxX - 26
        let tongueTop = rect.minY + rect.height * 0.42
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: tongueStart, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: tongueStart + 10, y: tongueTop), control: CGPoint(x: tongueStart + 8, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - 5, y: tongueTop))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - 5, y: rect.maxY), control: CGPoint(x: rect.maxX + 3, y: (tongueTop + rect.maxY) / 2))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
