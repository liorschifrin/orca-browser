# Site search

Type an exact shortcut followed by a space (for example `yt lofi beats`), or tap a provider suggestion while typing the first word. Matching ignores case and surrounding whitespace. The single best matching provider appears in a compact brand-colored chip to the left of the clipboard suggestion (when present). Typing the shortcut and a space (or selecting the suggestion) turns the word into a solid, brand-colored chip at the start of the search field, with the provider's icon and name. The chip behaves like text: one delete press with the cursor right after it turns it back into the word you typed (`yt`), and the × on the right of the field clears the whole entry, chip included. When the chip is turned back into text with a query after it, automatic activation stays off until the field is cleared or reopened; suggestion chips still work.

Automatic activation requires the complete shortcut and a whitespace boundary: `ytmusic` and `yt.com` remain ordinary inputs. Short aliases intentionally take priority when followed by a space: `a book` activates Amazon. Press delete once to turn the chip back into text and search that query normally, or disable/change the shortcut in settings. Selecting a provider consumes the first token; it does not send an empty query. Clipboard navigation and voice searches retain their previous behavior.

Use **Settings → Search sites** to manage everything in one list. Each site has a name, an HTTPS URL with exactly one `%s`, and two independent uses: **typing** (one or more shortcuts) and **voice** (a place in the voice layout, up to nine). The keyboard and microphone buttons on a row turn each use on or off; the Voice filter shows the layout preview and lets you drag to reorder. Each use has its own icon (the site's fetched icon, or an SF Symbol) and colour (the site's colour, or any colour you pick). Shortcuts are 1–20 ASCII letters/numbers with optional hyphens/underscores, and stay unique even when a site isn't used for typing.

Built-in definitions are one-line entries in `OrcaBrowser/SearchSite.swift`, under `SearchSite.builtIns`. Use a stable, unique ID and unique shortcuts. The list is saved as `searchSites.v1`; built-ins added later appear at the end without overwriting edits or resurrecting removed sites. The first time it loads, it is built from the older `searchProviders.v1` and `voiceQueryOptions` settings, which are left untouched. If a site was customised differently in both, both are kept as separate entries. Search queries and provider IDs are saved with tabs.

Site icons are fetched from the site itself (its touch icon or favicon) once, kept in Application Support, and never include anything you search. Brand colours are hard-coded for the built-in sites; any other site uses the main colour of its icon.

Queries use UTF-8 percent-encoding with only URL-unreserved bytes left literal. Rendering substitutes once, so literal `%s`, ampersands, hashes, plus signs, emoji, and diacritics remain query data. Templates are limited to 2,048 UTF-8 bytes, require HTTPS and a host, and reject login details, malformed percent escapes, and placeholders in the authority.

## Validation

The tests live in `OrcaBrowserTests/SearchProviderTests.swift` and run with the rest of the app's tests.

Tests cover built-ins, template rendering and validation, UTF-8 encoding and literal placeholders, path/fragment templates, shortcut boundaries and disabled providers, ranked suggestions, settings serialization, and existing address/search resolution.

Endpoint checks on November 2, 2026 returned HTTP 200 for YouTube, Wikipedia, Amazon, Google Images, and Translate. Wikipedia redirected an exact match to its article; Google Images redirected `udm=2` to `tbm=isch`. Reddit returned 403 and IMDb returned 202 to automated requests, so their interactive results were not verified.

Network query suggestions and dedicated language/region controls are deliberately omitted. Provider suggestions are entirely local.
