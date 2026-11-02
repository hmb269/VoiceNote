import SwiftUI
import SwiftData

@main
struct VoiceNoteApp: App {
    let container: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppConfig.registerDefaults()
        container = DataStore.shared
        Processor.shared.container = container
        PhoneSession.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    Processor.shared.importFile(url)
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Processor.shared.resumePending()
            }
        }
    }
}
