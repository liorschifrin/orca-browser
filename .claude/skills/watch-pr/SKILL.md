---
name: watch-pr
description: Open a PR for the current branch if there isn't one, answer CodeRabbit and review comments, rebuild on the phone when behavior changes, then ask the user to confirm before merging. Use for "watch the PR" or "open a PR and watch it". To merge without asking, use merge-pr.
---

# Watch PR

Follow steps 1 to 4 of the `merge-pr` skill (`../merge-pr/SKILL.md`): open, watch,
respond, rebuild, repeat. Don't take step 4's "go to step 5" or merge from step 5
until the user confirms below; Confirm is the only merge gate here.

**Confirm.** Once CodeRabbit has reviewed the latest push, nothing is unresolved
and checks pass, call `unwatch_pull_request`, tell the user it's ready, and ask
them to confirm the merge. End your turn.

**On yes**, do steps 5 and 6 of `merge-pr`. If the user already merged it
(`gh pr view --json state`), do just step 6.
