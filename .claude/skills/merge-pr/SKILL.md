---
name: merge-pr
description: Open a pull request for the current branch if there isn't one, squash-merge it now, then free the branch's phone slot and rebuild the regular Orca Browser app from main. Use when the user says "merge the PR", "merge this", "ship it and merge", or "open a PR and merge it". To open a PR and wait for someone else to merge it, use watch-pr instead.
---

# Merge PR

Run from the worktree for the branch being merged. Stop and tell the user at any
point where a step says stop; never work around it.

## 1. Open the PR (skip if one is open)

Other skills point here, so keep this section self-contained.

1. Refuse on `main`. Stop if `git status --porcelain` shows uncommitted changes
   and ask the user what to do with them; don't commit on your own.
2. Look for an existing PR: `gh pr view --json number,url,state,title`.
   - `OPEN`: use it, go to step 4.
   - `MERGED` or `CLOSED`: say so and stop.
   - No PR: continue.
3. `git push -u origin HEAD`, then
   `gh pr create --base main --title "<title>" --body "<body>"`.
   - The title is one short line in plain words. Squash makes it the commit
     subject on `main`, and the regular app's what's-new panel lists that
     subject, so write it for the user to read on the phone.
   - The body says what changed and why, in a few lines.
4. Link it to the thread with `link_pull_request` (full PR URL).

## 2. Check it can merge

`gh pr view --json mergeable,mergeStateStatus,statusCheckRollup` and
`gh pr checks`. The repo has no CI today, so "no checks reported" is fine.
Stop and report if a check is failing or pending, or if the PR has conflicts. Don't
resolve conflicts or retry unasked.

## 3. Squash-merge

```
gh pr merge <number> --squash --subject "<PR title> (#<number>)"
```

Don't pass `--delete-branch`: it also tries to delete the local branch, which
fails or misbehaves from a worktree. If the merge is refused, report the reason
and stop.

## 4. After it merges

Also used by watch-pr once someone else merges. Confirm first with
`gh pr view <number> --json state` that it says `MERGED`.

1. Free this branch's test slot: `scripts/ship-to-phone.sh --release`.
2. Update main and reinstall the regular app: `scripts/ship-to-phone.sh --main`.
   - Leave off `--changed`/`--test`: the panel then lists the new commit
     subjects, which is what the user wants after a merge. Only pass them if
     the user asks.
   - If the phone is locked or unplugged, say so and stop; the user will
     reconnect it and the only step left is `--main`. If it refuses because the
     main checkout has uncommitted changes, report that and don't touch them.
3. Delete the remote branch (ignore "already deleted"):
   `git push origin --delete "$(git branch --show-current)"`.
   Leave the local branch and the worktree alone.

Finish with one short line: PR URL, whether the slot was released, and whether
the main app was reinstalled.
