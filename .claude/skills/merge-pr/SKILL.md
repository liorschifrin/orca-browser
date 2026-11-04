---
name: merge-pr
description: Open a PR for the current branch if there isn't one, answer CodeRabbit and review comments, rebuild on the phone when behavior changes, then squash-merge and rebuild the regular app. Use for "merge the PR" or "open a PR and merge it". To confirm with the user before merging, use watch-pr.
---

# Merge PR

Run from the branch's worktree. Where a step says stop, tell the user and stop.

1. **Open.** Stop on `main`, or on uncommitted changes (ask). Reuse an open PR
   (`gh pr view`); stop if it's merged or closed. Otherwise
   `git fetch origin` and `git merge origin/main`, resolving conflicts (ask the user
   about judgment calls), then push and `gh pr create --base main` with a short
   plain title (the phone's what's-new panel shows it) and a few-line body. Then
   `link_pull_request`.
2. **Watch.** Call `watch_pull_request`, then end your turn. A wake is not a
   merge: check `gh pr view --json state` first. `MERGED` → step 6, `CLOSED` →
   `unwatch_pull_request` and stop.
3. **Respond.** Read the new CodeRabbit and other review comments (reviews, inline
   comments, PR comments). Fix what's valid, push, and reply on each thread with
   the fix or why not. Ask the user about judgment calls. Fix failed checks. If
   `main` moved and the PR conflicts, merge it in as in step 1.
4. **Rebuild** only if the push changes something a user would notice, not for
   refactors, tests, comments or docs. Build to where you built before (test slot;
   the regular app only if you're already on it via `--as-main`). Run
   `scripts/ship-to-phone.sh --status` first. If you no longer hold it, or the
   script exits 3 or 4, don't take over: tell the user and carry on without
   rebuilding. Notes cover just this fix. Then go to step 5 if its condition is
   met, otherwise end your turn and keep watching.
5. **Merge** once CodeRabbit has reviewed the latest push, nothing is unresolved
   and checks pass: `gh pr merge <n> --squash --subject "<title> (#<n>)"`. No
   `--delete-branch`.
6. **Finish.** `scripts/ship-to-phone.sh --release`,
   `git push origin --delete "$(git branch --show-current)"` and
   `unwatch_pull_request` (skip any already done), then `--main`. If `--main`
   exits non-zero (4 means another branch holds the regular app), say what
   failed and stop; don't report main as rebuilt. Otherwise one line: PR URL,
   slot released, main rebuilt.
