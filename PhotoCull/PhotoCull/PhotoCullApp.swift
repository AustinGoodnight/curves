import SwiftUI
import SwiftData
import AppKit
import PhotoCatalog

/// Forces the whole app's AppKit-drawn chrome (title bar, toolbar, and — the one
/// `.preferredColorScheme(.dark)` on `ContentView` didn't reach — the menu-bar strip that
/// reveals itself over the window in fullscreen) to dark, regardless of the system appearance
/// setting. `.preferredColorScheme` only carries SwiftUI's own environment color scheme into the
/// content it's attached to; it doesn't reliably reach the *fullscreen* toolbar/menu-bar-reveal
/// surface, which macOS renders through a separate mechanism outside that view hierarchy.
/// `NSApp.appearance`, set once at launch, is the actual source AppKit chrome reads everywhere —
/// windowed or fullscreen — so it's the one override guaranteed to reach it. Appropriate here
/// specifically because this app's whole palette (`Color+Workspace.swift`) is a fixed dark theme,
/// not one that's meant to adapt to Light Mode.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

@main
struct PhotoCullApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            PhotoAsset.self, PhotoStack.self, PhotoScene.self, Session.self, Stage.self, LUT3DPreset.self, AssetVersion.self,
            Preset.self, ExportPreset.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // The whole UI (`Color.workspaceBackground`/`sidebarBackground`, etc. — see
                // `Color+Workspace.swift`) is a fixed dark palette, not adaptive to the system
                // appearance. Without forcing the window itself dark, AppKit-drawn chrome (the
                // toolbar, and especially the menu-bar strip that reveals itself over the window
                // in fullscreen) falls back to the system's light/dark setting instead, which is
                // what let fullscreen's toolbar mismatch the rest of the app on a light-mode Mac.
                .preferredColorScheme(.dark)
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
        }
    }
}
