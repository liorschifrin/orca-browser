import CoreMedia

/// Keeps the latest interpretation of each audio range, including unchanged
/// tentative text that Apple confirms by advancing its finalization time.
struct SpeechTranscript {
    private var segments: [(range: CMTimeRange, text: String)] = []
    var text: String { segments.map(\.text).joined() }

    /// Apple's transcriber punctuates sentences; queries read better without
    /// the trailing period. Periods inside tokens ("apple.com", "3.5") stay.
    var queryText: String {
        text.replacingOccurrences(of: #"\.+(?=\s|$)"#, with: "", options: .regularExpression)
    }

    mutating func replace(range: CMTimeRange, text: String) {
        segments.removeAll {
            $0.range.start == range.start ||
            CMTimeRangeGetIntersection($0.range, otherRange: range).duration > .zero
        }
        segments.append((range, text))
        segments.sort { $0.range.start < $1.range.start }
    }
}
