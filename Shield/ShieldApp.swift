import AVFoundation
import SwiftUI

@main
struct ShieldApp: App {
    @StateObject private var blocker = ContentBlocker.shared
    @StateObject private var tabs = TabManager()

    init() {
        // Sonido aunque el iPhone esté en silencio, y Picture in Picture
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environmentObject(blocker)
                .environmentObject(tabs)
                .task { await blocker.load() }
        }
    }
}
