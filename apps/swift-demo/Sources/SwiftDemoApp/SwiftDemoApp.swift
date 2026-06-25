import SwiftUI
import Antifragile

@main
struct SwiftDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.store, store)
        }
    }
}
