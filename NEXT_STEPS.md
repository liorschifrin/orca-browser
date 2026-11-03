# Blocking: next steps and ideas

Ads and trackers are blocked natively (WebKit content rule lists built from
AdGuard's filters), with a per-site menu opened from the caret in the address
bar. See `OrcaBrowser/ContentBlocker.swift` and `OrcaBrowser/SiteMenu.swift`.

## Before this ships

- **Check it on a real device.** Everything so far was tested in the simulator:
  page-load speed, memory with three rule lists attached, and the first
  launch after install (about 10 seconds of list conversion, during which
  requests can still get through).
- **Decide about the private counting callback.** Blocked counts come from an
  underscore-prefixed WebKit delegate method in `Tab.swift`. It works on iOS 27
  but could get an App Store submission rejected. If it has to go, the menu can
  drop the counts (or show only whether blocking is on) and nothing else
  changes.
- **Decide about the licence.** AdGuard's SafariConverterLib is GPL-3.0. Fine
  for personal builds; distributing the app changes that. Alternatives: ask
  AdGuard about a commercial licence, or write a smaller converter.
- **Commit `project.xcworkspace/xcshareddata/`.** It holds `Package.resolved`,
  which pins the package version.
- **Trust the build plugin once in Xcode.** SafariConverterLib has a
  "GenerateVersion" build plugin. Xcode asks to Trust & Enable it the first
  time; command-line builds need `-skipPackagePluginValidation`.

## Site settings

- Make each switch row tappable, not only the switch itself.
- Show a list of sites with blocking turned off (in Settings), so an exception
  can be removed without visiting the site.
- Optional totals: ads and trackers blocked today, and all time.
- Count hidden page elements too (cosmetic filtering), not only blocked
  requests.
- A "Report a broken site" action that turns blocking off for the site and
  copies the address.

## Phase 2: cookie banners

- Add AdGuard's Cookie Notices filter (id 18) as a third category, with its own
  switch in Settings and in the site menu.
- Many banners also lock scrolling. Add a small script that clears the lock
  once a banner has been hidden.
- Check the cost of one more rule list on page-load speed before enabling it by
  default.

## Phase 3: automatic rejection and scriptlets

- Auto-reject cookie consent where a banner can't just be hidden (consent
  frameworks that need a click).
- Scriptlet-based blocking for things network rules can't stop, mainly
  YouTube's in-stream ads. This needs AdGuard's advanced rules and a script
  injected into pages, so it costs page-load time. Measure first, and keep it
  to the sites that need it.
- Look at how it interacts with the existing "Hide YouTube Shorts" setting.

## Other ideas

- Run the filter update from a background task instead of on launch.
- Let people add their own filter lists or rules.
- Show a small badge on the caret when the current page had blocked content.
- Per-site settings beyond blocking (for example desktop site, or always
  allow notifications), living in the same menu.
