import SwiftUI

@main struct OrcaBrowserApp: App {
    init() {
        BackgroundPlayback.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
    }
}
