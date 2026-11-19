# Phone build queue

The owning thread does the work and receives feedback through the existing
**Open Thread in T3 Code** button. The manager starts builds in response to
thread messages. There is no timer, background polling, or feedback service.
Releasing a test slot does not merge, close, or discard the branch.

## Owning threads

After committing a change and running the relevant checks:

```sh
python3 scripts/build-queue.py ready --label "Tab switching" --thread YOUR_THREAD_ID \
  --changed "Keep the selected tab visible" --test "Switch tabs with the keyboard open"
```

After registration succeeds, use **`t3_thread_send` with `mode: "auto"`** to
send the notification payload printed by the command. This starts the manager
when idle, or steers/queues the notification when it is already running. Sending
is part of the handoff: saving the queue alone does not wake the manager. If a
send fails, retain and retry that notification; do not assume the handoff happened.
The CLI itself does not invoke T3 tools.

Repeat `--changed` and `--test` as needed. Higher `--priority` numbers run first;
equal priorities are first-in, first-out. Registration requires a clean worktree,
including untracked files. Do not edit it while queued or building. If more work
is needed, `defer` first, then register again after committing. The manager marks
changed registrations stale instead of building something the thread did not hand off.

After the user tests and says the slot can be freed:

```sh
python3 scripts/build-queue.py release
```

Use this instead of a bare `ship-to-phone.sh --release` for queued work. After
release succeeds, send its printed notification to the manager with
`t3_thread_send` (`mode: "auto"`). Notify it after deferring or reprioritizing too.
The manager can then immediately build the next item. Feedback alone does not release the slot: the owning thread decides
with the user when this test build is finished. Additional branch work can be
registered later. Never infer that a successful build passed user testing.

## Manager

Configure this managing thread once; its ID is stored in the shared queue,
not hard-coded into the repository:

```sh
python3 scripts/build-queue.py manager --thread MANAGING_THREAD_ID
```

Use `t3_thread_list` to get the current thread ID. This feature does not require
creating a separate thread. Owning threads read the manager ID from the queue
and use the printed notification payload. A manager that changes this setting
should also send itself a queue notification if ready work is already waiting.

```sh
python3 scripts/build-queue.py status
python3 scripts/build-queue.py next --automatic  # respects failure/phone pause
python3 scripts/build-queue.py next              # explicit “build next”; retries
python3 scripts/build-queue.py prioritize 10 --worktree /path/to/worktree
python3 scripts/build-queue.py defer --worktree /path/to/worktree
python3 scripts/build-queue.py release --worktree /path/to/worktree
```

Deferring removes an item from consideration but retains an existing phone slot.
To put installed work aside, defer it and explicitly release its slot. Never take
over an occupied slot or install over the regular app through this queue.

On a ready/release/priority/defer message, the manager reads current queue status,
then runs `next --automatic` if there is ready work and no pause. Continue processing
available ready work after a successful build or a stale entry, stopping when no
work is ready, slots are full, or the queue is paused. This is processing the
notification, not waiting or polling: do not schedule checks or retry full slots.
Re-read status after each action so messages received during a build are included.
Duplicate messages are safe: installed entries are not built again. A notification
never authorizes clearing a phone/build pause. Empty queues and full slots do
not touch the phone. Failed builds/installations retain their entry and pause
automatic attempts globally. If the phone is locked or disconnected, report it
and stop; when the user says “build next,” use `next` without `--automatic`.
An interrupted build remains `building`; inspect its log and the actual slot
status, then use `ready`, `defer`, or `release` to resolve it before continuing.
The slot claimed by a failed build may still be held; it is never silently freed.

All worktrees share `~/.orca-slots/queue.json` and file locks. `ORCA_SLOTS_DIR`
overrides this directory, including for the underlying ship script. Registration
can proceed while another item builds. Only one queue build runs at a time.
Manual ship commands remain supported; the queue probes current slot ownership
before building and the shipper makes the final locked ownership check.

The queue uses each registered worktree's own ship script. That worktree needs
the queue-aware script (`--queue-check`), so bring this change into older branches
before registering them. The manager never updates or merges another branch.

No app UI changes, feedback server, automatic merge, or new app slots are needed.

If another queue build is running, leave that build alone; its manager should
re-read status when it finishes. After installing, the manager may notify the
owning thread with `t3_thread_send` that its build is on the phone, including the
revision. This is a status update, not an instruction to edit or release the
branch. Never use messages to initiate unrelated work.
