import SwiftUI

/// Hold to talk, let go to Google search what was said. Recording starts
/// the instant the finger lands (the touch is read straight from UIKit),
/// but the button only shows it, with a buzz, once the finger has held
/// still for a moment. A touch that moves first is a swipe: it's dropped
/// silently and left to the toolbar's swipe, which opens the tab switcher.
struct MicButton: View {
    /// Called with the Google search address for a finished voice search.
    let onSearch: (URL) -> Void

    @State private var voiceSearch = VoiceSearch()
    @State private var micTouchStart = CGPoint.zero
    /// The touch has held still long enough to be sure it's not a swipe;
    /// only then does the microphone show (and buzz) that it's listening.
    @State private var isMicConfirmed = false
    @State private var micConfirmTask: Task<Void, Never>?
    @State private var isMicTouchIgnored = false

    /// Space between the top of the button and its status bubble.
    private static let statusGap: CGFloat = 8

    var body: some View {
        let isRecording = voiceSearch.state == .recording && isMicConfirmed
        return ZStack {
            if isMicConfirmed, voiceSearch.state == .transcribing || voiceSearch.state == .downloading {
                ProgressView()
            } else {
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isRecording ? Color.red : Color.primary)
            }
        }
        .frame(width: 44, height: 44)
        .background(.thinMaterial, in: .circle)
        .contentShape(.circle)
        .scaleEffect(isRecording ? 1.12 : 1)
        .animation(.spring(duration: 0.2), value: isRecording)
        .overlay(alignment: .bottomTrailing) {
            if isMicConfirmed, let status = voiceSearch.status {
                Text(status)
                    .font(.subheadline)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(12)
                    .background(.regularMaterial, in: .capsule)
                    .offset(y: -(44 + Self.statusGap))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            TouchSurface(
                onBegan: { point in
                    micTouchStart = point
                    isMicTouchIgnored = false
                    isMicConfirmed = false
                    // Record at once; whether it's a swipe is decided meanwhile.
                    voiceSearch.begin(provider: AppSettings.shared.voiceSearchProvider)
                    micConfirmTask?.cancel()
                    micConfirmTask = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled, voiceSearch.isBusy else { return }
                        isMicConfirmed = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                },
                onMoved: { point in
                    guard !isMicTouchIgnored, !isMicConfirmed,
                          hypot(point.x - micTouchStart.x, point.y - micTouchStart.y) > 10 else { return }
                    // Moved before it was sure to be a hold: a swipe.
                    micConfirmTask?.cancel()
                    isMicTouchIgnored = true
                    voiceSearch.cancel()
                },
                onEnded: { point in
                    micConfirmTask?.cancel()
                    if isMicTouchIgnored { return }
                    let dx = point.x - micTouchStart.x
                    let dy = point.y - micTouchStart.y
                    if dy < -30, -dy > abs(dx) {
                        voiceSearch.cancel()
                    } else {
                        finishVoiceSearch()
                    }
                },
                onCancelled: {
                    micConfirmTask?.cancel()
                    voiceSearch.cancel()
                }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Voice search")
        .accessibilityHint("Hold while speaking, then release to Google search. With VoiceOver, double-tap to start and again to search.")
        .accessibilityValue(isRecording ? "Listening" : "Hold to talk")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if voiceSearch.state == .recording {
                finishVoiceSearch()
            } else {
                isMicConfirmed = true
                voiceSearch.begin(provider: AppSettings.shared.voiceSearchProvider)
            }
        }
        .cancelsVoiceSearchWhenInterrupted(voiceSearch)
        .onChange(of: voiceSearch.state) {
            if voiceSearch.state == .idle { isMicConfirmed = false }
        }
        .alert("Voice search", isPresented: Binding(
            get: { voiceSearch.errorMessage != nil },
            set: { if !$0 { voiceSearch.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { voiceSearch.errorMessage = nil }
        } message: {
            Text(voiceSearch.errorMessage ?? "")
        }
    }

    private func finishVoiceSearch() {
        voiceSearch.finish { transcript in
            guard let url = Destination.searchURL(for: transcript) else { return }
            onSearch(url)
        }
    }
}
