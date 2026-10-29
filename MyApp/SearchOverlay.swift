import AVFoundation
import SwiftUI

/// The "type a search or address" sheet: a blurred backdrop with the text
/// field at the bottom, riding just above the keyboard (easy for one thumb).
///
/// This view stays in the hierarchy permanently and just fades in and out.
/// That keeps the text field "warm" so the keyboard can appear right away.
struct SearchOverlay: View {
    let isPresented: Bool
    /// Text the field starts with each time the overlay opens.
    var initialText = ""
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @State private var text = ""
    private let clipboardCache = ClipboardCache.shared
    @State private var voiceSearch = VoiceSearch()
    @Environment(\.scenePhase) private var scenePhase
    private let settings = AppSettings.shared

    /// @FocusState tracks (and controls) whether the field has the keyboard.
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // Backdrop: tapping anywhere outside the field dismisses.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            VStack(spacing: 10) {
                if let status = voiceSearch.status {
                    Text(status)
                        .font(.subheadline)
                        .padding(12)
                        .background(.regularMaterial, in: .capsule)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if !clipboardText.isEmpty && clipboardText != text {
                    clipboardChip
                }
                field
            }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .offset(y: isPresented ? 0 : 24)
        }
        .opacity(isPresented ? 1 : 0)
        // While invisible, it must not steal taps or show up for VoiceOver.
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        // Swiping down also dismisses.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if !voiceSearch.isBusy, value.translation.height > 40 { dismiss() }
                }
        )
        .onAppear {
            // Presented at launch: grab the keyboard right away.
            if isPresented {
                text = initialText
                isFocused = true
                clipboardCache.refresh()
            }
        }
        .onChange(of: isPresented) { _, nowPresented in
            if nowPresented {
                text = initialText
                isFocused = true
                clipboardCache.refresh()
            } else {
                voiceSearch.cancel()
                isFocused = false
            }
        }
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
        .alert("Voice search", isPresented: Binding(
            get: { voiceSearch.errorMessage != nil },
            set: { if !$0 { voiceSearch.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { voiceSearch.errorMessage = nil }
        } message: {
            Text(voiceSearch.errorMessage ?? "")
        }
    }

    private var clipboardText: String {
        clipboardCache.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shows what was copied; tapping goes straight to it.
    private var clipboardChip: some View {
        Button {
            onSubmit(clipboardText)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                Text(clipboardText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.regularMaterial, in: .capsule)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Go to copied text: \(clipboardText)")
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search or enter address", text: $text)
                .focused($isFocused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)

            if voiceSearch.state == .transcribing || voiceSearch.state == .downloading {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                VoiceSearchButton(
                    isRecording: voiceSearch.state == .recording,
                    isEnabled: isPresented,
                    onPress: { voiceSearch.begin(provider: settings.voiceSearchProvider) },
                    onRelease: finishVoiceSearch,
                    onCancel: { voiceSearch.cancel() }
                )
                .frame(width: 44, height: 44)
            }

            // Always laid out so the microphone doesn't shift when it appears.
            let showsClear = !text.isEmpty || voiceSearch.isBusy
            Button {
                voiceSearch.cancel()
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .opacity(showsClear ? 1 : 0)
            .disabled(!showsClear)
            .accessibilityHidden(!showsClear)
            .accessibilityLabel(voiceSearch.isBusy ? "Cancel voice search" : "Clear")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.regularMaterial, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private func submit() {
        voiceSearch.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dismiss()
        } else {
            onSubmit(trimmed)
        }
    }

    private func dismiss() {
        voiceSearch.cancel()
        isFocused = false
        onDismiss()
    }

    private func finishVoiceSearch() {
        voiceSearch.finish { transcript in
            guard isPresented, scenePhase == .active,
                  let url = Destination.searchURL(for: transcript) else { return }
            text = transcript
            isFocused = false
            onSubmit(url.absoluteString)
        }
    }
}
