import CoreMedia
import Foundation
import Testing
@testable import OrcaBrowser

struct VoiceQueryTests {
    @Test(arguments: VoiceQueryDestination.allCases)
    func destinationPreservesSpokenQuery(destination: VoiceQueryDestination) throws {
        let text = "café & headphones + apple.com?"
        let url = try #require(destination.url(for: text))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let expected: (String?, String, String?)
        switch destination {
        case .google: expected = ("www.google.com", "/search", "q")
        case .aiMode: expected = ("www.google.com", "/search", "q")
        case .youtube: expected = ("www.youtube.com", "/results", "search_query")
        case .chatGPT: expected = ("chatgpt.com", "/", "prompt")
        case .amazon: expected = ("www.amazon.com", "/s", "k")
        case .maps: expected = ("www.google.com", "/maps/search/", "api")
        case .reddit: expected = ("www.reddit.com", "/search/", "q")
        case .wikipedia: expected = ("en.wikipedia.org", "/w/index.php", "search")
        case .bing: expected = ("www.bing.com", "/search", "q")
        default: Issue.record("Unexpected built-in destination"); return
        }
        #expect(components.scheme == (destination == .chatGPT ? "com.openai.chat" : "https"))
        #expect(components.host == expected.0)
        #expect(components.path == expected.1)
        #expect(components.queryItems?.first?.name == expected.2)
        if destination == .maps {
            #expect(components.queryItems?.first?.value == "1")
            #expect(components.queryItems?.last == URLQueryItem(name: "query", value: text))
        } else {
            #expect(components.queryItems?.first?.value == text)
        }
        if destination == .aiMode {
            #expect(components.queryItems?.last == URLQueryItem(name: "udm", value: "50"))
        }
        #expect(destination.url(for: " \n ") == nil)
    }

    @Test func chatGPTPromptUsesStrictEncoding() throws {
        let prompt = "café & + # ? / = 東京"
        let url = try #require(ChatGPTLink.url(for: prompt))
        #expect(!url.absoluteString.contains("+"))
        #expect(url.fragment == nil)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "prompt", value: prompt)])
    }

    @Test func chatGPTFallsBackToAppOnlyUniversalLink() async throws {
        let url = try #require(ChatGPTLink.url(for: "a & b + café"))
        var attempts: [(URL, Bool)] = []
        let opened = await ChatGPTLink.open(url) { link, appOnly in
            attempts.append((link, appOnly))
            return appOnly
        }
        #expect(opened)
        #expect(attempts.count == 2)
        #expect(attempts[0].0 == url)
        #expect(!attempts[0].1)
        #expect(attempts[1].0.scheme == "https")
        #expect(attempts[1].1)
        #expect(URLComponents(url: attempts[1].0, resolvingAgainstBaseURL: false)?.percentEncodedQuery == URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
    }

    @Test func chatGPTStopsAfterSuccessfulAppOpenAndReportsFailure() async throws {
        let url = try #require(ChatGPTLink.url(for: "hello"))
        var attempts = 0
        let opened = await ChatGPTLink.open(url) { _, _ in
            attempts += 1
            return true
        }
        #expect(opened)
        #expect(attempts == 1)
        let failed = await ChatGPTLink.open(url) { _, _ in false }
        #expect(!failed)
    }

    @Test func previewRevisionsReplaceWordsWithoutDuplication() {
        var transcript = SpeechTranscript()
        transcript.replace(range: range(0, 1), text: "buy ")
        transcript.replace(range: range(1, 2), text: "head funds")
        transcript.replace(range: range(1, 2), text: "headphones")
        #expect(transcript.text == "buy headphones")
        // One corrected passage can replace several tentative segments.
        transcript.replace(range: range(0, 3), text: "blue headphones")
        #expect(transcript.text == "blue headphones")
        // An empty result revokes the corresponding interpretation.
        transcript.replace(range: range(0, 3), text: "")
        #expect(transcript.text.isEmpty)
    }

    @Test func adjacentSpeechRangesAreRetainedInTimeOrder() {
        var transcript = SpeechTranscript()
        transcript.replace(range: range(1, 1), text: "music")
        transcript.replace(range: range(0, 1), text: "find ")
        #expect(transcript.text == "find music")
    }

    @Test func queryTextDropsSentencePeriodsOnly() {
        var transcript = SpeechTranscript()
        transcript.replace(range: range(0, 1), text: "Best pizza near me. ")
        transcript.replace(range: range(1, 1), text: "Open apple.com in 3.5 seconds.")
        #expect(transcript.queryText == "Best pizza near me Open apple.com in 3.5 seconds")
    }

    @MainActor @Test func targetSelectionAndCancel() {
        let query = VoiceQuery()
        query.screenSize = CGSize(width: 390, height: 800)
        query.buttonFrame = CGRect(x: 155, y: 720, width: 80, height: 44)
        query.updateSelection(at: query.center)
        #expect(query.destination == .google)
        query.updateSelection(at: query.targetPoint(.youtube))
        #expect(query.destination == .youtube)
        // Small movements beyond the entry radius keep the selected target.
        query.updateSelection(at: CGPoint(x: query.targetPoint(.youtube).x, y: query.targetPoint(.youtube).y + 45))
        #expect(query.destination == .youtube)
        query.updateSelection(at: query.targetPoint(.chatGPT))
        #expect(query.destination == .chatGPT)
        query.updateSelection(at: CGPoint(x: 195, y: 710))
        #expect(query.isCancelling)
        query.updateSelection(at: query.center)
        #expect(!query.isCancelling)
        #expect(query.destination == .google)
    }

    @MainActor @Test func tapStillOpensNewTabButOtherDragsDoNot() {
        let query = VoiceQuery()
        var taps = 0
        var searches = 0
        query.touchBegan(CGPoint(x: 40, y: 20))
        query.touchEnded(CGPoint(x: 42, y: 22), onTap: { taps += 1 }, onSearch: { _ in searches += 1 })
        query.touchBegan(CGPoint(x: 40, y: 20))
        query.touchMoved(CGPoint(x: 90, y: 20))
        query.touchEnded(CGPoint(x: 90, y: 20), onTap: { taps += 1 }, onSearch: { _ in searches += 1 })
        #expect(taps == 1)
        #expect(searches == 0)
        #expect(!query.isPresented)
        #expect(!query.speech.isBusy)
    }

    @MainActor @Test func upwardSwipeStartsVoiceBeforeToolbarDragThreshold() {
        let query = VoiceQuery()
        query.touchBegan(CGPoint(x: 40, y: 20))
        query.touchMoved(CGPoint(x: 40, y: 3))

        #expect(query.isPresented)
        query.cancel()
    }

    private func range(_ start: Int64, _ duration: Int64) -> CMTimeRange {
        CMTimeRange(start: CMTime(value: start, timescale: 1), duration: CMTime(value: duration, timescale: 1))
    }
}
