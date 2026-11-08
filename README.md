# Orca Browser

A fast, gesture-driven web browser for iPhone, built with SwiftUI and WebKit. Inspired by Arc Search

## Features

- **Arc Search style tab switcher** – tabs laid out as a swipeable deck with live thumbnails, ordered by recency.
- **Voice search** – swipe up from **+** and hold to dictate, then slide to a destination (Google, YouTube, ChatGPT, Maps, Reddit, Wikipedia and more) and release to search. Fully customizable.
- **Page-history back button** – tap to go back, hold or drag up to jump backward or forward in the tab's history.
- **Translate** – detects pages in another language and adds a one-tap open in Chrome button for translation.
- **Ad, tracker and cookie banner blocking** – native WebKit content rules built from AdGuard filters, with per-site controls and blocked counts in the site menu. Pages locked by a hidden banner are unlocked so they still scroll. Where a consent banner offers a plain reject (Fides, OneTrust, Sourcepoint and a few others), it is rejected for you.
- **Quick search** - One tap to search clipboard contents
- **Auto tab archive**
- **Incognito tabs** - private tabs among your normal ones, each with its own throwaway storage
- **Incognito window** - a separate space of private tabs that share one session, kept only in memory. Open it with the incognito button at the bottom left of the tab switcher; inside, a Tabs / Incognito toggle at the top goes back. Leaving the app or switching back to normal tabs locks it; coming back offers Continue (behind Face ID) or Start Fresh (no Face ID, since it erases the tabs). The bottom-left button of the switcher flips between the two spaces. No translate button there, and Open in Chrome (in the site menu) asks first. Anything copied while inside is cleared from the clipboard when you leave

### Site specific features
- **YouTube**
  - Playback controls above the bottom bar on watch pages: back/forward 10 seconds, play/pause, speed (0.25×–4×), quality, captions, picture in picture and fullscreen. Speed and quality open a list the moment you touch them; slide to a choice and let go, or tap one.
  - A top bar with the time (`1:23 / 12:34`) and a chapters list, with the "Open App" button removed.
  - Picture in picture: "return to app" switches back to the tab that was playing and keeps it playing, a video in picture in picture returns to the page when you open its tab, and switching to another tab pauses the video.
  - Options to hide Shorts and to open them in the normal player. All YouTube options are in Settings and in the site menu on YouTube.
- **Reddit** – blocks the "open in app" pop-up that prevents mobile site usage
- **X** – keeps Google results and X's app-promotion links on the website, and dismisses the app pop-up. Public posts and the replies X makes available can be read without signing in; X may limit the remaining replies.


## Building
Requires iOS 27

Open `OrcaBrowser.xcodeproj` in Xcode and run the `OrcaBrowser` scheme. Xcode will ask you to trust the SafariConverterLib build plugin the first time (command-line builds need `-skipPackagePluginValidation`).

Note: the ad-blocking rules use AdGuard's SafariConverterLib, which is GPL-3.0 licensed.

## Tests and CI

The `Tests` GitHub Actions workflow runs `OrcaBrowserTests` on an iOS simulator for every pull request and push to `main`. It can also be started manually from the Actions tab. It uses the standard `xcode-27` runner with Xcode 27.2; no Apple signing certificates or repository secrets are required. New pushes cancel older runs for the same PR or branch. Failed runs retain the build log and Xcode result bundle for three days.

To run the same tests locally with Xcode 27.2 selected and an iPhone 17 simulator installed:

```sh
xcodebuild test \
  -project OrcaBrowser.xcodeproj \
  -scheme OrcaBrowser \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -skipPackagePluginValidation \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO
```

Once the workflow has run on GitHub, `iOS tests` can be added as a required status check in the `main` branch rules to prevent merging failing tests.
