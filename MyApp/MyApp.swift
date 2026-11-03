import SwiftUI

@main struct MyApp: App {
    init() {
        BackgroundPlayback.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
    }
}
