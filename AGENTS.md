# Orca Browser

Instructions change on `main` while branches are in flight. Before following
this file or a skill, run `git fetch` and
`git diff HEAD...origin/main --name-only -- AGENTS.md .claude/skills`. For each
file it lists, `main` has changed it since your branch started: read it with
`git show origin/main:<path>` and follow that version, not your copy.

## Testing a change on the phone

Each branch tests in its own app, so agents don't overwrite each other:

- **Orca Browser** is the regular app, built from `main` by `--main`. Only `--main` and `--as-main` install it.
- **Orca 1** and **Orca 2** are test slots. A branch claims one on its first build and keeps it.

To try a change, run from the worktree:
`scripts/ship-to-phone.sh --label "two to four words" --changed "..." --thread <thread id>`

- `--label` is remembered. `--thread` is your T3 thread id (`currentThreadId` from
  `t3_thread_list`); it adds a link back to you in the panel. Leave it off if you can't find it.
- `--changed` and `--test` (repeatable, one short line each) fill the what's-new
  panel and aren't remembered, so pass them every build. `--changed` covers only
  what's new since this branch's last build. Use `--test` only when what to try
  isn't obvious (a specific action to reproduce, an unusual situation).
- Rebuild only for changes a user would notice, not for code that doesn't change behavior.
- Before rebuilding, check `--status` that you still hold your slot or the regular app.

Rules:

- Both slots held by other branches: the script exits 3 and builds nothing.
  Report each holder, its label and age, and let the user decide. Never take a
  slot unasked; if told to, use `--takeover N`.
- Phone locked or unplugged: say so and stop.
- `--status` shows who holds each slot and the regular app.
- `--as-main` installs your branch over the regular app, only when the user asks.
  It holds the app until the PR is merged or closed or you run `--main`; another
  branch's `--as-main` or `--main` then exits 4. Report the holder and let the user decide.
- PRs: `merge-pr` merges; `watch-pr` asks the user to confirm first. After a
  merge, `--release` then `--main`. Its panel lists the latest 5 PR titles
  (squash subjects), so write titles for the user to read on the phone. For an
  abandoned branch, just `--release`.

Slot names, bundle IDs and the stamp are build settings; nothing for them is
committed. Don't hard-code any of it.
