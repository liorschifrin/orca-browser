# Voice search

Hold the microphone immediately before the search field's clear button, speak,
then release. After transcription, the app opens a Google search automatically,
even when the spoken text resembles a website address. Typed addresses retain
their existing behavior. A red microphone means audio is being recorded;
the progress indicator means the recording has stopped and transcription is
running. The clear button cancels either operation.

If the keyboard is open when you start, it stays open. If nothing is recognized
(silence, or a hold too short to contain speech), nothing happens: no alert and
no Google search. Real failures such as denied microphone access or a bad API
key still show an alert.

On first use, allow microphone access and then hold the button again. Recording
never begins after a permission prompt if the hold has already ended. Leaving
the app, dismissing search, an audio interruption, or disconnecting the audio
input cancels the operation without searching. Recordings are limited to 30
seconds; hitting the limit cancels rather than searching without a release.
VoiceOver users can activate the microphone once to start and again to search.

## Recognition providers

Choose **Settings → Voice search → Speech recognition**:

- **Apple (on device)** is the default and needs no API key. This uses the newer
  `SpeechAnalyzer` / `SpeechTranscriber`, not keyboard dictation. It uses the
  first preferred iPhone language, subject to device and model support. First
  use can require a model download. Unsupported devices/languages show an
  error rather than silently sending audio to a cloud provider.
- **OpenAI** sends the completed recording to `/v1/audio/transcriptions` using
  `gpt-transcribe`. Select OpenAI, enter your own API key, and tap **Save API
  key**. The key is stored in this device's Keychain, not UserDefaults or source
  control. API usage requires billing on that key's project. Audio is uploaded
  only after release. Local recording files are removed when the operation
  completes or is canceled; canceling an upload cannot recall data already sent.

Both providers transcribe the recording after release. Neither runs a language
model to rewrite the search. No live transcript is shown in this first version.
Do not ship a shared developer API key inside the app; a distributed app with
centrally funded API usage needs an authenticated backend instead.

Deepgram (streaming cloud recognition) and WhisperKit (downloaded on-device
models) remain alternatives, not dependencies of this version. Test recognition
on the same real searches before choosing a default based on accuracy.

References:
- https://developer.apple.com/videos/play/wwdc2025/277/
- https://developers.openai.com/api/docs/guides/speech-to-text

## Device verification

1. Test a held phrase with Apple, including its initial model download.
2. Confirm release opens Google once, and a spoken domain searches instead of
   navigating directly. Confirm typed domains still navigate normally.
3. Test a quick tap, silence, microphone denial, cancel during transcription,
   dismissal, switching apps, a phone interruption, and unplugging headphones.
4. Select OpenAI, save a key, and test a phrase, an invalid key, exhausted quota,
   no network, and cancel during upload. Confirm a late result never navigates.
5. Verify key replacement/removal and provider persistence after relaunch.
6. Check VoiceOver start/stop and finger movement while holding the microphone.

The repository has no automated test target. Simulator builds verify compilation,
but microphone quality, model availability, Keychain behavior, and paid API calls
need device verification.
