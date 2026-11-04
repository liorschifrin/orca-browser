#!/bin/bash
# Builds this checkout and installs it on your iPhone, without opening Xcode.
#
#   scripts/ship-to-phone.sh --label "two to four words"
#                                         build this branch into a test slot
#   scripts/ship-to-phone.sh --main       after a merge: update main from GitHub and rebuild
#                                         the regular Orca Browser app (no visible stamp),
#                                         from any worktree. Its what's-new panel lists the
#                                         commits since the last main build, or your
#                                         --changed/--test lines
#   scripts/ship-to-phone.sh --as-main    install THIS branch over the regular Orca Browser app
#                                         (invisible stamp, like main) instead of a test slot.
#                                         Temporary: --main puts main back. Pass --changed/--test.
#                                         Exits 4 instead if another branch's --as-main build is
#                                         still there (until its PR is merged or closed); --main
#                                         refuses the same way
#   scripts/ship-to-phone.sh --release    free this branch's test slot (after merging)
#   scripts/ship-to-phone.sh --takeover N replace whatever is in slot N (ask the user first)
#   scripts/ship-to-phone.sh --status     show who holds each slot
#
# There are two test slots, "Orca 1" and "Orca 2" (bundle IDs ending .dev1 and
# .dev2), next to the regular app. A branch keeps its slot across rebuilds, so
# two branches in flight never overwrite each other. When both slots are taken
# the script stops and says who holds them.
#
# Nothing here touches tracked files. The slot name, bundle ID, icon (the
# AppIconDev1/2 sets in the asset catalog) and commit stamp are passed to xcodebuild as build settings, so a build from Xcode (or
# the code on GitHub) looks the same as before.
#
# Other options:
#   --label "words"     what the branch is about, shown under the slot in the
#                       app (kept for later builds; defaults to the branch name)
#   --changed "line"    what this build changes (repeatable)
#   --test "line"       what to try, only when it isn't obvious from the changes
#                       (repeatable). The app shows both in a
#                       panel the first time this build opens, and when its
#                       stamp is held. Pass them on every build: notes are not kept.
#   --thread ID         your T3 Code thread id: the panel gets an "Open Thread in
#                       T3 Code" row linking to t3code://threads/<environment>/<id>
#   --build-only        build but don't install
#   --configuration X   Debug (default) or Release
#   --device X          device name or UDID (default: the connected iPhone)

set -euo pipefail

SLOT_COUNT=2
BASE_ID="com.liorschifrin.OrcaBrowser"
SLOTS_DIR="${ORCA_SLOTS_DIR:-$HOME/.orca-slots}"
# This Mac's T3 Code environment, for thread links (t3_environment_read shows it).
RECENT_UPDATES=5
T3_ENVIRONMENT_ID="${ORCA_T3_ENVIRONMENT_ID:-a42a529c-33c0-4e18-bacb-574b2bbe4c42}"

mode=ship
configuration=Debug
device="${ORCA_DEVICE:-}"
label=""
takeover=""
changed=()
tests=()
older=()
notes_heading=""
new_count=0
thread=""
build_only=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --main) mode=main ;;
        --as-main) mode=asmain ;;
        --release) mode=release ;;
        --status) mode=status ;;
        --build-only) build_only=1 ;;
        --configuration) configuration="$2"; shift ;;
        --device) device="$2"; shift ;;
        --label) label="$2"; shift ;;
        --takeover) takeover="$2"; shift ;;
        --changed) changed+=("$2"); shift ;;
        --test) tests+=("$2"); shift ;;
        --thread) thread="$2"; shift ;;
        -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

root="$(git rev-parse --show-toplevel)"
caller_root="$root"
caller_branch="$(git symbolic-ref --quiet --short HEAD || basename "$root")"
if [[ "$mode" == main ]]; then
    # Build in whichever checkout has main, so this works from any worktree.
    root="$(git worktree list --porcelain \
        | awk '/^worktree /{ p = substr($0, 10) } /^branch refs\/heads\/main$/{ print p; exit }')"
    if [[ -z "$root" ]]; then
        echo "No checkout has main checked out." >&2
        exit 1
    fi
    cd "$root"
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "The main checkout ($root) has uncommitted changes; not building them into the main app." >&2
        exit 1
    fi
    # Pick up merged pull requests. If this can't fast-forward, build local main as it is.
    git fetch --quiet origin main && git merge --ff-only --quiet origin/main \
        || echo "Couldn't update main from GitHub; building local main as it is." >&2
fi
cd "$root"
branch="$(git symbolic-ref --quiet --short HEAD || basename "$root")"
branch_label="${branch#t3/}"
commit="$(git rev-parse --short=7 HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    commit="$commit*"
fi

mkdir -p "$SLOTS_DIR"

# Up to four words: a branch named like "fix-page-safe-area" reads fine, and a
# hash-named branch falls back to its latest commit message.
default_label() {
    local text="$branch_label"
    [[ "$text" =~ ^[0-9a-f]{8}$ ]] && text="$(git log -1 --format=%s)"
    echo "$text" | tr '_-' '  ' | awk '{ for (i = 1; i <= NF && i <= 4; i++) printf "%s%s", $i, (i < NF && i < 4 ? " " : ""); print "" }'
}

# Prints one line per update on main, newest first: the title of each pull
# request, from squash commits ("Title (#12)") and "Merge pull request" commits.
# Older commits made directly on main or merged as plain branches are skipped.
list_updates() {
    local sha subject range="${1:-HEAD}"
    while IFS=$'\t' read -r sha subject; do
        if [[ "$subject" =~ ^(.+)\ \(#[0-9]+\)$ ]]; then
            echo "${BASH_REMATCH[1]}"
        elif [[ "$subject" == "Merge pull request #"* ]]; then
            git log -1 --format=%b "$sha" | sed -n '/./{p;q;}'
        fi
    done < <(git log --first-parent --format=$'%H\t%s' "$range")
}

# Sets the build ID and the what's-new notes (from --changed and --test) for the app.
add_notes_settings() {
    settings+=("ORCA_BUILD_ID=$(date +%s)")
    if [[ ${#changed[@]} -gt 0 || ${#tests[@]} -gt 0 || -n "$thread" ]]; then
        local notes_json thread_url=""
        [[ -n "$thread" ]] && thread_url="t3code://threads/$T3_ENVIRONMENT_ID/$thread"
        notes_json="$(jq -cn \
            --argjson c "$(json_array ${changed[@]+"${changed[@]}"})" \
            --argjson t "$(json_array ${tests[@]+"${tests[@]}"})" \
            --argjson m "$(json_array ${older[@]+"${older[@]}"})" \
            --arg heading "$notes_heading" \
            --argjson n "$new_count" \
            --arg thread "$thread_url" \
            '{changed: $c, test: $t}
             + (if ($m | length) == 0 then {} else {more: $m} end)
             + (if $heading == "" then {} else {heading: $heading} end)
             + (if $n == 0 then {} else {newCount: $n} end)
             + (if $thread == "" then {} else {thread: $thread} end)')"
        settings+=("ORCA_BUILD_NOTES=$(printf '%s' "$notes_json" | base64 | tr -d '\n')")
        return 0
    fi
    return 1
}

json_array() {
    if [[ $# -eq 0 ]]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -cs .; fi
}

slot_file() { echo "$SLOTS_DIR/$1"; }
slot_field() { grep "^$2=" "$(slot_file "$1")" 2>/dev/null | head -1 | cut -d= -f2- || true; }

with_lock() {
    local tries=0
    until mkdir "$SLOTS_DIR/.lock" 2>/dev/null; do
        tries=$((tries + 1))
        if [[ $tries -gt 100 ]]; then
            echo "Slot lock $SLOTS_DIR/.lock is stuck; remove it if no other build is running." >&2
            exit 1
        fi
        sleep 0.1
    done
    trap 'rmdir "$SLOTS_DIR/.lock" 2>/dev/null || true' EXIT
}

# A slot is stale when its worktree or branch no longer exists.
slot_is_stale() {
    local n="$1" w b
    [[ -f "$(slot_file "$n")" ]] || return 1
    w="$(slot_field "$n" worktree)"; b="$(slot_field "$n" branch)"
    [[ ! -d "$w" ]] && return 0
    git -C "$w" show-ref --verify --quiet "refs/heads/$b" || return 0
    return 1
}

# Best effort: a slot whose branch has a merged or closed pull request is free.
slot_pr_is_done() {
    local state
    command -v gh >/dev/null || return 1
    state="$(gh pr view "$(slot_field "$1" branch)" --json state --jq .state 2>/dev/null || true)"
    [[ "$state" == MERGED || "$state" == CLOSED ]]
}

# The regular app is held while a branch's --as-main build is on it, which
# --as-main records in main-holder. The hold lasts while that branch is in flight.
main_hold_is_active() {
    [[ -f "$(slot_file main-holder)" ]] || return 1
    [[ -n "$(slot_field main-holder released)" ]] && return 1
    slot_is_stale main-holder && return 1
    slot_pr_is_done main-holder && return 1
    return 0
}

# True if another checkout holds the regular app.
main_held_by_other() {
    main_hold_is_active || return 1
    [[ "$(slot_field main-holder worktree)" == "$caller_root" && "$(slot_field main-holder branch)" == "$caller_branch" ]] && return 1
    return 0
}

# --main and --as-main both install the regular app, so they take turns from
# checking the hold through installing.
acquire_main_lock() {
    local tries=0
    until mkdir "$SLOTS_DIR/.main-lock" 2>/dev/null; do
        tries=$((tries + 1))
        if [[ $tries -gt 600 ]]; then
            echo "Another main build seems stuck; remove $SLOTS_DIR/.main-lock if none is running." >&2
            exit 1
        fi
        sleep 0.5
    done
    trap 'rmdir "$SLOTS_DIR/.main-lock" 2>/dev/null || true' EXIT
}

lock_main() {
    acquire_main_lock
    if main_held_by_other; then refuse_main_held; fi
}

refuse_main_held() {
    local f=main-holder built
    built="$(slot_field $f built_epoch)"
    echo "The regular Orca Browser app is holding $(slot_field $f branch) \"$(slot_field $f label)\" for testing (last built $(format_age $(( $(date +%s) - ${built:-0} ))) ago). Not overwriting it." >&2
    echo "Report this to the user and let them decide. It frees when that branch's PR is merged or closed, or when it runs --main." >&2
    exit 4
}

# "5m", "3h" or "2d" for a number of seconds.
format_age() {
    local s="$1"
    if [[ $s -lt 3600 ]]; then echo "$((s / 60))m"
    elif [[ $s -lt 86400 ]]; then echo "$((s / 3600))h"
    else echo "$((s / 86400))d"; fi
}

print_status() {
    local n built built_ago
    for n in $(seq 1 "$SLOT_COUNT"); do
        if [[ -f "$(slot_file "$n")" ]]; then
            built="$(slot_field "$n" built_epoch)"
            if [[ -n "$built" ]]; then built_ago="$(format_age $(( $(date +%s) - built ))) ago"; else built_ago="at an unknown time"; fi
            echo "Orca $n  \"$(slot_field "$n" label)\"  $(slot_field "$n" branch) @ $(slot_field "$n" commit)  last built $built_ago  ($(slot_field "$n" worktree))"
        else
            echo "Orca $n  free"
        fi
    done
    if main_hold_is_active; then
        built="$(slot_field main-holder built_epoch)"
        echo "Orca Browser  testing \"$(slot_field main-holder label)\"  $(slot_field main-holder branch) @ $(slot_field main-holder commit)  last built $(format_age $(( $(date +%s) - ${built:-0} ))) ago  ($(slot_field main-holder worktree))"
    elif [[ -f "$(slot_file main-holder)" ]]; then
        echo "Orca Browser  free (still has $(slot_field main-holder branch)'s build, which is no longer held; --main puts main back)"
    else
        echo "Orca Browser  main"
    fi
}

find_slot_for_this_checkout() {
    local n
    for n in $(seq 1 "$SLOT_COUNT"); do
        [[ -f "$(slot_file "$n")" ]] || continue
        if [[ "$(slot_field "$n" worktree)" == "$root" && "$(slot_field "$n" branch)" == "$branch" ]]; then
            echo "$n"; return 0
        fi
    done
    return 1
}

claim_slot() {
    local n
    if n="$(find_slot_for_this_checkout)"; then echo "$n"; return 0; fi
    for n in $(seq 1 "$SLOT_COUNT"); do
        if slot_is_stale "$n"; then rm -f "$(slot_file "$n")"; fi
    done
    for n in $(seq 1 "$SLOT_COUNT"); do
        [[ -f "$(slot_file "$n")" ]] || { write_slot "$n"; echo "$n"; return 0; }
    done
    for n in $(seq 1 "$SLOT_COUNT"); do
        if slot_pr_is_done "$n"; then write_slot "$n"; echo "$n"; return 0; fi
    done
    return 1
}

write_slot() {
    cat > "$(slot_file "$1")" <<EOF
branch=$branch
worktree=$root
commit=$commit
label=$label
built_epoch=$(date +%s)
EOF
}

case "$mode" in
    status)
        print_status
        exit 0
        ;;
    release)
        with_lock
        if n="$(find_slot_for_this_checkout)"; then
            rm -f "$(slot_file "$n")"
            echo "Released Orca $n (it stays installed on the phone until another branch overwrites it)."
        else
            echo "$branch holds no slot."
        fi
        rmdir "$SLOTS_DIR/.lock" 2>/dev/null || true
        acquire_main_lock
        if [[ -f "$(slot_file main-holder)" && "$(slot_field main-holder worktree)" == "$root" && "$(slot_field main-holder branch)" == "$branch" ]]; then
            echo "released=1" >> "$(slot_file main-holder)"
            echo "Released the regular app (it keeps this build on the phone until --main rebuilds it)."
        fi
        exit 0
        ;;
esac

# Pick the device before spending a minute on a build.
if [[ $build_only -eq 0 ]]; then
    if [[ -z "$device" ]]; then
        listing="$(mktemp)"
        # An idle paired phone lists as disconnected until a command wakes it.
        for attempt in 1 2; do
            xcrun devicectl list devices --json-output "$listing" >/dev/null 2>&1 || true
            device="$(jq -r '[.result.devices[]?
                | select(.hardwareProperties.reality == "physical"
                         and .connectionProperties.tunnelState == "connected")][0]
                | .hardwareProperties.udid // empty' "$listing")"
            [[ -n "$device" || $attempt -eq 2 ]] && break
            for udid in $(jq -r '.result.devices[]?
                | select(.hardwareProperties.reality == "physical"
                         and .connectionProperties.pairingState == "paired")
                | .hardwareProperties.udid' "$listing"); do
                xcrun devicectl device info details --device "$udid" >/dev/null 2>&1 || true
            done
        done
        rm -f "$listing"
        if [[ -z "$device" ]]; then
            echo "No iPhone is connected. Plug it in (or pass --device), unlock it, and run again." >&2
            exit 1
        fi
    fi
fi

settings=()
if [[ "$mode" == main ]]; then
    slot_name=main
    bundle_id="$BASE_ID"
    lock_main

    # No notes given: show the latest 5 updates, with the rest behind a
    # "more" button, unless nothing new has landed since the last main build.
    main_state="$SLOTS_DIR/main"
    last_main="$(grep '^commit=' "$main_state" 2>/dev/null | cut -d= -f2- || true)"
    if [[ ${#changed[@]} -eq 0 && ${#tests[@]} -eq 0 ]]; then
        if [[ "$last_main" != "$(git rev-parse HEAD)" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                if [[ ${#changed[@]} -lt $RECENT_UPDATES ]]; then changed+=("$line"); else older+=("$line"); fi
            done < <(list_updates)
            notes_heading="Recent updates"
            # The updates since the last main build are the new ones; the rest are earlier.
            if [[ -n "$last_main" ]] && git cat-file -e "$last_main^{commit}" 2>/dev/null; then
                new_count="$(list_updates "$last_main..HEAD" | grep -c . || true)"
            else
                new_count=1
            fi
        fi
    fi
    settings+=("ORCA_BUILD_SLOT=main" "ORCA_BUILD_COMMIT=$commit" "ORCA_BUILD_LABEL=What's new")
    add_notes_settings || echo "Nothing new on main since the last main build, so no what's-new panel." >&2
elif [[ "$mode" == asmain ]]; then
    # This branch in the regular app: same bundle ID and icon as main, so the
    # test uses the real app and its data, with main's invisible stamp.
    slot_name=main
    bundle_id="$BASE_ID"
    [[ -n "$label" ]] || label="$(default_label)"
    lock_main
    settings+=("ORCA_BUILD_SLOT=main" "ORCA_BUILD_COMMIT=$commit" "ORCA_BUILD_LABEL=$label")
    add_notes_settings || echo "No --changed or --test notes given, so the app won't show a what's-new panel for this build." >&2
    echo "Installing this branch over the regular Orca Browser app. Run --main afterwards to put main back." >&2
else
    with_lock
    if [[ -z "$label" ]]; then
        if existing="$(find_slot_for_this_checkout)"; then label="$(slot_field "$existing" label)"; fi
        [[ -n "$label" ]] || label="$(default_label)"
    fi
    if [[ -n "$takeover" ]]; then
        if ! [[ "$takeover" =~ ^[0-9]+$ ]] || [[ "$takeover" -lt 1 || "$takeover" -gt $SLOT_COUNT ]]; then
            echo "--takeover takes a slot number from 1 to $SLOT_COUNT." >&2
            exit 2
        fi
        # Give up any slot this branch already holds, then take the requested one.
        if existing="$(find_slot_for_this_checkout)"; then rm -f "$(slot_file "$existing")"; fi
        if [[ -f "$(slot_file "$takeover")" ]]; then
            echo "Taking over Orca $takeover from $(slot_field "$takeover" branch) ($(slot_field "$takeover" label))."
        fi
        write_slot "$takeover"
        slot="$takeover"
    elif ! slot="$(claim_slot)"; then
        echo "All $SLOT_COUNT test slots are in use, so nothing was built. Not overwriting another branch's build:" >&2
        print_status >&2
        echo "Report this to the user and let them decide. Don't take a slot unasked. If they say to," >&2
        echo "run again with --takeover N (the other branch's next build will pick a new slot)." >&2
        exit 3
    fi
    slot_name="dev $slot"
    bundle_id="$BASE_ID.dev$slot"
    settings+=("PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" "INFOPLIST_KEY_CFBundleDisplayName=Orca $slot" "ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev$slot")
    settings+=("ORCA_BUILD_SLOT=$slot_name" "ORCA_BUILD_COMMIT=$commit" "ORCA_BUILD_LABEL=$label")
    add_notes_settings || echo "No --changed or --test notes given, so the app won't show a what's-new panel for this build." >&2

    # Slot claimed: the rest can run without holding the lock.
    rmdir "$SLOTS_DIR/.lock" 2>/dev/null || true
    trap - EXIT
fi

derived="$root/build"
log="$derived/ship-to-phone.log"
mkdir -p "$derived"
echo "Building $branch @ $commit as $slot_name ($configuration)..."
if ! xcodebuild \
        -project OrcaBrowser.xcodeproj \
        -scheme OrcaBrowser \
        -configuration "$configuration" \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$derived" \
        -skipPackagePluginValidation \
        -allowProvisioningUpdates \
        ${settings[@]+"${settings[@]}"} \
        build >"$log" 2>&1; then
    grep -E "error:|BUILD FAILED" "$log" | head -20 >&2 || true
    echo "Build failed. Full log: $log" >&2
    exit 1
fi

app="$derived/Build/Products/$configuration-iphoneos/OrcaBrowser.app"
if [[ $build_only -eq 1 ]]; then
    echo "Built $app"
else
    echo "Installing on the phone..."
    xcrun devicectl device install app --device "$device" "$app" >>"$log" 2>&1 || {
        tail -15 "$log" >&2
        echo "Install failed. Is the phone unlocked and trusted? Log: $log" >&2
        exit 1
    }
    xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle_id" >>"$log" 2>&1 \
        || echo "Installed, but couldn't launch it (phone locked?). Open it by hand."
    echo "Done: $slot_name ($branch_label @ $commit) is on the phone."
    if [[ "$mode" == main ]]; then
        printf 'commit=%s\nbuilt_epoch=%s\n' "$(git rev-parse HEAD)" "$(date +%s)" > "$main_state"
        rm -f "$(slot_file main-holder)"
    elif [[ "$mode" == asmain ]]; then
        write_slot main-holder
    fi
fi

# Remember what's in the slot, so --status and other branches can see it.
if [[ "$mode" == ship ]]; then
    with_lock
    write_slot "$slot"
fi
