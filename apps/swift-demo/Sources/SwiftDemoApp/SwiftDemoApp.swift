import SwiftUI
import FiskalPure

@main
struct SwiftDemoApp: App {
    // The store is initialized once at app launch and passed down as an
    // environment object. No component imports the store directly.
    @StateObject private var demoStore = DemoStore()

    var body: some Scene {
        WindowGroup {
            WiredContentView()
                .environmentObject(demoStore)
        }
    }
}
