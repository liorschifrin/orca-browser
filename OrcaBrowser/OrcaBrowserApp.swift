import SwiftUI

@main struct OrcaBrowserApp: App {
    @UIApplicationDelegateAdaptor(VideoFullscreen.AppDelegate.self) private var appDelegate

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
