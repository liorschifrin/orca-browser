import SwiftUI

/// Every YouTube setting, as switches. Shown in Settings and, for YouTube
/// sites, in the site menu, so both change the same settings.
struct YouTubeToggles: View {
    @Bindable var settings: AppSettings
    /// Draw a divider between the switches (the site menu's card; a Form
    /// draws its own).
    var separated = false

    var body: some View {
        toggle("Hide Shorts", $settings.hideShorts)
        toggle("Open Shorts as regular videos", $settings.opensShortsAsVideos)
        toggle("Playback controls", $settings.showsPlaybackBar)
        toggle("Hide Open App button", $settings.hidesOpenApp)
        toggle("Time and chapters in top bar", $settings.showsHeaderTools, isLast: true)
    }

    @ViewBuilder
    private func toggle(_ title: String, _ isOn: Binding<Bool>, isLast: Bool = false) -> some View {
        if separated {
            Toggle(title, isOn: isOn)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
            if !isLast { Divider().padding(.leading, 16) }
        } else {
            Toggle(title, isOn: isOn)
        }
    }

    static let footnote = "Hide Shorts removes Shorts shelves and cards. Open Shorts as regular videos plays a Short in the normal player. Playback controls is the bar above the bottom bar on watch pages, with speed, quality, captions, skip and picture in picture. The top bar shows the time and a list of chapters, and Open App is YouTube's button for its app."
}
