import SwiftUI

@main
struct ShieldApp: App {
    @StateObject private var blocker = ContentBlocker.shared
    @StateObject private var tabs = TabManager()

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environmentObject(blocker)
                .environmentObject(tabs)
                .task { await blocker.load() }
        }
    }
}
