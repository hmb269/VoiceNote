import SwiftUI

@main
struct VoiceNoteWatchApp: App {
    init() {
        WatchSession.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
        }
    }
}
