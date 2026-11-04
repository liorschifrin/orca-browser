# Site search

Type an exact shortcut followed by a space (for example `yt lofi beats`), or tap a provider suggestion while typing the first word. Matching ignores case and surrounding whitespace. The single best matching provider appears in a compact brand-colored chip to the left of the clipboard suggestion (when present). Typing the shortcut and a space (or selecting the suggestion) turns the word into a solid, brand-colored chip at the start of the search field, with the provider's icon and name. The chip behaves like text: one delete press with the cursor right after it turns it back into the word you typed (`yt`), and the × on the right of the field clears the whole entry, chip included. When the chip is turned back into text with a query after it, automatic activation stays off until the field is cleared or reopened; suggestion chips still work.

Automatic activation requires the complete shortcut and a whitespace boundary: `ytmusic` and `yt.com` remain ordinary inputs. Short aliases intentionally take priority when followed by a space: `a book` activates Amazon. Press delete once to turn the chip back into text and search that query normally, or disable/change the shortcut in settings. Selecting a provider consumes the first token; it does not send an empty query. Clipboard navigation and voice searches retain their previous behavior.

Use **Settings → Search providers** to add, edit, disable, or remove providers. The editor accepts a name, comma-separated shortcuts, and an HTTPS URL containing exactly one `%s` placeholder after the host. Change Amazon's domain, Wikipedia's language, or Translate's target parameter directly in the template. Shortcuts are 1–20 ASCII letters/numbers with optional hyphens/underscores. Duplicate shortcuts are rejected even when the other provider is disabled.

Built-in definitions are one-line entries in `OrcaBrowser/SearchProvider.swift`, under `SearchProvider.builtIns`. Use a stable, unique ID and unique shortcuts. Preferences store overrides and removal IDs in UserDefaults; future built-ins appear without overwriting edits or resurrecting removed providers. Search queries and provider IDs are saved with tabs. Adding a built-in whose shortcut conflicts with an existing customization requires a migration policy before release.

Queries use UTF-8 percent-encoding with only URL-unreserved bytes left literal. Rendering substitutes once, so literal `%s`, ampersands, hashes, plus signs, emoji, and diacritics remain query data. Templates are limited to 2,048 UTF-8 bytes, require HTTPS and a host, and reject login details, malformed percent escapes, and placeholders in the authority.

## Validation

The tests live in `OrcaBrowserTests/SearchProviderTests.swift` and run with the rest of the app's tests.

Tests cover built-ins, template rendering and validation, UTF-8 encoding and literal placeholders, path/fragment templates, shortcut boundaries and disabled providers, ranked suggestions, settings serialization, and existing address/search resolution.

Endpoint checks on November 2, 2026 returned HTTP 200 for YouTube, Wikipedia, Amazon, Google Images, and Translate. Wikipedia redirected an exact match to its article; Google Images redirected `udm=2` to `tbm=isch`. Reddit returned 403 and IMDb returned 202 to automated requests, so their interactive results were not verified.

Network query suggestions, runtime favicon fetching, and dedicated language/region controls are deliberately omitted. Provider suggestions and bundled brand icons are entirely local; custom providers use a generic globe.
