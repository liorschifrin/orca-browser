import AVFoundation
import Foundation
import Speech
import SwiftUI

enum VoiceSearchProvider: String, CaseIterable, Identifiable {
    case apple
    case openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple (on device)"
        case .openAI: "OpenAI"
        }
    }
}

@MainActor
@Observable
final class VoiceSearch {
    enum State {
        case idle, preparing, recording, transcribing, downloading
    }

    private(set) var state = State.idle
    var errorMessage: String?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var operation: Task<Void, Never>?
    private var recordingLimit: Task<Void, Never>?
    private var sessionID: UUID?
    private var isHolding = false
    private var provider = VoiceSearchProvider.apple
    private var previousAudioConfiguration: AudioConfiguration?

    nonisolated private struct AudioConfiguration: Sendable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    /// Switching the audio session on or off can take a noticeable moment, so
    /// it happens here rather than on the main thread, in order.
    nonisolated private static let audioQueue = DispatchQueue(label: "VoiceSearch.audio", qos: .userInitiated)

    var isBusy: Bool { state != .idle }

    var status: String? {
        switch state {
        case .idle: nil
        case .preparing: "Allow microphone access, then hold to talk."
        case .recording: "Listening… Release to Google search."
        case .transcribing: "Transcribing…"
        case .downloading: "Downloading Apple's speech model…"
        }
    }

    func begin(provider: VoiceSearchProvider) {
        guard !isBusy else { return }
        errorMessage = nil
        if provider == .openAI, VoiceSearchCredentials.apiKey == nil {
            errorMessage = "Add your OpenAI API key in Settings, or choose Apple on-device dictation."
            return
        }
        self.provider = provider
        isHolding = true
        state = .preparing
        let identifier = UUID()
        sessionID = identifier
        if AVAudioApplication.shared.recordPermission == .granted {
            startRecording(identifier)
            return
        }
        operation = Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard !Task.isCancelled, sessionID == identifier, isHolding else { return }
            guard granted else {
                fail("Microphone access is off. Enable it for Browser in iPhone Settings.")
                return
            }
            startRecording(identifier)
        }
    }

    private func startRecording(_ identifier: UUID) {
        operation = Task {
            let previous: AudioConfiguration
            do {
                previous = try await Self.activateAudioSession()
            } catch {
                guard sessionID == identifier else { return }
                fail("Couldn't start recording. Check your microphone and try again.")
                return
            }
            // Let go (or cancelled) while the session was starting.
            guard !Task.isCancelled, sessionID == identifier, isHolding else {
                Self.restoreAudioSession(previous)
                return
            }
            previousAudioConfiguration = previous
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voice-search-\(identifier).m4a")
                recordingURL = url
                let capture = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ])
                recorder = capture
                guard capture.record() else {
                    fail("The microphone couldn't start. Please try again.")
                    return
                }
            } catch {
                fail("Couldn't start recording. Check your microphone and try again.")
                return
            }
            state = .recording
            // Recording really has started: say so.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            operation = nil
            recordingLimit = Task {
                do {
                    try await Task.sleep(for: .seconds(30))
                    guard sessionID == identifier else { return }
                    fail("Voice searches are limited to 30 seconds. Hold the microphone to try again.")
                } catch {}
            }
        }
    }

    /// Sets the session up for recording and returns how it was before.
    nonisolated private static func activateAudioSession() async throws -> AudioConfiguration {
        try await withCheckedThrowingContinuation { continuation in
            audioQueue.async {
                let audioSession = AVAudioSession.sharedInstance()
                let previous = AudioConfiguration(
                    category: audioSession.category,
                    mode: audioSession.mode,
                    options: audioSession.categoryOptions
                )
                do {
                    try audioSession.setCategory(.record, mode: .measurement)
                    try audioSession.setActive(true)
                    continuation.resume(returning: previous)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Hands the audio back (other apps' sound resumes) and puts the session
    /// back how it was.
    nonisolated private static func restoreAudioSession(_ previous: AudioConfiguration) {
        audioQueue.async {
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            try? audioSession.setCategory(previous.category, mode: previous.mode, options: previous.options)
        }
    }

    func finish(onTranscript: @escaping (String) -> Void) {
        guard isHolding else { return }
        isHolding = false
        guard state == .recording, let recorder, let url = recordingURL,
              let identifier = sessionID else {
            cancel()
            return
        }
        let duration = recorder.currentTime
        stopRecording()
        guard duration >= 0.3 else {
            cancel()
            return
        }
        state = .transcribing
        let selectedProvider = provider
        operation = Task {
            defer {
                try? FileManager.default.removeItem(at: url)
                if sessionID == identifier {
                    recordingURL = nil
                    operation = nil
                    sessionID = nil
                    state = .idle
                }
            }
            do {
                let transcript: String
                switch selectedProvider {
                case .apple:
                    transcript = try await transcribeOnDevice(url, session: identifier)
                case .openAI:
                    transcript = try await OpenAITranscription.transcribe(url)
                }
                try Task.checkCancellation()
                guard sessionID == identifier else { return }
                let query = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return }
                state = .idle
                onTranscript(query)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, sessionID == identifier else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        sessionID = nil
        isHolding = false
        operation?.cancel()
        operation = nil
        stopRecording()
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        state = .idle
    }

    private func stopRecording() {
        recordingLimit?.cancel()
        recordingLimit = nil
        recorder?.stop()
        recorder = nil
        if let previousAudioConfiguration {
            self.previousAudioConfiguration = nil
            Self.restoreAudioSession(previousAudioConfiguration)
        }
    }

    private func fail(_ message: String) {
        cancel()
        errorMessage = message
    }

    private func transcribeOnDevice(_ url: URL, session identifier: UUID) async throws -> String {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
              ) else {
            throw VoiceSearchError.message("Apple's on-device speech model isn't available for this device or language. Try OpenAI in Settings.")
        }
        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            if sessionID == identifier { state = .downloading }
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        if sessionID == identifier { state = .transcribing }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        return try await withTaskCancellationHandler {
            let results = Task {
                var transcript = ""
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    transcript += String(result.text.characters)
                }
                return transcript
            }
            do {
                let audioFile = try AVAudioFile(forReading: url)
                try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
                return try await results.value
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

enum VoiceSearchError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

private enum OpenAITranscription {
    static func transcribe(_ url: URL) async throws -> String {
        guard let apiKey = VoiceSearchCredentials.apiKey else {
            throw VoiceSearchError.message("Add your OpenAI API key in Settings first.")
        }
        let boundary = "VoiceSearch-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"search.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: url))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let response = response as? HTTPURLResponse else {
            throw VoiceSearchError.message("The transcription service returned an invalid response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            switch response.statusCode {
            case 401: message = "OpenAI rejected the API key. Update it in Settings."
            case 429: message = "OpenAI's quota or rate limit was reached. Check your API billing or try again later."
            default: message = "OpenAI transcription failed (\(response.statusCode)). Please try again or choose Apple in Settings."
            }
            throw VoiceSearchError.message(message)
        }
        struct Transcript: Decodable { let text: String }
        return try JSONDecoder().decode(Transcript.self, from: data).text
    }
}

/// Cancels a voice search when the app leaves the foreground, the system
/// takes the audio session, or the microphone is unplugged.
private struct VoiceSearchLifecycle: ViewModifier {
    let voiceSearch: VoiceSearch
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) {
                if scenePhase != .active { voiceSearch.cancel() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.didBecomeInactiveNotification)) { notification in
                if let context = notification.userInfo?[AVAudioSession.deactivationContextKey]
                    as? AVAudioSession.DeactivationContext, context.source == .system {
                    voiceSearch.cancel()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
                if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    voiceSearch.cancel()
                }
            }
            .onDisappear { voiceSearch.cancel() }
    }
}

extension View {
    func cancelsVoiceSearchWhenInterrupted(_ voiceSearch: VoiceSearch) -> some View {
        modifier(VoiceSearchLifecycle(voiceSearch: voiceSearch))
    }
}
