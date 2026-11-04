# Orca Browser

## Testing a change on the phone

Several agent branches (Claude Code, Codex and others) can be in flight at
once, so each one tests in its own app on the phone instead of fighting over a
single install:

- **Orca Browser** is the regular app, always built from `main` and shown
  with no build stamp. Only `--main` builds it.
- **Orca 1** and **Orca 2** are test slots. A branch claims one on its first
  build and keeps it, so rebuilding never touches the other slot.

When a change is ready to try, run
`scripts/ship-to-phone.sh --label "two to four words" --changed "..." --test "..."`
from the worktree. The label says what the change is (for example
`--label "hide shorts toggle"`). It builds, installs and launches the app, and
prints which slot it used. The label is remembered, so later builds from the
same branch can leave it off.

`--changed` and `--test` (each repeatable, one short line per flag) become a
panel the app shows over the page the first time that build opens. The user
can reopen it by tapping the stamp. Pass them on every build, since they are
not remembered, and the app shows no panel without them. Keep them concise:
`--changed` lines say what is different, `--test` lines say what to try and
what the right result looks like. There is no length limit and the panel
scrolls, so include what the user needs and no more. Write them for the whole
branch compared with main, and say what is new in this build if it is a
follow-up. Light Markdown works (`**bold**`, `code`).

The bottom bar of a test build shows the slot (dev 1 or dev 2), a small commit stamp and the label, so the user can tell what
each app contains. A `*` after the commit means uncommitted changes. In Debug
builds the stamp is part of the Settings > Debug "Show FPS, memory and build"
switch, so the user can hide it. Each test slot also has its own app icon (the `AppIconDev1` and `AppIconDev2`
sets in the asset catalog, with a DEV banner), chosen by the script at build time.

- If both slots are held by other branches, the script exits with code 3 and
  builds nothing. Report to the user which branch holds each slot, its label,
  and how long ago it was last built (the script prints all three), and let
  them decide. Never release or take over a slot on your own. If the user says
  to take one, run `scripts/ship-to-phone.sh --takeover N` (N is 1 or 2). The
  other branch's next build then picks a new slot.
- If the phone is locked or unplugged, say so and stop. The user will reconnect it.
- When your branch is merged, run `scripts/ship-to-phone.sh --release` to free
  its slot, then `scripts/ship-to-phone.sh --main`. That pulls main from GitHub
  in the main checkout and reinstalls the regular app from it, so the phone
  always has what is on main. It works from any worktree and refuses if the
  main checkout has uncommitted changes. If a branch is abandoned instead, just
  `--release`.
- `scripts/ship-to-phone.sh --status` shows who holds each slot.

Slot names, bundle IDs and the stamp are build settings passed on the command
line. Nothing for them is committed, so the code on GitHub builds as plain
Orca Browser with no stamp. Don't hard-code any of it.
