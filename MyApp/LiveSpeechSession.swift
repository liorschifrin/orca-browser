import AVFoundation
import CoreMedia
import Speech

/// One continuous on-device recognition session. Preview text may change;
/// callers receive the search text only after the analyzer finishes its input.
@MainActor
final class LiveSpeechSession {
    private let engine = AVAudioEngine()
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private var input: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var results: Task<String, Error>?
    private var hasTap = false
    private var startedAt: Date?

    var duration: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    init(locale: Locale) {
        var preset = SpeechTranscriber.Preset.transcription
        preset.reportingOptions.insert(.volatileResults)
        preset.reportingOptions.remove(.fastResults)
        transcriber = SpeechTranscriber(locale: locale, preset: preset)
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func prepare(onDownload: () -> Void) async throws {
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onDownload()
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
    }

    func start(onPreview: @escaping (String) -> Void, onError: @escaping (Error) -> Void) async throws {
        let naturalFormat = engine.inputNode.outputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: naturalFormat
              ) else {
            throw VoiceSearchError.message("The microphone's audio format isn't supported.")
        }
        let stream = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
        input = stream.continuation
        let bridge = try SpeechAudioBridge(from: naturalFormat, to: format, input: stream.continuation)
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        try await analyzer.start(inputSequence: stream.stream)
        try Task.checkCancellation()
        results = Task {
            // Replace overlapping hypotheses instead of appending tentative
            // words. Finalization can confirm an unchanged hypothesis without
            // issuing it again, so retain the latest text for every audio range.
            var transcript = SpeechTranscript()
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    transcript.replace(range: result.range, text: String(result.text.characters))
                    onPreview(transcript.text)
                }
                return transcript.text
            } catch {
                if !Task.isCancelled { onError(error) }
                throw error
            }
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: naturalFormat) { buffer, _ in
            bridge.append(buffer)
        }
        hasTap = true
        engine.prepare()
        try engine.start()
        startedAt = Date()
    }

    func stopInput() {
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        input?.finish()
        input = nil
    }

    func finish() async throws -> String {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results?.value ?? ""
    }

    func cancel() {
        stopInput()
        results?.cancel()
        results = nil
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// The audio tap owns the converter exclusively. Every yielded buffer is a
/// fresh allocation, since the engine reuses its input buffers after the tap.
nonisolated private final class SpeechAudioBridge: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let input: AsyncThrowingStream<AnalyzerInput, Error>.Continuation

    init(from source: AVAudioFormat, to target: AVAudioFormat, input: AsyncThrowingStream<AnalyzerInput, Error>.Continuation) throws {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw VoiceSearchError.message("Couldn't prepare microphone audio for speech recognition.")
        }
        self.converter = converter
        format = target
        self.input = input
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if consumed {
                state.pointee = .noDataNow
                return nil
            }
            consumed = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else {
            input.finish(throwing: error ?? VoiceSearchError.message("Microphone audio conversion failed. Please try again."))
            return
        }
        if output.frameLength > 0 { input.yield(AnalyzerInput(buffer: output)) }
    }
}
