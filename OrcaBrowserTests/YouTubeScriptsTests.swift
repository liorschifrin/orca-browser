import Foundation
import JavaScriptCore
import Testing
@testable import OrcaBrowser

/// Runs the page scripts in JavaScriptCore with just enough of a page around
/// them, so a typo in one is caught here instead of on the phone.
struct YouTubeScriptsTests {
    @Test(arguments: [
        ("BackgroundPlayback", BackgroundPlayback.source),
        ("PlaybackControl", PlaybackControl.source),
        ("YouTubeHeader", YouTubeHeader.source),
    ])
    func scriptsAreValidJavaScript(name: String, source: String) {
        let context = JSContext()!
        context.setObject(source, forKeyedSubscript: "source" as NSString)
        var problems: [String] = []
        context.exceptionHandler = { _, error in problems.append(error?.toString() ?? "unknown") }
        context.evaluateScript("new Function(source)")
        #expect(problems.isEmpty, "\(name): \(problems)")
    }

    /// A page with no video and no player, at a watch address.
    private func makeContext(search: String = "?v=abc") -> (JSContext, errors: () -> [String]) {
        let context = JSContext()!
        var problems: [String] = []
        context.exceptionHandler = { _, error in problems.append(error?.toString() ?? "unknown") }
        context.evaluateScript("""
        var window = this;
        var location = { hostname: 'm.youtube.com', pathname: '/watch', search: '\(search)' };
        var navigator = { language: 'en-US' };
        var URLSearchParams = function (text) {
          this.get = key => ((text.match(new RegExp('[?&]' + key + '=([^&]*)')) || [])[1]) || null;
        };
        var element = () => ({ style: { setProperty() {}, removeProperty() {} }, appendChild() {},
                               append() {}, addEventListener() {}, setAttribute() {} });
        var document = { querySelector: () => null, querySelectorAll: () => [], getElementById: () => null,
                         createElement: element, createElementNS: element,
                         head: { appendChild() {} }, documentElement: { appendChild() {} } };
        var setInterval = () => 0;
        var setTimeout = () => 0;
        """)
        return (context, { problems })
    }

    private let chapterData = """
    {
      "currentVideoEndpoint": { "watchEndpoint": { "videoId": "abc" } },
      "playerOverlays": { "playerOverlayRenderer": { "decoratedPlayerBarRenderer": { "decoratedPlayerBarRenderer": {
        "playerBar": { "multiMarkersPlayerBarRenderer": { "markersMap": [
          { "key": "AUTO_CHAPTERS", "value": { "chapters": [
            { "chapterRenderer": { "title": { "simpleText": "Auto one" }, "timeRangeStartMillis": 0 } } ] } },
          { "key": "DESCRIPTION_CHAPTERS", "value": { "chapters": [
            { "chapterRenderer": { "title": { "runs": [{ "text": "Intro" }] }, "timeRangeStartMillis": 0 } },
            { "chapterRenderer": { "title": { "runs": [{ "text": "Part " }, { "text": "two" }] }, "timeRangeStartMillis": 266349 } },
            { "chapterRenderer": { "title": { "simpleText": "The end" }, "timeRangeStartMillis": 3725000 } } ] } }
        ] } } } } } }
    }
    """

    @Test func readsChaptersFromThePagesData() {
        let (context, errors) = makeContext()
        context.evaluateScript("window.ytInitialData = \(chapterData);")
        context.evaluateScript(PlaybackControl.source)
        let chapters = context.evaluateScript("window.__orcaChapters()")?.toArray() as? [[String: Any]]
        #expect(errors().isEmpty, "\(errors())")
        #expect(chapters?.map { $0["title"] as? String } == ["Intro", "Part two", "The end"])
        #expect(chapters?.map { $0["start"] as? Double } == [0, 266.349, 3725])
    }

    @Test func waitsForThePageToParseItsData() {
        let (context, errors) = makeContext()
        // YouTube first holds the data as a JSON string, and replaces it with the object at the end of the page.
        context.evaluateScript("window.ytInitialData = '{\"not\": \"yet\"}';")
        context.evaluateScript(PlaybackControl.source)
        #expect(context.evaluateScript("window.__orcaChapters().length")?.toInt32() == 0)
        context.evaluateScript("window.ytInitialData = \(chapterData);")
        #expect(context.evaluateScript("window.__orcaChapters().length")?.toInt32() == 3)
        #expect(errors().isEmpty, "\(errors())")
    }

    @Test func noChaptersWhenThePageHasNone() {
        let (context, errors) = makeContext()
        context.evaluateScript("window.ytInitialData = { playerOverlays: {} };")
        context.evaluateScript(PlaybackControl.source)
        let count = context.evaluateScript("window.__orcaChapters().length")?.toInt32()
        #expect(errors().isEmpty, "\(errors())")
        #expect(count == 0)
    }

    @Test func keepsChaptersByVideo() {
        let (context, _) = makeContext(search: "?v=other")
        context.evaluateScript("window.ytInitialData = \(chapterData);")
        context.evaluateScript(PlaybackControl.source)
        // The data is for "abc"; this page is a different video.
        #expect(context.evaluateScript("window.__orcaChapters().length")?.toInt32() == 0)
    }

    @Test func fallsBackToTheDescriptionsTimestamps() {
        let (context, errors) = makeContext()
        context.evaluateScript("""
        document.getElementById = id => id === 'movie_player' ? { getPlayerResponse: () => ({ videoDetails: {
          shortDescription: 'Hello\\n0:00 Intro\\n1:30 - Setup\\n(12:05) The big part\\n1:02:03 Outro\\nthanks'
        } }) } : null;
        """)
        context.evaluateScript(PlaybackControl.source)
        let chapters = context.evaluateScript("window.__orcaChapters()")?.toArray() as? [[String: Any]]
        #expect(errors().isEmpty, "\(errors())")
        #expect(chapters?.map { $0["title"] as? String } == ["Intro", "Setup", "The big part", "Outro"])
        #expect(chapters?.map { $0["start"] as? Double } == [0, 90, 725, 3723])
    }

    @Test func descriptionNeedsThreeTimestampsStartingAtZero() {
        let (context, _) = makeContext()
        context.evaluateScript("""
        document.getElementById = id => id === 'movie_player' ? { getPlayerResponse: () => ({ videoDetails: {
          shortDescription: '0:00 Intro\\n1:30 Setup'
        } }) } : null;
        """)
        context.evaluateScript(PlaybackControl.source)
        #expect(context.evaluateScript("window.__orcaChapters().length")?.toInt32() == 0)
    }
}

struct ChaptersSheetTests {
    private let chapters = [
        PlaybackControl.Chapter(start: 0, title: "A"),
        PlaybackControl.Chapter(start: 60, title: "B"),
        PlaybackControl.Chapter(start: 300, title: "C"),
    ]

    @Test func findsTheChapterPlayingNow() {
        #expect(ChaptersSheet.currentIndex(in: chapters, at: 0) == 0)
        #expect(ChaptersSheet.currentIndex(in: chapters, at: 59.9) == 1) // within half a second of B
        #expect(ChaptersSheet.currentIndex(in: chapters, at: 120) == 1)
        #expect(ChaptersSheet.currentIndex(in: chapters, at: 9999) == 2)
        #expect(ChaptersSheet.currentIndex(in: chapters, at: nil) == nil)
    }

    @Test func formatsStartTimes() {
        #expect(ChaptersSheet.clock(0) == "0:00")
        #expect(ChaptersSheet.clock(83) == "1:23")
        #expect(ChaptersSheet.clock(3725) == "1:02:05")
    }
}

struct YouTubeSettingsTests {
    @Test func youTubeFeaturesAreOnByDefault() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "YouTubeSettingsTests-\(UUID())")!)
        #expect(settings.showsPlaybackBar)
        #expect(settings.hidesOpenApp)
        #expect(settings.showsHeaderTools)
    }

    @Test func choicesAreRemembered() {
        let suite = "YouTubeSettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        AppSettings(defaults: defaults).showsHeaderTools = false
        #expect(!AppSettings(defaults: defaults).showsHeaderTools)
    }

    @Test func headerSettingsScriptCarriesBothChoices() {
        #expect(YouTubeHeader.settingsScript(hidesOpenApp: true, showsTools: false)
            == "window.__orcaHeader = { hidesOpenApp: true, showsTools: false };")
    }
}
