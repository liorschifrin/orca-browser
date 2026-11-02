import SwiftUI

@main struct MyApp: App {
    init() {
        // Start looking up the saved blocking lists before the first page loads.
        ContentBlocker.shared.start()
        BackgroundPlayback.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
    }
}
