import Testing
@testable import OrcaBrowser

struct PlaybackControlTests {
    @Test func readsThePagesReport() {
        let state = PlaybackControl.State(message: ["available": true, "paused": false, "rate": 2.0])
        #expect(state == { var s = PlaybackControl.State(); s.isAvailable = true; s.isPaused = false; s.rate = 2; return s }())
    }

    @Test func ignoresReportsWithoutAvailability() {
        #expect(PlaybackControl.State(message: ["paused": true]) == nil)
        #expect(PlaybackControl.State(message: "nope") == nil)
    }

    @Test func commandsCallThePagesControls() {
        #expect(PlaybackControl.Command.seek(seconds: -10).script == "window.__orcaPlayback?.seek(-10.0)")
        #expect(PlaybackControl.Command.setRate(3).script == "window.__orcaPlayback?.setRate(3.0)")
        #expect(PlaybackControl.Command.togglePlay.script == "window.__orcaPlayback?.togglePlay()")
    }
}
