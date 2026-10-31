import SwiftUI

@main
struct MacDevCleanerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1050, minHeight: 700)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.automatic)
    }
}
