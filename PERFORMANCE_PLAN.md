# Performance and cleanup plan

Follow-up work from the codebase review. The first round of fixes (saving off
the main thread, progress line, switcher card redraws/shadows/culling,
target=_blank links, script-handler crash guard, language detection off main)
is already done.

Each item below should land as its own commit, with a PR at the end.

## 0. TOP PRIORITY: the switcher puts every tab's picture in memory

### Diagnosis (from the 2026-11-02 screen recording, 142 tabs)

- Frame analysis of the recording: while scrolling a page the screen
  freezes for 70–120 ms roughly every 170 ms (~15–25 fps); opening the
  switcher freezes for about 1 s.
- Reproduced in the simulator with 142 tabs:

  | | Original code | After first-round fixes |
  |---|---|---|
  | Before opening the switcher | 153 MB | 108 MB |
  | Switcher open | 1615 MB | 1577 MB |
  | After closing the switcher | 1559 MB | 1554 MB |

- Cause: each snapshot decodes to a 1200×2195 bitmap (~10.5 MB). Opening
  the switcher draws every card during its entrance animation, so all 142
  pictures get decoded (~1.5 GB), and they stay decoded because each
  `Tab.snapshot` keeps its `UIImage` alive for the life of the app.
- On a phone, 1.5 GB pushes the system into memory pressure: compression,
  WebKit content processes being squeezed or killed. That plausibly
  explains the stutter while scrolling even after the switcher is closed
  (the simulator's Mac-sized memory hides it). The main thread itself was
  nearly idle while scrolling in the profile.
- Not introduced by the first-round fixes: the original code measures the
  same.
- Quick check on the phone: force-quit, relaunch, scroll (should be
  smooth); open the switcher once, close it, scroll again (should stutter).

### Fix

1. **Cards use small thumbnails, not the full picture.** A card is ~255 pt
   wide; a 2x thumbnail is ~510×930 px (~1.9 MB) instead of 10.5 MB.
   Decode them off the main thread with ImageIO
   (`CGImageSourceCreateThumbnailAtIndex`) straight from the file on disk.
2. **Keep only nearby thumbnails in memory.** A size-limited cache
   (`NSCache`, ~100 MB); thumbnails load as cards come near the screen
   and are dropped when they're far away or on a memory warning.
3. **Don't build or draw far-away cards at all**, including during the
   opening animation (today's culling only applies once cards are at
   rest). Only render a window of cards around the focus.
4. **Full-size pictures only where they're needed:** the current tab
   (restoring cover and the switcher's exit zoom). Everything else lives
   on disk until it's needed.
5. **Stop re-encoding every picture after each launch.** Restored tabs
   start at snapshot revision 0, but the "already written" record starts
   empty, so the first save after launch re-encodes and rewrites every
   tab's picture, icon and history (142 JPEG encodes). Seed the record in
   `TabPersistence.load()`.

Expected result: switcher memory roughly flat regardless of tab count
(tens of MB), and opening the switcher no longer freezes for ~1 s.

## 1. Smaller snapshots (decided: 2x)

Snapshots are currently captured at the screen's 3x scale: 1200×2195 px,
about 10.5 MB of memory each. Cards are only ~255 pt wide.

- Shrink each snapshot to 2x right after capture: ~800×1460 px, ~4.7 MB
  (55% less memory, similar saving on disk).
- Do the shrinking on a background thread (WebKit always captures at full
  resolution).
- Only visible cost: the full-screen picture shown while an unloaded tab
  reloads is very slightly softer, until the page appears.
- Item 0 matters much more than this; this one mainly helps the current
  tab and disk usage.

## 2. Lazy loading at launch

- Load only the current tab's picture and history at launch.
- Other tabs' history loads when selected (`activate()`); their pictures
  load when the switcher opens.

## 3. Mic: record only once the hold is confirmed

- Start recording after the existing ~150 ms "hold confirmed" delay, not on
  touch-down. A swipe that starts on the mic no longer touches the audio
  session, so playing video isn't paused.
- Haptic when recording actually starts (after the audio session is up, and
  after the permission prompt on first use).
- Activate/deactivate the audio session off the main thread.
- Trade-off: speech in the first ~150 ms is lost (acceptable).

## 4. Clipboard

Unchanged. It stays pre-read on foreground so the chip is instant when a
new tab opens.

## 5. Website dialogs (alert / confirm / prompt)

- Implement the `WKUIDelegate` dialog methods and show native alerts.
- Dialogs from a tab that isn't on screen are answered "Cancel" at once.
- Disabling them (decided: both):
  - **Per site:** a "Block dialogs from this site" button in each dialog,
    plus a toggle in the site settings. Site settings exist on the newer
    `main`, so rebase/merge onto it first.
  - **Global:** an on/off switch in Settings.

## Decisions so far

- Snapshot size: 2x.
- Website dialogs: both per-site and global switches.
- Clipboard: unchanged.
- Mic: record after the hold is confirmed, with a haptic on start.
- Commits: one per item on this branch, PR at the end (not yet confirmed).

## 6. Break up `Tab` (behavior unchanged)

- `Tab`: the record only (address, title, recency, search text, peek,
  picture, icon, flags).
- `TabWebController`: creates/configures the WKWebView, KVO mirroring into
  `Tab`, navigation and UI delegates (including dialogs).
- `PageSnapshotter`: scroll/load-triggered snapshots and downscaling.
- `PageMetadata`: favicon fetching and language detection.
- Link preview: replace the `removeFromSuperview` hand-off with a single
  container view so moving the web view between the preview and the main
  page is explicit.
- `BottomBar.swift` (731 lines): split out the history menu and the voice
  button into their own files.

## 7. Smaller items

- Guard against double-submit in `BrowserStore.open` (two quick Enters must
  not create two tabs).
- Count each loaded link-preview web view toward the 3-live-tab limit;
  unload previews before their parent tab.
- Cache the "is Chrome installed" check; refresh it when the app returns to
  the foreground (`canOpenURL` is also deprecated in iOS 27).
- Add a unit-test target with tests for `Destination`, `ShortsFilter`,
  `StackMetrics` and `Translation.isForeign`.
