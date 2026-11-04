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
- **Incognito tabs**

### Site specific features
- **YouTube**
  - Playback controls above the bottom bar on watch pages: back/forward 10 seconds, play/pause, speed (0.25×–4×), quality, captions, picture in picture and fullscreen. Speed and quality open a list the moment you touch them; slide to a choice and let go, or tap one.
  - A top bar with the time (`1:23 / 12:34`) and a chapters list, with the "Open App" button removed.
  - Picture in picture: "return to app" switches back to the tab that was playing and keeps it playing, a video in picture in picture returns to the page when you open its tab, and switching to another tab pauses the video.
  - Options to hide Shorts and to open them in the normal player. All YouTube options are in Settings and in the site menu on YouTube.
- **Reddit** – blocks the "open in app" pop-up that prevents mobile site usage


## Building
Requires iOS 27

Open `OrcaBrowser.xcodeproj` in Xcode and run the `OrcaBrowser` scheme. Xcode will ask you to trust the SafariConverterLib build plugin the first time (command-line builds need `-skipPackagePluginValidation`).

Note: the ad-blocking rules use AdGuard's SafariConverterLib, which is GPL-3.0 licensed.
