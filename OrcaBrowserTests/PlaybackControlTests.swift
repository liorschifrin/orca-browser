import Testing
@testable import OrcaBrowser

struct PlaybackControlTests {
    @Test func readsThePagesReport() {
        let state = PlaybackControl.State(message: [
            "available": true, "paused": false, "rate": 2.0, "hasCaptions": true, "captionsOn": true,
            "qualities": ["large", "hd720"], "quality": "hd720", "playingQuality": "large",
        ])
        #expect(state == {
            var s = PlaybackControl.State()
            s.isAvailable = true; s.isPaused = false; s.rate = 2; s.hasCaptions = true; s.captionsOn = true
            s.qualities = ["large", "hd720"]; s.quality = "hd720"; s.playingQuality = "large"
            return s
        }())
    }

    @Test func ignoresReportsWithoutAvailability() {
        #expect(PlaybackControl.State(message: ["paused": true]) == nil)
        #expect(PlaybackControl.State(message: "nope") == nil)
    }

    @Test func commandsCallThePagesControls() {
        #expect(PlaybackControl.Command.seek(seconds: -10).script == "window.__orcaPlayback?.seek(-10.0)")
        #expect(PlaybackControl.Command.setRate(3).script == "window.__orcaPlayback?.setRate(3.0)")
        #expect(PlaybackControl.Command.toggleCaptions.script == "window.__orcaPlayback?.toggleCaptions()")
        #expect(PlaybackControl.Command.setQuality("hd720").script == "window.__orcaPlayback?.setQuality(\"hd720\")")
        #expect(PlaybackControl.qualityName("hd1080") == "1080p")
        #expect(PlaybackControl.Command.togglePlay.script == "window.__orcaPlayback?.togglePlay()")
    }
}
