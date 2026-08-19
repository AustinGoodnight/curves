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
    let coordinator: EditorRenderCoordinator

    @State private var exportStatus: String?

    var body: some View {
        section(nil) {
            Button("Reset All") {
                resetAllEdits(asset)
                coordinator.scheduleRender(params: rawEditParameters(for: asset))
            }
            .disabled(!hasAnyEdits(asset))
            Button("Export…") { exportImage() }
                .disabled(!coordinator.isReady)
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

    private func exportImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .tiff]
        panel.nameFieldStringValue = (asset.fileName as NSString).deletingPathExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let format: ExportFormat = url.pathExtension.lowercased() == "tiff" ? .tiff : .jpeg(quality: 0.9)
        do {
            try ExportPipeline.export(renderer: coordinator.renderer, params: rawEditParameters(for: asset), format: format, to: url)
            exportStatus = "Exported to \(url.lastPathComponent)."
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }
}
