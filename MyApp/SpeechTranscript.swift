import CoreMedia

/// Keeps the latest interpretation of each audio range, including unchanged
/// tentative text that Apple confirms by advancing its finalization time.
struct SpeechTranscript {
    private var segments: [(range: CMTimeRange, text: String)] = []
    var text: String { segments.map(\.text).joined() }

    mutating func replace(range: CMTimeRange, text: String) {
        segments.removeAll {
            $0.range.start == range.start ||
            CMTimeRangeGetIntersection($0.range, otherRange: range).duration > .zero
        }
        segments.append((range, text))
        segments.sort { $0.range.start < $1.range.start }
    }
}
