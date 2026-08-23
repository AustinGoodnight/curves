import SwiftUI
import SwiftData
import PhotoCatalog

@main
struct PhotoCullApp: App {
    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            PhotoAsset.self, PhotoStack.self, PhotoScene.self, Session.self, Stage.self, LUT3DPreset.self, AssetVersion.self
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
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
        }
    }
}
