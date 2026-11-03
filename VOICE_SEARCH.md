# Voice search

Tap **+** to open the normal new-tab search. Swipe up from **+** at least 16pt
and keep holding to start voice search. This works in both the browser and tab
switcher. A haptic confirms when the microphone is actually listening; wait for
that confirmation before speaking. The existing toolbar swipe still opens tabs
when it starts outside **+** or Back.

Configure **Settings → Voice search → Voice search options**. Toggle destinations
and drag their handles to keep anywhere from one to nine enabled. At least one
must remain enabled. The first enabled destination is the center/default; all
others follow the saved order, starting at the left and moving clockwise for every count. Disabled destinations keep their list position
and never participate in gesture selection. Settings and order persist across
launches, and the settings preview uses the same geometry as the voice overlay.

Tap a destination name to edit its name, icon, highlight color, or search URL.
Use **Add option** for custom destinations and put `{query}` in the URL where
the encoded transcription belongs. More than nine can be saved, with up to nine
enabled at once. Existing saved configurations migrate automatically.

The built-in destinations are Google, Google AI Mode, YouTube, ChatGPT, Amazon,
Google Maps, Reddit, English Wikipedia, and Bing. The original four are enabled
by default. Selection highlights use the destination's color. Release to stop
listening and finalize recognition. Web searches open in a new tab; ChatGPT opens
its app with the dictated prompt prefilled. Spoken domains remain search queries.

Layouts adapt to the count. Seven uses six circular targets around an equal-sized
center; eight uses seven circular targets and a larger center, with matching
visible gaps between neighbors and the center. Nine uses eight circular targets around the center. The center/default can be any enabled destination.

Slide down toward **+** and release to cancel. Cancellation, very short holds,
and empty recognition never navigate. During transcription the overlay remains
visible with a progress indicator and a Cancel button. The microphone also
remains available as the existing hold-to-search-Google shortcut, including in
the text search interface.

ChatGPT uses `com.openai.chat://chatgpt.com/?prompt=…` with strict query
encoding. The URL is opened through iOS, never loaded into an Orca Browser web view.
If the scheme fails, an app-only `https://chatgpt.com/?prompt=…` universal link
is attempted. If neither opens, an error asks the user to install ChatGPT.
Only the dictated prompt is included; sending it is done inside ChatGPT.

## Recognition providers

Choose **Settings → Voice search → Speech recognition**:

- **Apple (on device)** is the default and needs no API key. An audio engine
  feeds one continuous `SpeechAnalyzer` / `SpeechTranscriber` session. Tentative
  results appear live and may be corrected as more speech arrives. The normal
  transcription preset is used with volatile results enabled and `fastResults`
  disabled. On release, input stops and the analyzer finalizes all remaining
  audio before the transcript can trigger a search. Preview revisions replace
  overlapping audio ranges instead of duplicating words. No audio is uploaded
  or saved to a recording file. It uses the first preferred iPhone language,
  subject to device/model support. First use may require a model download.
- **OpenAI** keeps the complete-recording workflow: audio is recorded locally
  while held and sent only after release to `/v1/audio/transcriptions` using
  `gpt-transcribe`. There is no live transcript in this mode. Select OpenAI,
  enter your own API key, and tap **Save API key**. The key stays in Keychain;
  usage requires API billing. Files are deleted after completion/cancellation.
  Canceling an upload cannot recall data already sent.

Neither provider rewrites the recognized query with a language model. No claim
is made that live Apple recognition and file recognition produce identical
results; compare real searches on hardware when evaluating accuracy.

## Permissions, interruptions, and accessibility

On first use, allow microphone access, then swipe/hold again if the original
hold has ended. A late permission result or model download never starts a
recording after release. Leaving the app, an audio interruption, disconnecting
the microphone, or dismissing the recording control cancels without searching.
The audio session is restored after recording. Recording is limited to 30
seconds; reaching the limit cancels rather than automatically searching.

VoiceOver exposes a **Voice search** action on **New Tab**. Activate it to
start, then activate a labeled destination button to stop and search, or Cancel.
The existing mic supports activation once to start and again to submit Google.

## Verification

`VoiceQueryOptionsTests` covers saving/restoring configuration, reordering,
minimum enabled count, unknown saved IDs, default selection, and target spacing
for all counts at several widths. `VoiceQueryTests` covers destination URL encoding, blank queries, transcript
corrections/revocations, time ordering, target tolerance, cancellation selection,
and preservation of normal taps. Run the full OrcaBrowser test suite in Xcode.

On a real device, verify:

1. Tap + still opens text search. Swipe + opens voice without opening tabs.
   Swiping elsewhere on the toolbar still opens tabs.
2. Apple shows live text, revises uncertain words, and searches only after
   release/finalization. Try Google, YouTube, ChatGPT, and AI Mode.
3. Test the initial model download, denied microphone permission, release while
   preparing, silence, short holds, slide-down cancel, cancellation during
   finalization, and repeated sessions.
4. Test app/background and audio interruptions, including headphones removed
   while recording, and restoration of other apps' audio.
5. With OpenAI selected, verify no upload before release, selected destination,
   invalid key/quota/network failures, and cancellation during upload.
6. Verify VoiceOver controls and both toolbar locations on different sizes.

Simulator builds and automated tests do not establish microphone quality,
recognition accuracy, hardware audio routing, or paid API behavior.

References:
- https://developer.apple.com/videos/play/wwdc2025/277/
- https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption
- https://developers.openai.com/api/docs/guides/speech-to-text
