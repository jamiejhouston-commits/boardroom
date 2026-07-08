import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_PATH = Path(__file__).with_name("hermes_watchdog.py")
SPEC = importlib.util.spec_from_file_location("hermes_watchdog", SCRIPT_PATH)
watchdog = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(watchdog)


class HealthTests(unittest.TestCase):
    def test_ok_true_is_healthy_anything_else_is_not(self):
        class FakeResponse:
            def __init__(self, body):
                self.body = body

            def read(self):
                return self.body

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        with mock.patch.object(watchdog.urllib.request, "urlopen",
                               return_value=FakeResponse(b'{"ok": true}')):
            self.assertTrue(watchdog.relay_healthy())
        with mock.patch.object(watchdog.urllib.request, "urlopen",
                               return_value=FakeResponse(b'{"ok": false}')):
            self.assertFalse(watchdog.relay_healthy())
        with mock.patch.object(watchdog.urllib.request, "urlopen",
                               side_effect=OSError("refused")):
            self.assertFalse(watchdog.relay_healthy())

    def test_missing_tailscale_cli_reads_as_running(self):
        with mock.patch.object(watchdog.Path, "exists", return_value=False):
            self.assertTrue(watchdog.tailscale_running())


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.hermes = Path(self.tmp.name) / ".hermes"
        self.hermes.mkdir()
        self.backups = self.hermes / "backups"
        (self.hermes / "mobile-company.json").write_text('{"initiatives": []}')
        (self.hermes / "mobile-relay.json").write_text('{"token": "t"}')

    def tearDown(self):
        self.tmp.cleanup()

    def test_backup_copies_state_once_per_day(self):
        folder = watchdog.backup_today(hermes_dir=self.hermes,
                                       backup_root=self.backups)
        self.assertIsNotNone(folder)
        self.assertEqual(json.loads((folder / "mobile-company.json").read_text()),
                         {"initiatives": []})
        self.assertFalse((folder / "mobile-games-studio.json").exists())  # absent → skipped
        self.assertIsNone(watchdog.backup_today(hermes_dir=self.hermes,
                                                backup_root=self.backups))  # same day: no-op

    def test_prune_keeps_the_newest_n(self):
        for day in ("2026-06-20", "2026-06-21", "2026-06-22", "2026-06-23"):
            (self.backups / day).mkdir(parents=True)
        removed = watchdog.prune_backups(backup_root=self.backups, keep=2)
        self.assertEqual(removed, ["2026-06-20", "2026-06-21"])
        self.assertEqual(sorted(p.name for p in self.backups.iterdir()),
                         ["2026-06-22", "2026-06-23"])


if __name__ == "__main__":
    unittest.main()
