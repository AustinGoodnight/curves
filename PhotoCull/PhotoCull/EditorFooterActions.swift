import SwiftUI
import AppKit
import PhotoCatalog
import RawEngine

/// "Reset All" / "Export…" — its own `View` type because `hasAnyEdits` reads edit fields from
/// every module (exposure, Filmic, Color Balance, RGB Curve, Color Zones). If this lived inline
/// in `EditorSidebarView`'s `body`, that cross-module read would couple the sidebar's own
/// invalidation to color-wheel/Color-Zones changes too — dragging a wheel would re-diff the RGB
/// Curve editor along with it. Isolating it here keeps that dependency local to these two buttons.
struct EditorFooterActions: View {
    let asset: PhotoAsset
    /// "Reset All" only touches the asset's base params and this selected stage — see
    /// `hasAnyEdits(asset:stage:)`'s doc comment for why it's scoped this way.
    let stage: Stage
    /// Cached active stage list, threaded through to `scheduleRender`/export — see
    /// `EditorView.activeStages`'s doc comment for why this isn't recomputed here.
    let activeStages: [Stage]
    let coordinator: EditorRenderCoordinator
    let history: EditHistory

    @State private var exportStatus: String?

    var body: some View {
        section(nil) {
            wideActionButton("Reset All", enabled: hasAnyEdits(asset: asset, stage: stage)) {
                resetAllEdits(asset: asset, stage: stage)
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
            wideActionButton("Export…", enabled: coordinator.isReady) {
                exportImage()
            }
        }
        .alert("Export", isPresented: Binding(
            get: { exportStatus != nil },
            set: { if !$0 { exportStatus = nil } }
        )) {
            Button("OK") { exportStatus = nil }
        } message: {
            Text(exportStatus ?? "")
        }
    }

    /// Full-width, filled-box styling matching the Filmic module button in `EditorSidebarView` —
    /// these two footer actions get the same visual weight as a primary module toggle instead of a
    /// plain default-styled button.
    private func wideActionButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
        .background(
            enabled ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .disabled(!enabled)
    }

    private func exportImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .tiff]
        panel.nameFieldStringValue = (asset.fileName as NSString).deletingPathExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let format: ExportFormat = url.pathExtension.lowercased() == "tiff" ? .tiff : .jpeg(quality: 0.9)
        do {
            try ExportPipeline.export(
                renderer: coordinator.renderer,
                baseParams: rawBaseParameters(for: asset),
                stageStack: activeStages.map { stageParameters(for: $0, detailEnabled: asset.editDetailEnabled) },
                format: format,
                to: url
            )
            exportStatus = "Exported to \(url.lastPathComponent)."
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }
}
