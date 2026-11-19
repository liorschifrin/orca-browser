"""Exercise queue transitions with temporary git checkouts and a fake shipper."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('build_queue', Path(__file__).parents[1] / 'build-queue.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.queue = module.Queue(self.base / 'slots')

    def checkout(self, name, priority=0):
        root = self.base / name
        (root / 'scripts').mkdir(parents=True)
        script = root / 'scripts/ship-to-phone.sh'
        script.write_text('''#!/bin/sh
case "$1" in
 --queue-check) exit "${CHECK_CODE:-0}" ;;
 --release) exit 0 ;;
esac
printf '%s\\n' "$@" > "$ORCA_SLOTS_DIR/last-args"
exit "${SHIP_CODE:-0}"
''')
        script.chmod(0o755)
        for args in (['init', '-q'], ['add', '.'], ['-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'initial']):
            subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)
        item = dict(worktree=str(root), revision=module.revision(root), priority=priority,
                    queued_at=len(self.queue.read()['items']), state='ready', label=name,
                    thread='test-thread', changed=['A change'], test=['Try it'])
        self.queue.update(lambda data: data['items'].append(item))
        return root

    def test_priority_and_notes_and_release(self):
        self.checkout('first')
        root = self.checkout('urgent', 10)
        self.queue.next()
        items = self.queue.read()['items']
        self.assertEqual([i['state'] for i in items], ['ready', 'installed'])
        self.assertEqual((self.queue.directory / 'last-args').read_text().splitlines(),
                         ['--label', 'urgent', '--thread', 'test-thread', '--changed', 'A change', '--test', 'Try it'])
        with patch('sys.argv', ['queue', '--directory', str(self.queue.directory), 'release', '--worktree', str(root)]):
            module.main()
        self.assertEqual(self.queue.read()['items'][1]['state'], 'released')
        self.queue.next(automatic=True)
        self.assertEqual(self.queue.read()['items'][0]['state'], 'installed')

    def test_unavailable_phone_pauses_until_explicit_retry(self):
        self.checkout('first')
        with patch.dict('os.environ', {'SHIP_CODE': '1'}):
            self.queue.next()
        self.assertTrue(self.queue.read()['paused'])
        self.queue.next(automatic=True)
        self.assertEqual(self.queue.read()['items'][0]['state'], 'ready')
        self.queue.next()
        self.assertEqual(self.queue.read()['items'][0]['state'], 'installed')
        self.assertIsNone(self.queue.read()['paused'])

    def test_full_slots_leave_work_ready_without_phone_attempt(self):
        self.checkout('first')
        with patch.dict('os.environ', {'CHECK_CODE': '3'}):
            self.queue.next(automatic=True)
        self.assertEqual(self.queue.read()['items'][0]['state'], 'ready')
        self.assertFalse((self.queue.directory / 'last-args').exists())

    def test_edits_invalidate_registration(self):
        root = self.checkout('first')
        (root / 'new.txt').write_text('new work')
        self.queue.next()
        self.assertEqual(self.queue.read()['items'][0]['state'], 'stale')
        self.assertFalse((self.queue.directory / 'last-args').exists())

    def test_manager_configuration_and_message_handoff(self):
        root = self.checkout('first')
        common = ['queue', '--directory', str(self.queue.directory)]
        with patch('sys.argv', common + ['manager', '--thread', 'manager-thread']):
            module.main()
        self.assertEqual(self.queue.read()['manager_thread'], 'manager-thread')
        output = io.StringIO()
        with patch('sys.argv', common + ['release', '--worktree', str(root)]), contextlib.redirect_stdout(output):
            module.main()
        notification = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(notification['threadId'], 'manager-thread')
        self.assertEqual(notification['mode'], 'auto')
        self.assertIn('release', notification['message'])
        self.assertIn('next --automatic', notification['message'])
        self.assertEqual(self.queue.read()['items'][0]['state'], 'released')

    def test_slot_taken_after_probe_stays_ready(self):
        self.checkout('first')
        with patch.dict('os.environ', {'SHIP_CODE': '3'}):
            self.queue.next(automatic=True)
        self.assertEqual(self.queue.read()['items'][0]['state'], 'ready')
        self.assertIsNone(self.queue.read()['paused'])

    def test_old_shipper_requires_registration_after_upgrade(self):
        self.checkout('old')
        with patch.dict('os.environ', {'CHECK_CODE': '2'}):
            self.queue.next(automatic=True)
        self.assertEqual(self.queue.read()['items'][0]['state'], 'stale')

    def test_stale_head_does_not_block_next_ready_build(self):
        root = self.checkout('stale')
        self.checkout('usable')
        (root / 'new.txt').write_text('unfinished changes')
        self.queue.next(automatic=True)
        self.assertEqual([i['state'] for i in self.queue.read()['items']], ['stale', 'installed'])

    def test_old_shipper_does_not_block_next_ready_build(self):
        root = self.checkout('old')
        self.checkout('usable')
        original_ship = self.queue.ship
        def probe(checkout, args):
            if checkout == str(root) and args == ['--queue-check']:
                return subprocess.CompletedProcess(args, 2)
            return original_ship(checkout, args)
        with patch.object(self.queue, 'ship', side_effect=probe):
            self.queue.next(automatic=True)
        self.assertEqual([i['state'] for i in self.queue.read()['items']], ['stale', 'installed'])

    def test_transient_slot_check_failure_pauses_and_can_retry(self):
        self.checkout('first')
        with patch.dict('os.environ', {'CHECK_CODE': '1'}):
            self.queue.next(automatic=True)
        data = self.queue.read()
        self.assertEqual(data['items'][0]['state'], 'ready')
        self.assertTrue(data['paused'])
        self.assertIn('exited 1', data['items'][0]['detail'])
        self.queue.next(automatic=True)
        self.assertFalse((self.queue.directory / 'last-args').exists())
        self.queue.next()
        self.assertEqual(self.queue.read()['items'][0]['state'], 'installed')

    def test_defer_skips_item_and_reregister_replaces_it(self):
        root = self.checkout('first')
        common = ['queue', '--directory', str(self.queue.directory)]
        with patch('sys.argv', common + ['defer', '--worktree', str(root)]):
            module.main()
        self.queue.next(automatic=True)
        self.assertFalse((self.queue.directory / 'last-args').exists())
        with patch('os.getcwd', return_value=str(root)), patch('sys.argv', common + [
                'ready', '--label', 'Updated', '--thread', 'new-thread', '--changed', 'Updated change']):
            # git's cwd follows the real process, so isolate the repository lookup.
            original_run = module.run
            def in_checkout(args, cwd=None, capture=False, env=None):
                return original_run(args, cwd or root, capture, env)
            with patch.object(module, 'run', side_effect=in_checkout):
                module.main()
        items = self.queue.read()['items']
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]['state'], 'ready')
        self.assertEqual(items[0]['thread'], 'new-thread')

    def test_interrupted_build_and_concurrent_build_are_not_repeated(self):
        self.checkout('first')
        with self.queue.locked('queue-build.lock'):
            with self.assertRaisesRegex(ValueError, 'Another queue build'):
                self.queue.next()
        self.queue.update(lambda data: data['items'][0].update(state='building'))
        with self.assertRaisesRegex(ValueError, 'Interrupted build'):
            self.queue.next()


if __name__ == '__main__':
    unittest.main()
