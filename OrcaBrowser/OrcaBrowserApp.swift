import SwiftUI

@main struct OrcaBrowserApp: App {
    init() {
        BackgroundPlayback.configureAudioSession()
        PictureInPictureRestoreHook.install()
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
    }
}
