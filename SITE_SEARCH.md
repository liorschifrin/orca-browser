# Site search

Type an exact shortcut followed by a space (for example `yt lofi beats`), or tap the site suggestion that appears at the left of the clipboard row while you type the first word. Matching ignores case and surrounding whitespace.

- **Chip:** The shortcut becomes a solid, site-coloured chip at the start of the search bar, only as wide as its name, with the site's icon and a small ×. It pops in with a short animation.
- **Back to text:** Tapping the chip's × or pressing delete right after it turns it back into exactly the word you typed (`yt`, or `you` if you tapped a suggestion for it), with any query kept after it. The × at the right of the bar clears everything, chip included.
- **Empty chip:** Pressing Go with a chip and no query opens that site's front page (Maps, Google Images and AI Mode have their own addresses).
- **Suggestions:** A suggestion shows only while the first word is still being typed; a space after a word that isn't a site removes it. Holding the suggestion for 120 ms (the same as the back button) shows the other matching sites in a row above it; tap one to use it.
- **Reopening:** Tapping + after a chip search reopens the search with the chip and query selected together, so typing starts over without the chip.

Automatic activation requires the complete shortcut and a whitespace boundary: `ytmusic` and `yt.com` remain ordinary inputs. Short aliases intentionally take priority when followed by a space: `a book` activates Amazon. Press delete once to turn the chip back into text and search that query normally, or disable/change the shortcut in settings. Selecting a provider consumes the first token; it does not send an empty query. Clipboard navigation and voice searches retain their previous behavior.

Use **Settings → Search sites** to manage everything in one list. Each site has a name, an HTTPS URL with exactly one `%s`, and two independent uses: **typing** (one or more shortcuts) and **voice** (a place in the voice layout, up to nine). The keyboard and microphone buttons on a row turn each use on or off; the Voice filter shows the layout preview and lets you drag to reorder. Each use has its own icon (the site's fetched icon, or an SF Symbol) and colour (the site's colour, or any colour you pick). Shortcuts are 1–20 ASCII letters/numbers with optional hyphens/underscores, and stay unique even when a site isn't used for typing.

Built-in definitions are one-line entries in `OrcaBrowser/SearchSite.swift`, under `SearchSite.builtIns`. Use a stable, unique ID and unique shortcuts. The list is saved as `searchSites.v1`; built-ins added later appear at the end without overwriting edits or resurrecting removed sites. The first time it loads, it is built from the older `searchProviders.v1` and `voiceQueryOptions` settings, which are left untouched. If a site was customised differently in both, both are kept as separate entries. Search queries and provider IDs are saved with tabs.

Site icons are fetched from the site itself (its touch icon or favicon) once, kept in Application Support, and never include anything you search. Brand colours are hard-coded for the built-in sites; any other site uses the main colour of its icon.

Queries use UTF-8 percent-encoding with only URL-unreserved bytes left literal. Rendering substitutes once, so literal `%s`, ampersands, hashes, plus signs, emoji, and diacritics remain query data. Templates are limited to 2,048 UTF-8 bytes, require HTTPS and a host, and reject login details, malformed percent escapes, and placeholders in the authority.

## Validation

The tests live in `OrcaBrowserTests/SearchProviderTests.swift` and run with the rest of the app's tests.

Tests cover built-ins, template rendering and validation, UTF-8 encoding and literal placeholders, path/fragment templates, shortcut boundaries and disabled providers, ranked suggestions, front pages, voice and typing limits, migration from the older separate lists, icon discovery, and existing address/search resolution.

Endpoint checks on November 2, 2026 returned HTTP 200 for YouTube, Wikipedia, Amazon, Google Images, and Translate. Wikipedia redirected an exact match to its article; Google Images redirected `udm=2` to `tbm=isch`. Reddit returned 403 and IMDb returned 202 to automated requests, so their interactive results were not verified.

Network query suggestions and dedicated language/region controls are deliberately omitted. Provider suggestions are entirely local.

## Implementation notes

The chip is stood in for inside the text field by one hidden ASCII control character (`\u{1}`), so deleting right after the chip is visible as a text change. It has to be ASCII: SwiftUI's `TextSelection` places selections by byte offsets and silently ignores them in text with other characters, so the overlay also asks the field itself to select all (which also makes accented queries select correctly).
