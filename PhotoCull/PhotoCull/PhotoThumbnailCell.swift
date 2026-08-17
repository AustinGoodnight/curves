import SwiftUI
import PhotoCatalog

enum StackBadge {
    case collapsed(count: Int)
    case expandedMember(position: Int, total: Int)
}

struct PhotoThumbnailCell: View {
    @Bindable var asset: PhotoAsset
    let isSelected: Bool
    var stackBadge: StackBadge? = nil
    var onToggleStack: (() -> Void)? = nil

    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.gray.opacity(0.15))
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                if asset.flag == .reject {
                    Color.black.opacity(0.35)
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            )
            .overlay(alignment: .topTrailing) { flagBadge }
            .overlay(alignment: .topLeading) { colorDot }
            .overlay(alignment: .bottomLeading) { stackBadgeView }

            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= asset.rating ? "star.fill" : "star")
                        .font(.caption2)
                        .foregroundStyle(star <= asset.rating ? .yellow : .secondary)
                }
            }

            Text(asset.fileName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .task(id: asset.filePath) {
            await loadThumbnail()
        }
    }

    @ViewBuilder private var flagBadge: some View {
        switch asset.flag {
        case .pick:
            Image(systemName: "flag.fill")
                .foregroundStyle(.green)
                .padding(4)
                .background(.thinMaterial, in: Circle())
                .padding(4)
        case .reject:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .padding(4)
                .background(.thinMaterial, in: Circle())
                .padding(4)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var colorDot: some View {
        if asset.colorLabel != .none {
            Circle()
                .fill(color(for: asset.colorLabel))
                .frame(width: 10, height: 10)
                .padding(6)
        }
    }

    @ViewBuilder private var stackBadgeView: some View {
        switch stackBadge {
        case .collapsed(let count):
            Button(action: { onToggleStack?() }) {
                HStack(spacing: 3) {
                    Image(systemName: "square.stack")
                    Text("\(count)")
                }
            }
            .buttonStyle(.plain)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .padding(4)
        case .expandedMember(let position, let total):
            HStack(spacing: 3) {
                if position == 1 {
                    Button(action: { onToggleStack?() }) {
                        Image(systemName: "chevron.down.square.fill")
                    }
                    .buttonStyle(.plain)
                }
                Text("\(position)/\(total)")
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .padding(4)
        case nil:
            EmptyView()
        }
    }

    private func color(for label: ColorLabel) -> Color {
        switch label {
        case .none: return .clear
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }

    private func loadThumbnail() async {
        let key = asset.filePath
        if let cached = ThumbnailCache.shared.image(for: key) {
            thumbnail = cached
            return
        }
        let url = asset.resolvedURL()
        let image = await Task.detached(priority: .userInitiated) {
            ThumbnailProvider.thumbnail(for: url)
        }.value
        if let image {
            ThumbnailCache.shared.setImage(image, for: key)
            thumbnail = image
        }
    }
}
