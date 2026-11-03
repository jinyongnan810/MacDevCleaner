import SwiftUI

/// Main entry point for the MacDevCleaner application.
@main
struct MacDevCleanerApp: App {
    /// Configures the main application window and its default sizing.
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1050, minHeight: 700)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.automatic)
    }
}
