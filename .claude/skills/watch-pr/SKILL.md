---
name: watch-pr
description: Open a pull request for the current branch if there isn't one, watch it with T3's watch_pull_request tool, and when it gets merged free the branch's phone slot and rebuild the regular Orca Browser app from main. Use when the user says "watch the PR", "open a PR and watch it", or "babysit this PR". To merge it yourself right now, use merge-pr instead.
---

# Watch PR

This skill doesn't merge. Someone else merges, and you finish up afterwards.

## 1. Open the PR

Follow "1. Open the PR" in the `merge-pr` skill (`../merge-pr/SKILL.md`): same
checks, same short title, and it ends by linking the PR to the thread.

## 2. Start the watch

Call `watch_pull_request` with the PR URL, then **end your turn**. Tell the user
in one line that you're watching and what will happen on merge. Don't poll, sleep
or loop. Call it once; the watch stays on across wakes.

## 3. On each wake

T3 wakes you for failed checks, passed required checks, new comments or
reviews, and conflicts. A wake is not a merge. First run
`gh pr view <number> --json state,mergeable`:

- `MERGED`: go to step 4.
- `CLOSED` without merging: call `unwatch_pull_request`, tell the user, and stop.
  Don't release the slot; ask whether the branch is abandoned.
- `OPEN`: handle what woke you, then end your turn again.
  - Review comments: read them all, make the requested fixes, push, and reply. Ask
    the user if a comment is a judgment call rather than a plain fix.
  - Failed check: find the cause, fix it, push.
  - Conflict: report it to the user; don't resolve it unasked.
  - Checks passed: nothing to do, the merge isn't yours.

## 4. After it merges

Run "4. After it merges" in the `merge-pr` skill: `--release`, then `--main`,
then delete the remote branch. Then call `unwatch_pull_request` and finish with
the same one-line summary.

If a merge doesn't wake you and the user comes back, check the state yourself and
run this step.
