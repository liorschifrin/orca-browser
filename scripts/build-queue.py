#!/usr/bin/env python3
"""Shared phone-build queue. Run --help for commands; no third-party packages."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


def run(args, cwd=None, capture=False, env=None):
    """Run a command without shell interpolation, optionally capturing its output."""
    return subprocess.run(args, cwd=cwd, text=True, capture_output=capture, env=env)


def revision(root):
    """Return a clean worktree’s commit, rejecting pending or untracked changes."""
    head = run(['git', 'rev-parse', 'HEAD'], root, True)
    status = run(['git', 'status', '--porcelain'], root, True)
    if head.returncode or status.returncode or status.stdout.strip():
        raise ValueError('Commit or remove pending changes before registering/building this worktree.')
    return head.stdout.strip()


class Queue:
    def __init__(self, directory):
        """Locate shared queue state and locks outside branch checkouts."""
        self.directory = Path(directory).expanduser()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path = self.directory / 'queue.json'

    @contextlib.contextmanager
    def locked(self, name='queue.lock', blocking=True):
        """Hold an advisory lock for queue updates or the lifetime of a build."""
        with (self.directory / name).open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            except BlockingIOError:
                raise ValueError('Another queue build is running.')
            yield

    def read(self):
        """Read shared state, using an empty queue before the first registration."""
        return json.loads(self.path.read_text()) if self.path.exists() else {'items': [], 'paused': None}

    def ship(self, root, args):
        """Run the owning branch’s shipper with the same shared slot directory."""
        return run([str(Path(root) / 'scripts/ship-to-phone.sh'), *args], root,
                   env={**os.environ, 'ORCA_SLOTS_DIR': str(self.directory.resolve())})

    def save(self, data):
        """Atomically replace queue state while the caller holds the queue lock."""
        with tempfile.NamedTemporaryFile(mode='w', dir=self.directory, delete=False) as out:
            json.dump(data, out, indent=2)
            out.write('\n')
            temp = out.name
        os.replace(temp, self.path)

    def update(self, change):
        """Apply a state mutation under the shared lock and persist the result."""
        with self.locked():
            data = self.read()
            result = change(data)
            self.save(data)
            return result

    def next(self, automatic=False):
        """Build the first usable ready item, respecting pauses for message-driven attempts."""
        with self.locked('queue-build.lock', blocking=False):
            with self.locked():
                data = self.read()
                # A previous interrupted process must never silently retry an installation.
                if any(i['state'] == 'building' for i in data['items']):
                    raise ValueError('Interrupted build needs inspection; use ready or defer to resolve it.')
                if automatic and data['paused']:
                    print('Paused:', data['paused'])
                    return
                candidates = sorted((i for i in data['items'] if i['state'] == 'ready'),
                                    key=lambda i: (-i['priority'], i['queued_at']))
                if not candidates:
                    print('No builds ready.')
                    return
                for item in candidates:
                    root = item['worktree']
                    try:
                        if revision(root) != item['revision']:
                            raise ValueError('Revision changed; register the new version when ready.')
                    except (ValueError, OSError) as error:
                        item['state'] = 'stale'
                        item['detail'] = str(error)
                        self.save(data)
                        print(f"{item['label']}: {error}")
                        continue
                    try:
                        available = self.ship(root, ['--queue-check'])
                        code = available.returncode
                    except OSError as error:
                        code = 1
                        print(error)
                    if code == 3:
                        print('Waiting for a test slot.')
                        return
                    if code == 2:
                        item['state'] = 'stale'
                        item['detail'] = 'Slot check failed. Bring the queue-aware ship script into this branch before registering again.'
                        self.save(data)
                        print(item['detail'])
                        continue
                    if code:
                        item['detail'] = f'Slot check exited {code}; inspect the slot lock and git status before retrying.'
                        data['paused'] = 'Slot check failed. Say “build next” when ready to retry.'
                        self.save(data)
                        print(item['detail'])
                        return
                    break
                else:
                    return
                item['state'] = 'building'
                item.pop('detail', None)
                data['paused'] = None
                self.save(data)
                snapshot = dict(item)
            args = ['--label', snapshot['label'], '--thread', snapshot['thread']]
            for note in snapshot['changed']:
                args += ['--changed', note]
            for note in snapshot['test']:
                args += ['--test', note]
            # Keep the queue lock free during the build; other threads can register work.
            try:
                result = self.ship(root, args)
                code = result.returncode
            except OSError as error:
                code = 1
                print(error)
            unchanged = True
            if code == 0:
                try:
                    unchanged = revision(root) == snapshot['revision']
                except (ValueError, OSError):
                    unchanged = False
            def finish(data):
                """Record installation results without releasing a possibly occupied slot."""
                current = next(i for i in data['items'] if i['worktree'] == root)
                current['state'] = 'installed' if code == 0 else 'ready'
                current['detail'] = 'Awaiting your feedback in the owning thread.' if code == 0 else f'Build/install exited {code}; inspect the build log before retrying.'
                if not unchanged:
                    current['state'] = 'stale'
                    current['detail'] = 'Worktree changed during the build. Installed version is unverified; inspect before re-registering or releasing its slot.'
                if code not in (0, 3):
                    data['paused'] = 'Build or phone unavailable. Say “build next” when ready to retry.'
            self.update(finish)


def main():
    """Dispatch queue commands and print T3 notification payloads after mutations."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', default=os.environ.get('ORCA_SLOTS_DIR', '~/.orca-slots'))
    commands = parser.add_subparsers(dest='command', required=True)
    ready = commands.add_parser('ready', help='Register the current committed worktree.')
    ready.add_argument('--label', required=True)
    ready.add_argument('--thread', required=True)
    ready.add_argument('--changed', action='append', required=True)
    ready.add_argument('--test', action='append', default=[])
    ready.add_argument('--priority', type=int, default=0)
    commands.add_parser('status')
    manager = commands.add_parser('manager', help='Set the T3 thread to notify after queue changes.')
    manager.add_argument('--thread', required=True)
    for command in ('release', 'defer', 'prioritize'):
        sub = commands.add_parser(command)
        sub.add_argument('--worktree', help='Defaults to the current worktree; manager may target another.')
        if command == 'prioritize':
            sub.add_argument('priority', type=int)
    nxt = commands.add_parser('next', help='Build next; explicitly retries a paused queue.')
    nxt.add_argument('--automatic', action='store_true', help='Respect phone/failure pause.')
    args = parser.parse_args()
    queue = Queue(args.directory)
    if args.command == 'status':
        with queue.locked():
            print(json.dumps(queue.read(), indent=2))
        return
    if args.command == 'next':
        queue.next(args.automatic)
        return
    if args.command == 'manager':
        queue.update(lambda data: data.update(manager_thread=args.thread))
        print('Queue manager:', args.thread)
        return
    root_result = run(['git', 'rev-parse', '--show-toplevel'], capture=True)
    if root_result.returncode:
        raise ValueError('Run inside an Orca worktree.')
    root = str(Path(getattr(args, 'worktree', None) or root_result.stdout.strip()).resolve())
    head = revision(root) if args.command == 'ready' else None

    def change(data):
        """Apply an owning-thread command without disturbing an active build."""
        item = next((i for i in data['items'] if i['worktree'] == root), None)
        if item and item['state'] == 'building':
            # Allow recovery only when no build process holds the build lock.
            with queue.locked('queue-build.lock', blocking=False):
                pass
        if args.command == 'ready':
            if item is None:
                item = {'worktree': root}
                data['items'].append(item)
            item.update(state='ready', revision=head, label=args.label, thread=args.thread,
                        changed=args.changed, test=args.test, priority=args.priority, queued_at=time.time())
            item.pop('detail', None)
        elif item is None and args.command != 'release':
            raise ValueError('No queue entry for this worktree.')
        elif args.command == 'prioritize':
            item['priority'] = args.priority
        elif args.command == 'defer':
            item['state'] = 'deferred'
        elif args.command == 'release':
            result = queue.ship(root, ['--release'])
            if result.returncode:
                raise ValueError('Slot release failed; queue unchanged.')
            if item:
                item['state'] = 'released'
        print(f'{args.command}: {root}')
    queue.update(change)
    # The owning agent sends this with T3's thread-send tool. The CLI does not
    # have T3 credentials and never schedules work or starts a polling process.
    with queue.locked():
        manager_thread = queue.read().get('manager_thread')
    if manager_thread:
        print('Send this notification using t3_thread_send after the command succeeds:')
        print(json.dumps(dict(threadId=manager_thread, mode='auto',
                              clientRequestId='orca-queue-' + str(uuid.uuid4()),
                              message=f'Orca build queue changed: {args.command} for {root}. '
                                      'Read queue status and advance ready builds with next --automatic '
                                      'if slots are available. Respect any phone/build pause; do not retry it.')))
    else:
        print('No manager configured. Set one with: build-queue.py manager --thread THREAD_ID; then notify it using t3_thread_send.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
