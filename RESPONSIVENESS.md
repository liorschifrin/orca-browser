# Responsiveness checks

The UI takes priority over screenshots and optional startup work. This applies
on every launch, including fresh installations. The Debug build still uses
unoptimized Swift; compare phone performance using Release without a debugger.

## Intended behavior

- The initial browser shell creates no WKWebView and performs no session disk
  reads. Session metadata and file inventory load off the main thread; records
  are installed in batches that yield to input. An early user navigation wins
  over the saved selection, and saved tabs join behind it. Saving is suppressed
  until restoration finishes so the temporary empty shell cannot erase tabs.
- New-tab submission never requests or awaits a screenshot. The old tab keeps
  its last image or a placeholder. WKWebView construction/navigation remains
  main-thread work, as required by WebKit.
- The switcher appears without capture/prefetch. Only prepared cached thumbnails
  draw initially. After its entrance, focused/nearby cards request images, one
  decode at a time off the main thread. Dragging postpones new work; disappearing
  cards cancel their requests. A decode already running may finish.
- Selecting a card starts its exit animation before activating WebKit. History
  state is read asynchronously. A restored page can initially show an empty
  background instead of a full-size screenshot; its navigation state is retained.
- Playback audio setup runs on the same background queue as microphone changes.
- Empty tabs create WebKit only when used. Favicon and language work, screenshot
  capture, history initialization/writes, and routine session saves yield to
  startup, search, switcher presentation, page scrolling, and app backgrounding.
- Optional work has a three-second startup grace period and a 500 ms quiet
  interval after input. Snapshots also debounce for 600 ms and allow one capture
  per tab. No new capture starts while the page is loading/hidden.
- Cached blocker lookup waits for idle. Updates wait another eight seconds and
  for idle between download/conversion/compilation stages, including first install.
  Pages never wait for blockers; initial requests may go unblocked. Conversion
  already running cannot be interrupted by a gesture, but runs at utility priority.
- History and tab data flush on backgrounding. SwiftData/WebKit APIs that must
  run on the main actor are deferred, rather than incorrectly moved off it.

## Repeatable phone comparison

Use the same phone, OS, session, build configuration, and thermal conditions.
Compare this branch with main. Do not uninstall an app containing valuable tabs.
Use a separate app identity/device for the fresh-install case.

1. Cold-launch with a saved session (small session, then 100+ tabs). Immediately
   tap +, type, and submit; repeat with the switcher instead. Verify that saved
   tabs arrive without replacing the new page or changing its selection.
2. Submit from an existing nonblank page while it is still loading. Immediately
   open the switcher. A missing/stale card image is acceptable; waiting for a
   fresh screenshot is not. Select and close placeholder cards.
3. Open the switcher repeatedly, drag rapidly both ways, then stop. Cached images
   should be immediate; new images arrive after settling. Navigation must work
   even if an image file is missing. Memory should remain bounded by nearby cards.
4. Restore an unloaded tab, then immediately navigate elsewhere or close it.
   Delayed history restoration must not load the old URL into the new page.
5. Background/relaunch after normal browsing. Check tabs, selection, back/forward
   history, auto archive, and new visits. Repeat with backgrounding during startup;
   the temporary empty shell must not overwrite the saved session.
6. Fresh-install test: start typing/opening tabs while blocker lists are absent.
   Verify blockers initialize later, with no page waiting for them.

## Measurements

In Instruments, record Time Profiler, Animation Hitches, and Points of Interest.
Filter signposts to subsystem = app bundle ID, category = `Responsiveness`:

- `Browser shell mounted`: SwiftUI shell task began (not a measured screen frame).
- `Session restoration`: asynchronous metadata restoration, excluding page load.
- `Switcher requested` → `Switcher mounted`: scheduling/presentation latency,
  excluding actual display/compositor latency. Use frame tracks for visible timing.
- `New tab submission`: synchronous tab creation/navigation setup. Contains no
  screenshot or thumbnail operation; excludes website loading time.
- `Page snapshot` and `Card thumbnail`: verify these no longer gate UI presentation.

Initial targets on the phone: visible switcher feedback and new-tab feedback
within 100 ms; no optional app-owned main-thread work exceeding one display frame
during interaction. These are goals, not measured claims. Report median and p95
over at least 20 repetitions, plus worst hitch and peak memory, for each build.

Automated regression coverage is in `ResponsivenessTests`: lightweight shell,
saved selection restoration, early user actions winning over restoration, and
cancellation/presentation rules for optional work. These behavioral tests do not
assert wall-clock budgets on a shared simulator.
