import importlib.util
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("hermes_mobile_relay.py")
SPEC = importlib.util.spec_from_file_location("hermes_mobile_relay", SCRIPT_PATH)
relay = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(relay)


class HermesMobileRelayTests(unittest.TestCase):
    def test_first_turn_starts_fresh_chat_without_continue(self):
        command = relay.chat_command("hello", "default", None)

        self.assertNotIn("--continue", command)
        self.assertNotIn("--resume", command)
        self.assertEqual(command[-2:], ["-q", "hello"])

    def test_later_turn_resumes_real_hermes_session_id(self):
        command = relay.chat_command("again", "default", "20260609_174801_abc123")

        self.assertIn("--resume", command)
        self.assertNotIn("--continue", command)
        resume_index = command.index("--resume")
        self.assertEqual(command[resume_index + 1], "20260609_174801_abc123")

    def test_extracts_session_id_from_resume_hint(self):
        output = """
        Confirmed.

        Resume this session with:
          hermes --resume 20260609_174801_abc123
        """

        self.assertEqual(relay.extract_session_id(output), "20260609_174801_abc123")

    def test_strips_resume_metadata_from_reply(self):
        output = """Confirmed.

Resume this session with:
  hermes --resume 20260609_174801_abc123

Session:        20260609_174801_abc123
Messages:       2
"""

        self.assertEqual(relay.clean_reply(output), "Confirmed.")

    def test_session_registry_persists_mobile_key_mapping(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = Path(temp_dir) / "mobile-relay.json"
            registry = relay.RelayConfigStore(config_path)

            registry.save_session("main", "iphone-session", "20260609_174801_abc123")

            reloaded = relay.RelayConfigStore(config_path)
            self.assertEqual(
                reloaded.session_id("main", "iphone-session"),
                "20260609_174801_abc123",
            )


class CompanyRunnerTests(unittest.TestCase):
    def test_company_chat_command_resumes_role_session(self):
        command = relay.company_chat_command("do work", "builder", "20260611_120000_abc123")
        self.assertIn("--resume", command)
        self.assertEqual(command[command.index("--resume") + 1], "20260611_120000_abc123")
        self.assertEqual(command[-2:], ["-q", "do work"])

    def test_company_chat_command_first_call_has_no_resume(self):
        command = relay.company_chat_command("scan trends", "research", None)
        self.assertNotIn("--resume", command)

    def test_company_summary_strips_minutes(self):
        state = relay.company_module.new_state()
        init = relay.company_module.new_initiative("A", "pitch")
        init["minutes"] = [{"stage": "research", "role": "research", "text": "x" * 9000, "ts": "t"}]
        state["initiatives"] = [init]
        summary = relay.company_summary(state)
        self.assertEqual(summary["initiatives"][0]["title"], "A")
        self.assertNotIn("minutes", summary["initiatives"][0])


class TurnTimeoutTests(unittest.TestCase):
    def test_default_is_30_minutes_when_no_config(self):
        original = relay.COMPANY_STATE_PATH
        relay.COMPANY_STATE_PATH = Path(tempfile.gettempdir()) / "nope-no-state.json"
        try:
            self.assertEqual(relay.company_turn_timeout(), 1800)
        finally:
            relay.COMPANY_STATE_PATH = original

    def test_owner_can_raise_timeout_via_company_config(self):
        original = relay.COMPANY_STATE_PATH
        with tempfile.TemporaryDirectory() as tmp:
            state_path = Path(tmp) / "state.json"
            state_path.write_text('{"config": {"turn_timeout_minutes": 45}}')
            relay.COMPANY_STATE_PATH = state_path
            try:
                self.assertEqual(relay.company_turn_timeout(), 45 * 60)
            finally:
                relay.COMPANY_STATE_PATH = original

    def test_timeout_is_clamped_to_sane_bounds(self):
        original = relay.COMPANY_STATE_PATH
        with tempfile.TemporaryDirectory() as tmp:
            state_path = Path(tmp) / "state.json"
            state_path.write_text('{"config": {"turn_timeout_minutes": 100000}}')
            relay.COMPANY_STATE_PATH = state_path
            try:
                self.assertEqual(relay.company_turn_timeout(), 120 * 60)
            finally:
                relay.COMPANY_STATE_PATH = original

    def test_turn_timeout_error_is_short_and_human(self):
        # str(TimeoutExpired) embeds the whole 4KB role prompt; the runner must
        # surface one readable line instead (the app shows it to the owner).
        original_run = relay.run_killable

        def fake_run_killable(command, timeout):
            raise subprocess.TimeoutExpired(cmd=command, timeout=timeout)

        relay.run_killable = fake_run_killable
        try:
            with self.assertRaises(RuntimeError) as caught:
                relay.company_cli_runner("builder", "long prompt " * 400)
        finally:
            relay.run_killable = original_run
        message = str(caught.exception)
        self.assertLess(len(message), 200)
        self.assertIn("builder turn timed out after", message)
        self.assertIn("resumes next tick", message)


class ShipTests(unittest.TestCase):
    def test_ship_commands_create_private_repo_from_outdir(self):
        commands = relay.ship_commands(Path("/tmp/proj-x"), "proj-x")
        gh = commands[-1]
        # gh is now an ABSOLUTE path, so branch on the basename.
        self.assertEqual(os.path.basename(gh[0]), "gh")
        self.assertEqual(gh[1:3], ["repo", "create"])
        self.assertIn("--private", gh)
        self.assertIn("--push", gh)
        self.assertIn("/tmp/proj-x", gh)
        # Every git command targets the deliverables dir, not the CWD.
        for command in commands[:-1]:
            self.assertEqual(os.path.basename(command[0]), "git")
            self.assertIn("/tmp/proj-x", command)

    def test_ship_commands_use_absolute_resolvable_binaries(self):
        # PATH-independence: no bare "git"/"gh" strings — every binary is an
        # absolute, existing, executable path so ship survives a stripped PATH.
        commands = relay.ship_commands(Path("/tmp/proj-x"), "proj-x")
        for command in commands:
            binary = command[0]
            self.assertNotIn(binary, ("git", "gh"),
                             "ship must resolve absolute binary paths, not bare names")
            self.assertTrue(os.path.isabs(binary), f"{binary} is not absolute")
            self.assertTrue(os.access(binary, os.X_OK), f"{binary} is not executable")

    def test_resolve_bin_finds_git_on_augmented_path(self):
        # Even with an empty process PATH, the fallback dirs locate git.
        original = os.environ.get("PATH", "")
        relay._BIN_CACHE.clear()
        os.environ["PATH"] = ""
        try:
            resolved = relay._resolve_bin("git")
            self.assertTrue(os.path.isabs(resolved))
            self.assertTrue(os.access(resolved, os.X_OK))
        finally:
            os.environ["PATH"] = original
            relay._BIN_CACHE.clear()

    def test_resolve_bin_raises_named_error_when_missing(self):
        relay._BIN_CACHE.clear()
        with self.assertRaises(RuntimeError) as ctx:
            relay._resolve_bin("definitely-not-a-real-binary-xyz")
        self.assertIn("definitely-not-a-real-binary-xyz", str(ctx.exception))

    def test_reship_already_exists_yields_url_from_remote(self):
        # Root cause 2: after a revise->re-ship, gh returns "already exists"
        # and emits no URL; the push succeeds but url stayed None, so the
        # function used to return None. It must now derive the URL from the
        # existing remote instead of falsely reporting "no repo URL returned".
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            outdir = root / "Boardroom" / "quake-app-abc1"
            outdir.mkdir(parents=True)
            (outdir / "file.txt").write_text("deliverable")

            git = relay._resolve_bin("git")
            subprocess.run([git, "-C", str(outdir), "init", "-b", "main"],
                           capture_output=True, check=True)
            subprocess.run([git, "-C", str(outdir), "remote", "add", "origin",
                            "git@github.com:owner/quake-app.git"],
                           capture_output=True, check=True)

            original_root = relay.COMPANY_ARTIFACTS_ROOT
            relay.COMPANY_ARTIFACTS_ROOT = root / "Boardroom"
            original_run = subprocess.run

            def fake_run(command, *args, **kwargs):
                # Stub only the gh + push network calls; let real git run.
                if os.path.basename(command[0]) == "gh":
                    return subprocess.CompletedProcess(
                        command, 1, "", "GraphQL: Name already exists on this account")
                if command[:2] == [git, "-C"] and "push" in command:
                    return subprocess.CompletedProcess(command, 0, "", "")
                return original_run(command, *args, **kwargs)

            init = {"id": "abc1", "title": "Quake App", "pitch": "p"}
            try:
                relay.subprocess.run = fake_run
                url = relay.ship_initiative(init)
            finally:
                relay.subprocess.run = original_run
                relay.COMPANY_ARTIFACTS_ROOT = original_root

            self.assertEqual(url, "https://github.com/owner/quake-app")


class PushTests(unittest.TestCase):
    def test_apns_message_shape(self):
        message = relay.apns_message("Title", "Body", "BOARDROOM_GATE",
                                     {"initiative_id": "abc1"})
        self.assertEqual(message["aps"]["alert"], {"title": "Title", "body": "Body"})
        self.assertEqual(message["aps"]["category"], "BOARDROOM_GATE")
        self.assertEqual(message["initiative_id"], "abc1")

    def test_apns_message_omits_empty_category(self):
        self.assertNotIn("category", relay.apns_message("T", "B")["aps"])

    def test_gate_transitions_detects_only_new_arrivals(self):
        before = {"initiatives": [{"id": "a", "stage": "boardroom"},
                                  {"id": "b", "stage": "gate2"},
                                  {"id": "c", "stage": "planning"}]}
        after = {"initiatives": [{"id": "a", "stage": "gate1"},
                                 {"id": "b", "stage": "gate2"},
                                 {"id": "c", "stage": "execution"}]}
        moved = relay.gate_transitions(before, after)
        self.assertEqual([i["id"] for i in moved], ["a"])   # b was already gated

    def test_gate_transitions_detects_blocked(self):
        before = {"initiatives": [{"id": "x", "stage": "execution"}]}
        after = {"initiatives": [{"id": "x", "stage": "blocked"}]}
        self.assertEqual(len(relay.gate_transitions(before, after)), 1)

    def test_gate_push_content_carries_actionable_payload(self):
        init = {"id": "abc1", "stage": "gate2", "title": "Quake App", "pitch": "p"}
        title, body, category, payload = relay.gate_push_content(init)
        self.assertIn("Demo Day", title)
        self.assertEqual(category, "BOARDROOM_GATE")
        self.assertEqual(payload["initiative_id"], "abc1")
        self.assertEqual(payload["stage"], "gate2")

    def test_send_push_is_noop_without_tokens(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            original = relay.CONFIG_PATH
            relay.CONFIG_PATH = Path(temp_dir) / "mobile-relay.json"
            try:
                self.assertEqual(relay.send_push("t", "b"), 0)   # never raises
            finally:
                relay.CONFIG_PATH = original

    def test_register_and_drop_push_token_roundtrip(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            original = relay.CONFIG_PATH
            relay.CONFIG_PATH = Path(temp_dir) / "mobile-relay.json"
            try:
                relay.register_push_token("ab12")
                relay.register_push_token("cd34")
                relay.register_push_token("ab12")           # dedupes, moves last
                self.assertEqual(relay.push_tokens(), ["cd34", "ab12"])
                relay.drop_push_token("cd34")
                self.assertEqual(relay.push_tokens(), ["ab12"])
            finally:
                relay.CONFIG_PATH = original


class DemoAssetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.original_state = relay.COMPANY_STATE_PATH
        self.original_artifacts = relay.COMPANY_ARTIFACTS_ROOT
        relay.COMPANY_STATE_PATH = root / "company.json"
        relay.COMPANY_ARTIFACTS_ROOT = root / "Boardroom"
        state = relay.company_module.new_state()
        self.init = relay.company_module.new_initiative("Quake App", "p")
        state["initiatives"] = [self.init]
        relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).save(state)
        self.demo_dir = (relay.COMPANY_ARTIFACTS_ROOT
                         / relay.company_module.initiative_dirname(self.init) / ".demo")
        self.demo_dir.mkdir(parents=True)
        (self.demo_dir / "01-home.png").write_bytes(b"png-bytes")
        (self.demo_dir / "02-detail.png").write_bytes(b"more-bytes")
        (self.demo_dir / "notes.txt").write_text("not an image")

    def tearDown(self):
        relay.COMPANY_STATE_PATH = self.original_state
        relay.COMPANY_ARTIFACTS_ROOT = self.original_artifacts
        self.tmp.cleanup()

    def test_lists_only_media_files_in_order(self):
        self.assertEqual(relay.demo_asset_names(self.init["id"]),
                         ["01-home.png", "02-detail.png"])

    def test_serves_bytes_with_mime(self):
        asset = relay.demo_asset(self.init["id"], "01-home.png")
        self.assertEqual(asset, (b"png-bytes", "image/png"))

    def test_rejects_traversal_and_unknown_names(self):
        self.assertIsNone(relay.demo_asset(self.init["id"], "../company.json"))
        self.assertIsNone(relay.demo_asset(self.init["id"], "/etc/passwd"))
        self.assertIsNone(relay.demo_asset(self.init["id"], "notes.txt"))
        self.assertIsNone(relay.demo_asset("nope", "01-home.png"))

    def test_unknown_initiative_lists_empty(self):
        self.assertEqual(relay.demo_asset_names("nope"), [])


class InitiativeFilesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.original_state = relay.COMPANY_STATE_PATH
        self.original_artifacts = relay.COMPANY_ARTIFACTS_ROOT
        relay.COMPANY_STATE_PATH = root / "company.json"
        relay.COMPANY_ARTIFACTS_ROOT = root / "Boardroom"
        state = relay.company_module.new_state()
        self.init = relay.company_module.new_initiative("Quake App", "p")
        state["initiatives"] = [self.init]
        relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).save(state)
        self.artifacts = (relay.COMPANY_ARTIFACTS_ROOT
                          / relay.company_module.initiative_dirname(self.init))
        (self.artifacts / "Sources").mkdir(parents=True)
        (self.artifacts / "Sources" / "Main.swift").write_text("print(1)")
        (self.artifacts / "README.md").write_text("# app")
        (self.artifacts / "icon.png").write_bytes(b"png-bytes")
        # Junk that must never show up in the manifest:
        (self.artifacts / ".git").mkdir()
        (self.artifacts / ".git" / "config").write_text("secret")
        (self.artifacts / "node_modules" / "pkg").mkdir(parents=True)
        (self.artifacts / "node_modules" / "pkg" / "index.js").write_text("x")
        (self.artifacts / ".DS_Store").write_bytes(b"junk")
        (self.artifacts / "huge.bin").write_bytes(b"\0" * (relay.FILE_MAX_BYTES + 1))
        # A file OUTSIDE the artifacts dir — the traversal target.
        (relay.COMPANY_ARTIFACTS_ROOT / "outside.txt").write_text("secret")

    def tearDown(self):
        relay.COMPANY_STATE_PATH = self.original_state
        relay.COMPANY_ARTIFACTS_ROOT = self.original_artifacts
        self.tmp.cleanup()

    def test_lists_files_recursively_sorted_with_sizes(self):
        self.assertEqual(relay.initiative_files(self.init["id"]), [
            {"path": "README.md", "size": 5},
            {"path": "Sources/Main.swift", "size": 8},
            {"path": "icon.png", "size": 9},
        ])

    def test_listing_caps_entries(self):
        original = relay.FILE_LIST_CAP
        relay.FILE_LIST_CAP = 2
        try:
            self.assertEqual(len(relay.initiative_files(self.init["id"])), 2)
        finally:
            relay.FILE_LIST_CAP = original

    def test_unknown_initiative_is_none_and_missing_dir_is_empty(self):
        self.assertIsNone(relay.initiative_files("nope"))
        empty = relay.company_module.new_initiative("Fresh", "p")
        store = relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH)
        state = store.load()
        state["initiatives"].append(empty)
        store.save(state)
        self.assertEqual(relay.initiative_files(empty["id"]), [])

    def test_serves_code_as_text_and_image_as_png(self):
        self.assertEqual(relay.initiative_file(self.init["id"], "Sources/Main.swift"),
                         (b"print(1)", "text/plain"))
        self.assertEqual(relay.initiative_file(self.init["id"], "icon.png"),
                         (b"png-bytes", "image/png"))

    def test_unknown_suffix_is_octet_stream(self):
        (self.artifacts / "blob.dat").write_bytes(b"\x01\x02")
        self.assertEqual(relay.initiative_file(self.init["id"], "blob.dat"),
                         (b"\x01\x02", "application/octet-stream"))

    def test_rejects_traversal_out_of_artifacts_dir(self):
        self.assertIsNone(relay.initiative_file(self.init["id"], "../outside.txt"))
        self.assertIsNone(relay.initiative_file(self.init["id"], "Sources/../../outside.txt"))
        self.assertIsNone(relay.initiative_file(self.init["id"], "/etc/passwd"))
        self.assertIsNone(relay.initiative_file(self.init["id"], ""))

    def test_rejects_oversized_missing_and_unknown(self):
        self.assertEqual(relay.initiative_file(self.init["id"], "huge.bin"), "too_large")
        self.assertIsNone(relay.initiative_file(self.init["id"], "nope.txt"))
        self.assertIsNone(relay.initiative_file("nope", "README.md"))


class GameArtifactTests(unittest.TestCase):
    """/games/artifact/<id>/… — the arcade cabinet's game file server
    (mirrors InitiativeFilesTests, keyed on the games studio)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.original_state = relay.GAMES_STATE_PATH
        self.original_artifacts = relay.GAMES_ARTIFACTS_ROOT
        relay.GAMES_STATE_PATH = root / "games.json"
        relay.GAMES_ARTIFACTS_ROOT = root / "games-studio"
        state = relay.games_module.new_studio_state()
        self.game = relay.games_module.seed_concept(state, "Neon Drift", "hyper-casual")
        self.game["runtime"] = "index.html"
        relay.games_module.StudioStore(relay.GAMES_STATE_PATH).save(state)
        self.artifacts = (relay.GAMES_ARTIFACTS_ROOT
                          / relay.games_module._game_dirname(self.game))
        self.artifacts.mkdir(parents=True)
        (self.artifacts / "index.html").write_text("<canvas>game</canvas>")
        (self.artifacts / "sprites.png").write_bytes(b"png-bytes")
        # A file OUTSIDE the game's dir — the traversal target.
        (root / "outside.txt").write_text("secret")

    def tearDown(self):
        relay.GAMES_STATE_PATH = self.original_state
        relay.GAMES_ARTIFACTS_ROOT = self.original_artifacts
        self.tmp.cleanup()

    def test_serves_html_as_text_html(self):
        self.assertEqual(relay.game_artifact(self.game["id"], "index.html"),
                         (b"<canvas>game</canvas>", "text/html"))
        self.assertEqual(relay.game_artifact(self.game["id"], "sprites.png"),
                         (b"png-bytes", "image/png"))

    def test_empty_relpath_serves_the_runtime_entry_file(self):
        self.assertEqual(relay.game_artifact(self.game["id"], ""),
                         (b"<canvas>game</canvas>", "text/html"))

    def test_empty_relpath_defaults_to_index_when_no_runtime(self):
        state = relay.games_module.StudioStore(relay.GAMES_STATE_PATH).load()
        state["games"][0]["runtime"] = ""
        relay.games_module.StudioStore(relay.GAMES_STATE_PATH).save(state)
        self.assertEqual(relay.game_artifact(self.game["id"], ""),
                         (b"<canvas>game</canvas>", "text/html"))

    def test_rejects_traversal_out_of_game_dir(self):
        self.assertIsNone(relay.game_artifact(self.game["id"], "../outside.txt"))
        self.assertIsNone(relay.game_artifact(self.game["id"], "a/../../outside.txt"))
        self.assertIsNone(relay.game_artifact(self.game["id"], "/etc/passwd"))

    def test_missing_game_and_missing_file_are_none(self):
        self.assertIsNone(relay.game_artifact("nope", "index.html"))
        self.assertIsNone(relay.game_artifact(self.game["id"], "nope.js"))

    def test_oversized_file_is_too_large(self):
        (self.artifacts / "huge.bin").write_bytes(b"\0" * (relay.FILE_MAX_BYTES + 1))
        self.assertEqual(relay.game_artifact(self.game["id"], "huge.bin"), "too_large")


class ObsidianGraphTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.originals = (relay.COMPANY_VAULT_ROOT, relay.OBSIDIAN_CONFIG_PATH,
                          relay.OBSIDIAN_ICLOUD_DOCS)
        relay.COMPANY_VAULT_ROOT = root / "Boardroom-Vault"
        relay.OBSIDIAN_CONFIG_PATH = root / "obsidian.json"
        relay.OBSIDIAN_ICLOUD_DOCS = root / "no-icloud"
        # Company brain: one meeting note linking an agent and an Obsidian note.
        meetings = relay.COMPANY_VAULT_ROOT / "meetings"
        meetings.mkdir(parents=True)
        (meetings / "2026-07-01-standup.md").write_text("[[ceo]] and [[Growth]]")
        # Obsidian brain ('vault'): nested note, wikilinks both ways, junk dirs.
        self.vault = root / "vault"
        (self.vault / "Ideas").mkdir(parents=True)
        (self.vault / "Ideas" / "Growth.md").write_text(
            "[[Roadmap]] [[2026-07-01-standup]] [[Nowhere]]")
        (self.vault / "Roadmap.md").write_text("plain note")
        (self.vault / ".obsidian").mkdir()
        (self.vault / ".obsidian" / "workspace.md").write_text("junk")
        (self.vault / ".trash").mkdir()
        (self.vault / ".trash" / "Old.md").write_text("deleted")
        relay.OBSIDIAN_CONFIG_PATH.write_text('{"vault_path": "%s"}' % self.vault)

    def tearDown(self):
        (relay.COMPANY_VAULT_ROOT, relay.OBSIDIAN_CONFIG_PATH,
         relay.OBSIDIAN_ICLOUD_DOCS) = self.originals
        self.tmp.cleanup()

    def test_obsidian_notes_become_namespaced_nodes(self):
        nodes = {n["id"]: n for n in relay.vault_graph()["nodes"]}
        self.assertEqual(nodes["obsidian:Ideas/Growth"],
                         {"id": "obsidian:Ideas/Growth", "label": "Growth", "type": "obsidian"})
        self.assertIn("obsidian:Roadmap", nodes)
        self.assertFalse(any(".obsidian" in nid or ".trash" in nid for nid in nodes))

    def test_cross_vault_edges_both_directions(self):
        edges = relay.vault_graph()["edges"]
        self.assertIn({"source": "2026-07-01-standup", "target": "obsidian:Ideas/Growth"}, edges)
        self.assertIn({"source": "obsidian:Ideas/Growth", "target": "2026-07-01-standup"}, edges)
        self.assertIn({"source": "obsidian:Ideas/Growth", "target": "obsidian:Roadmap"}, edges)

    def test_cap_keeps_most_recent_and_flags_truncated(self):
        original = relay.OBSIDIAN_NOTE_CAP
        relay.OBSIDIAN_NOTE_CAP = 1
        try:
            os.utime(self.vault / "Roadmap.md", (1, 1))   # oldest — dropped
            graph = relay.vault_graph()
            self.assertTrue(graph["truncated"])
            kept, _ = relay.obsidian_notes(relay.obsidian_vault_root())
            self.assertEqual([p.name for p in kept], ["Growth.md"])
            self.assertIn("obsidian:Ideas/Growth", {n["id"] for n in graph["nodes"]})
        finally:
            relay.OBSIDIAN_NOTE_CAP = original

    def test_missing_vault_degrades_to_company_only(self):
        relay.OBSIDIAN_CONFIG_PATH.write_text('{"vault_path": "/nope/nowhere"}')
        self.assertIsNone(relay.obsidian_vault_root())
        graph = relay.vault_graph()
        self.assertNotIn("truncated", graph)
        self.assertFalse(any(n["type"] == "obsidian" for n in graph["nodes"]))
        self.assertTrue(any(n["id"] == "2026-07-01-standup" for n in graph["nodes"]))

    def test_garbage_config_falls_back_without_crashing(self):
        relay.OBSIDIAN_CONFIG_PATH.write_text("not json{{{")
        self.assertIsNone(relay.obsidian_vault_root())   # iCloud default absent too

    def test_note_endpoint_serves_both_brains(self):
        company = relay.vault_note("2026-07-01-standup")
        self.assertEqual(company["source"], "company")
        self.assertEqual(company["title"], "2026-07-01-standup")
        self.assertIn("[[ceo]]", company["content"])
        self.assertIsInstance(company["modified"], int)
        obsidian = relay.vault_note("obsidian:Ideas/Growth")
        self.assertEqual(obsidian["source"], "obsidian")
        self.assertEqual(obsidian["title"], "Growth")
        self.assertIn("[[Roadmap]]", obsidian["content"])

    def test_note_rejects_traversal_and_unknown(self):
        (Path(self.tmp.name) / "outside.md").write_text("secret")
        self.assertIsNone(relay.vault_note("obsidian:../outside"))
        self.assertIsNone(relay.vault_note("obsidian:.trash/Old"))
        self.assertIsNone(relay.vault_note("obsidian:/etc/passwd"))
        self.assertIsNone(relay.vault_note("obsidian:Nowhere"))
        self.assertIsNone(relay.vault_note("no-such-company-note"))
        self.assertIsNone(relay.vault_note(""))

    def test_note_content_is_capped_with_marker(self):
        original = relay.NOTE_CONTENT_CAP
        relay.NOTE_CONTENT_CAP = 5
        try:
            note = relay.vault_note("obsidian:Roadmap")
            self.assertTrue(note["content"].startswith("plain"))
            self.assertTrue(note["content"].endswith("… (truncated)"))
        finally:
            relay.NOTE_CONTENT_CAP = original


class WarmPoolWiringTests(unittest.TestCase):
    def test_relay_warm_client_is_a_pool(self):
        self.assertIsInstance(relay.WARM_CLIENT, relay.acp_module.AcpPool)
        self.assertGreaterEqual(len(relay.WARM_CLIENT.clients), 1)
        # /health fields keep working without a single process spawned.
        self.assertFalse(relay.WARM_CLIENT.warm())
        self.assertEqual(relay.WARM_CLIENT.warm_count(), 0)


class RevenueTests(unittest.TestCase):
    def test_parse_revenuecat_metrics_maps_fields(self):
        payload = {"metrics": [
            {"object": "metric", "id": "mrr", "name": "MRR", "unit": "$", "value": 412.5},
            {"object": "metric", "id": "active_subscriptions", "name": "Active Subscriptions",
             "unit": "", "value": 61},
            "garbage",
        ]}
        metrics = relay.parse_revenuecat_metrics(payload)
        self.assertEqual(len(metrics), 2)
        self.assertEqual(metrics[0], {"id": "mrr", "name": "MRR", "value": 412.5, "unit": "$"})

    def test_parse_revenuecat_metrics_handles_garbage(self):
        self.assertEqual(relay.parse_revenuecat_metrics(None), [])
        self.assertEqual(relay.parse_revenuecat_metrics({"metrics": "no"}), [])

    def test_revenue_brief_line_formats_money(self):
        line = relay.revenue_brief_line([
            {"id": "mrr", "name": "MRR", "unit": "$", "value": 412.5},
            {"id": "subs", "name": "Active Subscriptions", "unit": "", "value": 61}])
        self.assertEqual(line, "MRR: $412.50 · Active Subscriptions: 61")

    def test_revenue_summary_unconfigured_is_honest(self):
        original = relay.REVENUE_CONFIG_PATH
        relay.REVENUE_CONFIG_PATH = Path(tempfile.mkdtemp()) / "nope.json"
        try:
            summary = relay.revenue_summary()
            self.assertFalse(summary["configured"])
            self.assertIn("revenue-keys.json", summary["note"])
        finally:
            relay.REVENUE_CONFIG_PATH = original


class VoiceTests(unittest.TestCase):
    def test_piper_names_map_to_cast_elevenlabs_voices(self):
        # CEO's Piper voice → Roger; Lena's → Sarah. The app never changes.
        self.assertEqual(relay.elevenlabs_voice_id("en_US-ryan-medium"),
                         "CwhRBWXzGAHq8TQ4Fs17")
        self.assertEqual(relay.elevenlabs_voice_id("en_GB-jenny_dioco-medium"),
                         "EXAVITQu4vr4xnSDxMaL")

    def test_unknown_voice_falls_back_to_default(self):
        self.assertEqual(relay.elevenlabs_voice_id("nonsense-voice"),
                         relay.ELEVENLABS_DEFAULT_VOICE)

    def test_raw_elevenlabs_id_passes_through(self):
        self.assertEqual(relay.elevenlabs_voice_id("pFZP5JQG7iQjIQuC4Bku"),
                         "pFZP5JQG7iQjIQuC4Bku")

    def test_owner_voice_map_override_wins(self):
        config = {"voice_map": {"en_US-ryan-medium": "customVoice123456"}}
        self.assertEqual(relay.elevenlabs_voice_id("en_US-ryan-medium", config),
                         "customVoice123456")

    def test_synthesize_elevenlabs_none_without_config(self):
        original = relay.ELEVENLABS_CONFIG_PATH
        relay.ELEVENLABS_CONFIG_PATH = Path(tempfile.mkdtemp()) / "nope.json"
        try:
            self.assertIsNone(relay.synthesize_elevenlabs("hello", "en_US-ryan-medium"))
        finally:
            relay.ELEVENLABS_CONFIG_PATH = original


class VoiceCostPolicyTests(unittest.TestCase):
    """ElevenLabs is NEVER the default: internal voice is free, premium is
    budget-capped, over-budget falls back to the free engine."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.orig_config = relay.ELEVENLABS_CONFIG_PATH
        self.orig_usage = relay.ELEVENLABS_USAGE_PATH
        self.orig_el = relay.synthesize_elevenlabs
        relay.ELEVENLABS_CONFIG_PATH = root / "elevenlabs.json"
        relay.ELEVENLABS_USAGE_PATH = root / "usage.json"
        relay.ELEVENLABS_CONFIG_PATH.write_text(
            '{"api_key": "k", "daily_char_budget": 20, "weekly_char_budget": 100}')
        self.el_calls = []
        relay.synthesize_elevenlabs = lambda text, voice: (
            self.el_calls.append(text) or b"mp3-bytes")

    def tearDown(self):
        relay.ELEVENLABS_CONFIG_PATH = self.orig_config
        relay.ELEVENLABS_USAGE_PATH = self.orig_usage
        relay.synthesize_elevenlabs = self.orig_el
        self.tmp.cleanup()

    def test_internal_tier_never_touches_elevenlabs(self):
        relay.synthesize_speech("hello team", "en_US-ryan-medium", "internal")
        relay.synthesize_speech("hello team", "en_US-ryan-medium")   # default
        self.assertEqual(self.el_calls, [])

    def test_premium_tier_uses_elevenlabs_and_charges_budget(self):
        speech = relay.synthesize_speech("pitch", "en_US-ryan-medium", "premium")
        self.assertEqual(speech, (b"mp3-bytes", "audio/mpeg", "elevenlabs"))
        self.assertEqual(relay.load_voice_usage()["chars_today"], 5)

    def test_premium_over_budget_falls_back_to_free(self):
        relay.charge_voice_usage(18)                    # 18 of 20 daily spent
        relay.synthesize_speech("long sales pitch", "en_US-ryan-medium", "premium")
        self.assertEqual(self.el_calls, [])             # EL never called
        self.assertEqual(relay.load_voice_usage()["chars_today"], 18)  # no charge

    def test_budget_rolls_over_by_day(self):
        import time as time_module
        monday = time_module.mktime((2026, 6, 29, 12, 0, 0, 0, 0, -1))
        tuesday = time_module.mktime((2026, 6, 30, 12, 0, 0, 0, 0, -1))
        relay.charge_voice_usage(15, now=monday)
        usage = relay.load_voice_usage(now=tuesday)
        self.assertEqual(usage["chars_today"], 0)       # new day
        self.assertEqual(usage["chars_week"], 15)       # same ISO week


class CompanyBrainTests(unittest.TestCase):
    def test_ensure_constitution_seeds_when_absent(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            relay.ensure_constitution(root)
            con = root / "Company.md"
            self.assertTrue(con.exists())
            self.assertIn("Constitution", con.read_text())

    def test_ensure_constitution_never_overwrites(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("MY EDITS")
            relay.ensure_constitution(root)
            self.assertEqual((root / "Company.md").read_text(), "MY EDITS")
    def test_memory_block_empty_when_vault_missing(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(relay.build_memory_block(Path(d) / "nope"), "")

    def test_memory_block_includes_constitution_and_decisions(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("# Constitution\nThesis: win.")
            (root / "decisions").mkdir()
            (root / "decisions" / "Decision Log.md").write_text(
                "# Decision Log\n\n## Ship widget — 2026-07-01\n- Approved widget\n")
            block = relay.build_memory_block(root)
            self.assertIn("Thesis: win.", block)
            self.assertIn("Approved widget", block)
            self.assertIn("Company memory", block)

    def test_memory_block_respects_cap(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("x" * 5000)
            block = relay.build_memory_block(root)
            self.assertLessEqual(len(block), relay.MEMORY_BLOCK_CAP)
    def test_compose_injects_for_deliberative_role(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("# Constitution\nThesis: win.")
            out = relay.compose_company_prompt("ceo", "Decide X.", root)
            self.assertIn("Thesis: win.", out)
            self.assertTrue(out.endswith("Decide X."))

    def test_compose_skips_scout_and_lena(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("# Constitution\nThesis: win.")
            self.assertEqual(relay.compose_company_prompt("research", "JSON please", root), "JSON please")
            self.assertEqual(relay.compose_company_prompt("lena", "summarize", root), "summarize")

    def test_compose_passthrough_when_no_vault(self):
        with tempfile.TemporaryDirectory() as d:
            out = relay.compose_company_prompt("ceo", "Decide X.", Path(d) / "nope")
            self.assertEqual(out, "Decide X.")
    def test_company_cli_runner_injects_memory_for_deliberative_role(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("# Constitution\nThesis: win.")
            captured = {}

            def fake_company_chat_command(prompt, role, resume):
                captured["prompt"] = prompt
                return ["true"]

            fake_result = subprocess.CompletedProcess(
                ["true"], 0,
                "ok\n\nResume this session with:\n  hermes --resume 20260703_120000_test\n", "")
            with mock.patch.object(relay, "COMPANY_VAULT_ROOT", root), \
                 mock.patch.object(relay, "company_chat_command", fake_company_chat_command), \
                 mock.patch.object(relay, "run_killable", return_value=fake_result), \
                 mock.patch.object(relay.RelayConfigStore, "session_id", return_value=None), \
                 mock.patch.object(relay.RelayConfigStore, "save_session", return_value=None):
                relay.company_cli_runner("ceo", "Decide X.")

            self.assertIn("Thesis: win.", captured["prompt"])
            self.assertIn("Decide X.", captured["prompt"])
    # ---- Phase 2: constitution in interactive app-chat (2c) ----
    def test_memory_block_constitution_only_omits_decisions(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("# Constitution\nThesis: win.")
            (root / "decisions").mkdir()
            (root / "decisions" / "Decision Log.md").write_text(
                "# Decision Log\n\n## D — 2026\n- did thing\n")
            block = relay.build_memory_block(root, include_decisions=False)
            self.assertIn("Thesis: win.", block)
            self.assertNotIn("did thing", block)

    def test_chat_injects_constitution_for_company_session(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("# Constitution\nThesis: win.")
            out = relay.compose_chat_message("company-ceo-chat", "hi", False, root)
            self.assertIn("Thesis: win.", out)
            self.assertTrue(out.endswith("hi"))

    def test_chat_skips_fast_and_noncompany(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("# Constitution\nThesis: win.")
            self.assertEqual(relay.compose_chat_message("company-ceo-chat", "hi", True, root), "hi")
            self.assertEqual(relay.compose_chat_message("hermes-mobile-briefing", "hi", False, root), "hi")

    def test_chat_passthrough_when_no_vault(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(
                relay.compose_chat_message("company-ceo-chat", "hi", False, Path(d) / "nope"), "hi")

    # ---- Phase 2: proactive daily briefing push (2a) ----
    def test_briefing_digest_from_real_state(self):
        state = {"initiatives": [{"stage": "gate1"}, {"stage": "execution"}, {"stage": "shipped"}],
                 "meetings": [{"topic": "Kickoff"}]}
        digest = relay.build_briefing_digest(state)
        self.assertIn("2 initiatives active", digest)
        self.assertIn("1 gate awaiting you", digest)
        self.assertIn("last: Kickoff", digest)

    def test_briefing_digest_quiet_when_empty(self):
        self.assertEqual(relay.build_briefing_digest({}), "Quiet — nothing needs you right now.")

    def test_briefing_due_once_per_morning(self):
        import time as t
        now9 = t.mktime((2026, 7, 3, 9, 0, 0, 0, 0, -1))
        today = t.strftime("%Y-%m-%d", t.localtime(now9))
        self.assertTrue(relay.briefing_due({"briefing_hour": 8}, now9, ""))
        self.assertFalse(relay.briefing_due({"briefing_hour": 8}, now9, today))
        now6 = t.mktime((2026, 7, 3, 6, 0, 0, 0, 0, -1))
        self.assertFalse(relay.briefing_due({"briefing_hour": 8}, now6, ""))
        self.assertFalse(relay.briefing_due({"briefing_push_enabled": False}, now9, ""))

    def test_maybe_push_briefing_sends_once(self):
        import time as t
        relay._BRIEFING_PUSH["date"] = ""
        now9 = t.mktime((2026, 7, 3, 9, 0, 0, 0, 0, -1))
        state = {"config": {"briefing_hour": 8},
                 "initiatives": [{"stage": "gate1"}], "meetings": [{"topic": "Kickoff"}]}
        sent = []
        with mock.patch.object(relay, "send_push", lambda *a, **k: (sent.append(a), 1)[1]):
            first = relay.maybe_push_briefing(state, now=now9)
            second = relay.maybe_push_briefing(state, now=now9)
        self.assertTrue(first)
        self.assertFalse(second)
        self.assertEqual(len(sent), 1)
        self.assertIn("gate", sent[0][1])


class CallQueueTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.originals = (relay.CALLS_STATE_PATH, relay.CONFIG_PATH, relay.APNS_CONFIG_PATH)
        relay.CALLS_STATE_PATH = root / "mobile-calls.json"
        relay.CONFIG_PATH = root / "mobile-relay.json"
        relay.APNS_CONFIG_PATH = root / "apns.json"   # unconfigured → honest no-op push

    def tearDown(self):
        (relay.CALLS_STATE_PATH, relay.CONFIG_PATH, relay.APNS_CONFIG_PATH) = self.originals
        self.tmp.cleanup()

    def test_create_then_pending_returns_newest_ringing(self):
        first = relay.create_call("Lena", "gate one")
        second = relay.create_call("CEO", "gate two")
        self.assertEqual(first["status"], "ringing")
        pending = relay.pending_call()
        self.assertEqual(pending["id"], second["id"])
        self.assertEqual((pending["caller"], pending["reason"]), ("CEO", "gate two"))
        self.assertTrue(relay.CALLS_STATE_PATH.exists())   # persisted, survives restarts

    def test_ack_answers_and_declines(self):
        call = relay.create_call("Lena", "pick up")
        answered = relay.ack_call(call["id"], "answered")
        self.assertEqual(answered["status"], "answered")
        self.assertEqual(relay.pending_call(), {})         # no longer ringing
        declined = relay.create_call("Lena", "again")
        self.assertEqual(relay.ack_call(declined["id"], "declined")["status"], "declined")
        self.assertIsNone(relay.ack_call("nope", "answered"))

    def test_ringing_calls_expire_after_120s(self):
        call = relay.create_call("Lena", "stale")
        data = relay._load_calls()
        data["calls"][0]["created"] = time.time() - relay.CALL_TTL_SECONDS - 1
        relay._save_calls(data)
        self.assertEqual(relay.pending_call(), {})
        stored = relay._load_calls()["calls"][0]
        self.assertEqual((stored["id"], stored["status"]), (call["id"], "expired"))

    def test_auto_call_is_rate_limited_and_persisted(self):
        self.assertTrue(relay.maybe_auto_call("Trend Radar"))
        self.assertFalse(relay.maybe_auto_call("Focus Timer"))   # within 30 min
        data = relay._load_calls()
        self.assertEqual(len(data["calls"]), 1)
        self.assertEqual(data["calls"][0]["caller"], "Lena")
        self.assertIn("Trend Radar", data["calls"][0]["reason"])
        self.assertIn("decision", data["calls"][0]["reason"])
        self.assertGreater(data["last_auto_call"], 0)            # cooldown survives restarts

    def test_auto_call_fires_again_after_cooldown(self):
        relay.maybe_auto_call("First")
        data = relay._load_calls()
        data["last_auto_call"] = time.time() - relay.AUTO_CALL_COOLDOWN - 1
        relay._save_calls(data)
        self.assertTrue(relay.maybe_auto_call("Second"))

    def test_voip_push_is_honest_noop_when_unconfigured(self):
        self.assertEqual(relay.send_voip_push({"id": "x"}), 0)   # no apns.json
        relay.APNS_CONFIG_PATH.write_text(json.dumps(
            {"key_path": "/nope.p8", "key_id": "K", "team_id": "T",
             "bundle_id": "com.example.app"}))                   # no voip_topic
        self.assertEqual(relay.send_voip_push({"id": "x"}), 0)
        relay.APNS_CONFIG_PATH.write_text(json.dumps(
            {"key_path": "/nope.p8", "key_id": "K", "team_id": "T",
             "bundle_id": "com.example.app", "voip_topic": "com.example.app.voip"}))
        self.assertEqual(relay.send_voip_push({"id": "x"}), 0)   # no voip tokens yet

    def test_voip_tokens_live_apart_from_alert_tokens(self):
        relay.register_push_token("aa" * 16)
        relay.register_voip_push_token("bb" * 16)
        relay.register_voip_push_token("cc" * 16)
        relay.register_voip_push_token("bb" * 16)                # dedupes, moves last
        self.assertEqual(relay.push_tokens(), ["aa" * 16])
        self.assertEqual(relay.voip_push_tokens(), ["cc" * 16, "bb" * 16])
        relay.drop_voip_push_token("cc" * 16)
        self.assertEqual(relay.voip_push_tokens(), ["bb" * 16])
        self.assertEqual(relay.push_tokens(), ["aa" * 16])       # untouched

    def test_corrupt_calls_file_resets_clean(self):
        relay.CALLS_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        relay.CALLS_STATE_PATH.write_text("not json{{{")
        self.assertEqual(relay.pending_call(), {})
        self.assertEqual(relay.create_call("Lena", "r")["status"], "ringing")


class VaultCaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.originals = (relay.COMPANY_VAULT_ROOT, relay.OBSIDIAN_CONFIG_PATH,
                          relay.OBSIDIAN_ICLOUD_DOCS)
        relay.COMPANY_VAULT_ROOT = root / "Boardroom-Vault"
        relay.OBSIDIAN_CONFIG_PATH = root / "obsidian.json"
        relay.OBSIDIAN_ICLOUD_DOCS = root / "no-icloud"
        self.vault = root / "vault"
        self.vault.mkdir()
        relay.OBSIDIAN_CONFIG_PATH.write_text(json.dumps({"vault_path": str(self.vault)}))

    def tearDown(self):
        (relay.COMPANY_VAULT_ROOT, relay.OBSIDIAN_CONFIG_PATH,
         relay.OBSIDIAN_ICLOUD_DOCS) = self.originals
        self.tmp.cleanup()

    def test_capture_lands_in_obsidian_inbox_as_graph_node(self):
        result = relay.capture_brain_dump("Ship the widget first.", "Big Idea")
        self.assertTrue(result["ok"])
        path = Path(result["path"])
        self.assertEqual(path.parent, self.vault / "Inbox")
        content = path.read_text()
        self.assertIn("# Big Idea", content)
        self.assertIn("Ship the widget first.", content)
        self.assertIn("#brain-dump", content)
        self.assertTrue(result["id"].startswith("obsidian:Inbox/"))
        self.assertIn("big-idea", result["id"])
        note = relay.vault_note(result["id"])          # the graph can serve it back
        self.assertIn("Ship the widget first.", note["content"])

    def test_capture_falls_back_to_company_vault(self):
        relay.OBSIDIAN_CONFIG_PATH.write_text(json.dumps({"vault_path": "/nope/nowhere"}))
        result = relay.capture_brain_dump("fallback thought")
        path = Path(result["path"])
        self.assertEqual(path.parent, relay.COMPANY_VAULT_ROOT / "Inbox")
        self.assertNotIn("obsidian:", result["id"])
        self.assertIn("fallback thought", relay.vault_note(result["id"])["content"])

    def test_capture_filename_is_traversal_safe(self):
        result = relay.capture_brain_dump("evil", "../../../../etc/passwd")
        path = Path(result["path"]).resolve()
        self.assertEqual(path.parent, (self.vault / "Inbox").resolve())
        self.assertNotIn("..", path.name)

    def test_capture_caps_text_at_64kb(self):
        result = relay.capture_brain_dump("x" * (relay.BRAIN_DUMP_CAP + 5000))
        size = Path(result["path"]).stat().st_size
        self.assertLessEqual(size, relay.BRAIN_DUMP_CAP + 64)   # + tag line

    def test_same_minute_same_title_keeps_both_notes(self):
        first = relay.capture_brain_dump("one", "Same Title")
        second = relay.capture_brain_dump("two", "Same Title")
        self.assertNotEqual(first["path"], second["path"])
        self.assertTrue(Path(first["path"]).exists())
        self.assertTrue(Path(second["path"]).exists())


class BoardPacketTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.originals = (relay.COMPANY_STATE_PATH, relay.COMPANY_VAULT_ROOT,
                          relay.CONFIG_PATH, relay.APNS_CONFIG_PATH)
        relay.COMPANY_STATE_PATH = root / "company.json"
        relay.COMPANY_VAULT_ROOT = root / "Boardroom-Vault"
        relay.CONFIG_PATH = root / "mobile-relay.json"
        relay.APNS_CONFIG_PATH = root / "apns.json"

    def tearDown(self):
        (relay.COMPANY_STATE_PATH, relay.COMPANY_VAULT_ROOT,
         relay.CONFIG_PATH, relay.APNS_CONFIG_PATH) = self.originals
        self.tmp.cleanup()

    def test_seed_board_packet_schedule_is_idempotent(self):
        relay.seed_board_packet_schedule()
        relay.seed_board_packet_schedule()
        state = relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).load()
        packets = [s for s in state["schedules"] if s["kind"] == "board_packet"]
        self.assertEqual(len(packets), 1)
        sched = packets[0]
        self.assertEqual((sched["cadence"], sched["weekday"], sched["at_hour"], sched["at_minute"]),
                         ("weekly", 6, 18, 0))       # Sunday 18:00
        self.assertTrue(sched["enabled"])

    def test_run_board_packet_files_note_logs_event_and_pushes(self):
        store = relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH)
        state = relay.company_module.new_state()
        shipped = relay.company_module.new_initiative("Quake App", "p")
        shipped["stage"] = "shipped"
        state["initiatives"] = [shipped]
        state["revenue_brief"] = "MRR: $412.00"
        store.save(state)
        seen = {}
        pushed = []
        def runner(role, prompt):
            seen["role"], seen["prompt"] = role, prompt
            return "## Shipped\nQuake App\n## Revenue\nMRR $412"
        with mock.patch.object(relay, "company_cli_runner", runner), \
                mock.patch.object(relay, "send_push",
                                  lambda title, body, *a, **k: pushed.append((title, body)) or 1):
            relay.run_board_packet()
        self.assertEqual(seen["role"], "cfo")
        self.assertIn("Quake App", seen["prompt"])
        self.assertIn("MRR: $412.00", seen["prompt"])
        date = time.strftime("%Y-%m-%d")
        note = relay.COMPANY_VAULT_ROOT / "Board Packets" / f"{date}-board-packet.md"
        self.assertIn("## Shipped", note.read_text())
        events = store.load()["events"]
        self.assertTrue(any("board packet" in e["text"] for e in events))
        self.assertEqual(len(pushed), 1)
        self.assertIn("board report is ready", pushed[0][1])

    def test_failed_packet_writes_nothing_and_stays_quiet(self):
        relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).save(
            relay.company_module.new_state())
        pushed = []
        def boom(role, prompt):
            raise RuntimeError("cfo turn timed out")
        with mock.patch.object(relay, "company_cli_runner", boom), \
                mock.patch.object(relay, "send_push",
                                  lambda *a, **k: pushed.append(a) or 1):
            relay.run_board_packet()                 # must not raise
        self.assertFalse((relay.COMPANY_VAULT_ROOT / "Board Packets").exists())
        self.assertEqual(pushed, [])                 # no fake "ready" push

    def test_due_board_packet_schedule_fires_from_run_schedules(self):
        store = relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH)
        state = relay.company_module.new_state()
        state["enabled"] = True
        sched = relay.company_module.new_schedule(
            "Weekly board packet", "board_packet", "", "weekly",
            at_hour=18, at_minute=0, weekday=6)
        sched["last_fired"] = time.time() - 8 * 86400   # a week+ ago → due
        state["schedules"] = [sched]
        store.save(state)
        fired = threading.Event()
        with mock.patch.object(relay, "run_board_packet", fired.set):
            relay.run_schedules()
            self.assertTrue(fired.wait(timeout=5))
        reloaded = store.load()["schedules"][0]
        self.assertGreater(reloaded["last_fired"], time.time() - 60)   # marked fired


class InstallDayTests(unittest.TestCase):
    BASE = "https://andrews-mac.tail4cd83c.ts.net:8443"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.originals = (relay.INSTALL_DAY_CONFIG_PATH, relay.INSTALLS_STATE_PATH,
                          relay.COMPANY_STATE_PATH, relay.COMPANY_ARTIFACTS_ROOT)
        relay.INSTALL_DAY_CONFIG_PATH = root / "install-day.json"
        relay.INSTALLS_STATE_PATH = root / "mobile-installs.json"
        relay.COMPANY_STATE_PATH = root / "company.json"
        relay.COMPANY_ARTIFACTS_ROOT = root / "Boardroom"
        relay._TAILNET_CACHE.update(base=None, checked=0.0)
        state = relay.company_module.new_state()
        self.init = relay.company_module.new_initiative("Quake App", "p")
        state["initiatives"] = [self.init]
        relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).save(state)
        self.artifacts = (relay.COMPANY_ARTIFACTS_ROOT
                          / relay.company_module.initiative_dirname(self.init))
        (self.artifacts / "QuakeApp.xcodeproj").mkdir(parents=True)

    def tearDown(self):
        (relay.INSTALL_DAY_CONFIG_PATH, relay.INSTALLS_STATE_PATH,
         relay.COMPANY_STATE_PATH, relay.COMPANY_ARTIFACTS_ROOT) = self.originals
        relay._TAILNET_CACHE.update(base=None, checked=0.0)
        self.tmp.cleanup()

    def configure(self):
        relay.INSTALL_DAY_CONFIG_PATH.write_text('{"team_id": "TEAM123XYZ"}')

    def seed_ready(self, token="tok_abc123", ipa_bytes=b"ipa-bytes"):
        ipa = self.artifacts / ".install" / "export" / "QuakeApp.ipa"
        ipa.parent.mkdir(parents=True, exist_ok=True)
        ipa.write_bytes(ipa_bytes)
        relay.set_install_entry(self.init["id"], status="ready", note="",
                                token=token, ipa_path=str(ipa),
                                bundle_id="com.jamie.quake", version="1.2",
                                title="Quake App")
        return token

    def test_manifest_xml_shape_via_plutil(self):
        entry = {"bundle_id": "com.jamie.quake", "version": "1.2", "title": "Quake & Friends"}
        xml = relay.install_manifest(entry, f"{self.BASE}/install/t/app.ipa")
        manifest_path = Path(self.tmp.name) / "manifest.plist"
        manifest_path.write_bytes(xml)
        converted = subprocess.run(
            ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(manifest_path)],
            capture_output=True, text=True, check=False)
        self.assertEqual(converted.returncode, 0, converted.stderr)   # valid plist XML
        item = json.loads(converted.stdout)["items"][0]
        self.assertEqual(item["assets"][0],
                         {"kind": "software-package", "url": f"{self.BASE}/install/t/app.ipa"})
        self.assertEqual(item["metadata"],
                         {"bundle-identifier": "com.jamie.quake", "bundle-version": "1.2",
                          "kind": "software", "title": "Quake & Friends"})   # & escaped, round-trips

    def test_status_degrades_without_team_config(self):
        status = relay.install_status(self.init["id"])
        self.assertFalse(status["available"])
        self.assertIn("install-day.json", status["note"])

    def test_status_degrades_without_tailnet_https(self):
        self.configure()
        with mock.patch.object(relay, "tailnet_https_base", lambda force=False: None):
            status = relay.install_status(self.init["id"])
        self.assertFalse(status["available"])
        self.assertIn("Tailscale HTTPS", status["note"])

    def test_status_ready_mints_itms_url(self):
        self.configure()
        token = self.seed_ready()
        with mock.patch.object(relay, "tailnet_https_base", lambda force=False: self.BASE):
            status = relay.install_status(self.init["id"])
        self.assertTrue(status["available"])
        self.assertEqual(status["status"], "ready")
        self.assertEqual(status["install_url"],
                         "itms-services://?action=download-manifest&url="
                         f"{self.BASE}/install/{token}/manifest.plist")

    def test_install_asset_serves_by_capability_token_only(self):
        token = self.seed_ready()
        with mock.patch.object(relay, "tailnet_https_base", lambda force=False: self.BASE):
            manifest = relay.install_asset(token, "manifest.plist")
            ipa = relay.install_asset(token, "app.ipa")
            self.assertIsNone(relay.install_asset("wrong-token", "manifest.plist"))
            self.assertIsNone(relay.install_asset(token, "../company.json"))
            self.assertIsNone(relay.install_asset("", "manifest.plist"))
        self.assertEqual(manifest[1], "text/xml; charset=utf-8")
        self.assertIn(b"com.jamie.quake", manifest[0])
        self.assertIn(f"{self.BASE}/install/{token}/app.ipa".encode(), manifest[0])
        self.assertEqual(ipa, (b"ipa-bytes", "application/octet-stream"))

    def test_export_lifecycle_with_mocked_xcodebuild(self):
        self.configure()

        def fake_run_killable(command, timeout):
            if "-list" in command:
                return subprocess.CompletedProcess(
                    command, 0, json.dumps({"project": {"schemes": ["QuakeApp"]}}), "")
            if "archive" in command:
                self.assertIn("DEVELOPMENT_TEAM=TEAM123XYZ", command)
                self.assertIn("generic/platform=iOS", command)
                app = (Path(command[command.index("-archivePath") + 1])
                       / "Products" / "Applications" / "QuakeApp.app")
                app.mkdir(parents=True)
                (app / "Info.plist").write_text(
                    relay._PLIST_HEADER + '<plist version="1.0"><dict>'
                    "<key>CFBundleIdentifier</key><string>com.jamie.quake</string>"
                    "<key>CFBundleShortVersionString</key><string>1.2</string>"
                    "</dict></plist>")
                return subprocess.CompletedProcess(command, 0, "", "")
            if "-exportArchive" in command:
                options = Path(command[command.index("-exportOptionsPlist") + 1]).read_text()
                self.assertIn("<string>ad-hoc</string>", options)
                self.assertIn("<string>TEAM123XYZ</string>", options)
                export_dir = Path(command[command.index("-exportPath") + 1])
                export_dir.mkdir(parents=True, exist_ok=True)
                (export_dir / "QuakeApp.ipa").write_bytes(b"real-ipa")
                return subprocess.CompletedProcess(command, 0, "", "")
            raise AssertionError(f"unexpected xcodebuild call: {command}")

        self.assertTrue(relay.begin_export(self.init["id"]))
        self.assertFalse(relay.begin_export(self.init["id"]))   # guarded while exporting
        with mock.patch.object(relay, "run_killable", fake_run_killable):
            relay._export_ipa(self.init["id"])
        entry = relay._load_installs()[self.init["id"]]
        self.assertEqual(entry["status"], "ready")
        self.assertEqual(entry["bundle_id"], "com.jamie.quake")
        self.assertEqual(entry["version"], "1.2")
        self.assertEqual(entry["title"], "Quake App")            # from the initiative
        self.assertGreaterEqual(len(entry["token"]), 16)
        self.assertEqual(Path(entry["ipa_path"]).read_bytes(), b"real-ipa")
        self.assertTrue(relay.begin_export(self.init["id"]))     # re-export allowed once done

    def test_failed_archive_records_real_reason(self):
        self.configure()

        def fake_run_killable(command, timeout):
            if "-list" in command:
                return subprocess.CompletedProcess(
                    command, 0, json.dumps({"project": {"schemes": ["QuakeApp"]}}), "")
            return subprocess.CompletedProcess(command, 65, "", "error: no signing certificate")

        with mock.patch.object(relay, "run_killable", fake_run_killable):
            relay._export_ipa(self.init["id"])
        entry = relay._load_installs()[self.init["id"]]
        self.assertEqual(entry["status"], "failed")
        self.assertIn("no signing certificate", entry["note"])

    def test_export_without_xcode_container_fails_honestly(self):
        self.configure()
        (self.artifacts / "QuakeApp.xcodeproj").rmdir()
        relay._export_ipa(self.init["id"])
        entry = relay._load_installs()[self.init["id"]]
        self.assertEqual(entry["status"], "failed")
        self.assertIn(".xcodeproj", entry["note"])

    def test_export_crash_lands_in_status_not_silence(self):
        self.configure()
        entry = {}
        with mock.patch.object(relay, "run_killable",
                               mock.Mock(side_effect=OSError("disk full"))):
            relay.export_ipa_in_background(self.init["id"])
            for _ in range(50):                       # background thread, tiny poll
                entry = relay._load_installs().get(self.init["id"]) or {}
                if entry.get("status") == "failed":
                    break
                time.sleep(0.1)
        self.assertEqual(entry["status"], "failed")
        self.assertIn("disk full", entry["note"])

    def test_tailnet_base_requires_dns_certs_and_serve(self):
        def fake_run(command, **kwargs):
            if "--json" in command:
                return subprocess.CompletedProcess(command, 0, self.ts_status, "")
            return subprocess.CompletedProcess(command, 0, self.ts_serve, "")

        with mock.patch.object(relay.subprocess, "run", fake_run):
            self.ts_status = json.dumps({"Self": {"DNSName": "mac.tail4cd83c.ts.net."},
                                         "CertDomains": ["mac.tail4cd83c.ts.net"]})
            self.ts_serve = "https://mac.tail4cd83c.ts.net:8443 -> http://127.0.0.1:8787"
            self.assertEqual(relay.tailnet_https_base(force=True),
                             "https://mac.tail4cd83c.ts.net:8443")
            self.ts_serve = "No serve config"                     # serve not fronting
            self.assertIsNone(relay.tailnet_https_base(force=True))
            self.ts_serve = "https://mac.tail4cd83c.ts.net:8443 -> http://127.0.0.1:8787"
            self.ts_status = json.dumps({"Self": {"DNSName": "mac.tail4cd83c.ts.net."},
                                         "CertDomains": None})    # certs not enabled
            self.assertIsNone(relay.tailnet_https_base(force=True))


class EndpointAuthTests(unittest.TestCase):
    """The new endpoints over real HTTP: bearer auth enforced, JSON shapes served."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        cls.originals = (relay.CALLS_STATE_PATH, relay.CONFIG_PATH, relay.APNS_CONFIG_PATH,
                         relay.COMPANY_VAULT_ROOT, relay.OBSIDIAN_CONFIG_PATH,
                         relay.OBSIDIAN_ICLOUD_DOCS, relay.asc_module.ASC_CONFIG_PATH,
                         relay.INSTALL_DAY_CONFIG_PATH, relay.INSTALLS_STATE_PATH,
                         relay.GAMES_STATE_PATH, relay.GAMES_ARTIFACTS_ROOT,
                         relay.COMPANY_STATE_PATH,
                         relay.RelayHandler.token)
        relay.CALLS_STATE_PATH = root / "mobile-calls.json"
        relay.CONFIG_PATH = root / "mobile-relay.json"
        relay.APNS_CONFIG_PATH = root / "apns.json"
        relay.COMPANY_VAULT_ROOT = root / "Boardroom-Vault"
        relay.OBSIDIAN_CONFIG_PATH = root / "obsidian.json"
        relay.OBSIDIAN_ICLOUD_DOCS = root / "no-icloud"
        relay.asc_module.ASC_CONFIG_PATH = root / "asc.json"
        relay.INSTALL_DAY_CONFIG_PATH = root / "install-day.json"
        relay.INSTALLS_STATE_PATH = root / "mobile-installs.json"
        relay.GAMES_STATE_PATH = root / "games.json"
        relay.GAMES_ARTIFACTS_ROOT = root / "games-studio"
        relay.COMPANY_STATE_PATH = root / "company.json"
        relay.RelayHandler.token = "test-token"
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), relay.RelayHandler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        (relay.CALLS_STATE_PATH, relay.CONFIG_PATH, relay.APNS_CONFIG_PATH,
         relay.COMPANY_VAULT_ROOT, relay.OBSIDIAN_CONFIG_PATH,
         relay.OBSIDIAN_ICLOUD_DOCS, relay.asc_module.ASC_CONFIG_PATH,
         relay.INSTALL_DAY_CONFIG_PATH, relay.INSTALLS_STATE_PATH,
         relay.GAMES_STATE_PATH, relay.GAMES_ARTIFACTS_ROOT,
         relay.COMPANY_STATE_PATH,
         relay.RelayHandler.token) = cls.originals
        cls.tmp.cleanup()

    def request(self, method, path, body=None, token="test-token"):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}", method=method,
            data=json.dumps(body).encode() if body is not None else None)
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read().decode())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read().decode())

    def test_every_new_endpoint_rejects_missing_token(self):
        for method, path in (("GET", "/call/pending"), ("GET", "/asc/summary"),
                             ("GET", "/company/initiative/x/install"),
                             ("GET", "/company/divisions"),
                             ("POST", "/call/request"), ("POST", "/call/ack"),
                             ("POST", "/push/register-voip"), ("POST", "/vault/capture"),
                             ("POST", "/company/initiative/x/export-ipa"),
                             ("POST", "/games/resume")):
            status, payload = self.request(method, path, body={} if method == "POST" else None,
                                           token=None)
            self.assertEqual((path, status), (path, 401))
            self.assertEqual(payload["error"], "unauthorized")

    def test_call_lifecycle_over_http(self):
        status, call = self.request("POST", "/call/request",
                                    {"caller": "Lena", "reason": "gate decision"})
        self.assertEqual(status, 200)
        self.assertEqual((call["caller"], call["status"]), ("Lena", "ringing"))
        status, pending = self.request("GET", "/call/pending")
        self.assertEqual(pending["id"], call["id"])
        status, acked = self.request("POST", "/call/ack",
                                     {"id": call["id"], "status": "answered"})
        self.assertEqual((status, acked["status"]), (200, "answered"))
        status, pending = self.request("GET", "/call/pending")
        self.assertEqual((status, pending), (200, {}))

    def test_call_ack_validates_status_and_id(self):
        status, payload = self.request("POST", "/call/ack", {"id": "x", "status": "maybe"})
        self.assertEqual(status, 400)
        status, payload = self.request("POST", "/call/ack", {"id": "nope", "status": "declined"})
        self.assertEqual((status, payload["error"]), (404, "call_not_found"))

    def test_register_voip_validates_token_format(self):
        status, payload = self.request("POST", "/push/register-voip", {"token": "not hex!"})
        self.assertEqual(status, 400)
        status, payload = self.request("POST", "/push/register-voip", {"token": "AB" * 16})
        self.assertEqual((status, payload["ok"]), (200, True))
        self.assertFalse(payload["voip"])            # honest: no voip_topic configured
        self.assertEqual(relay.voip_push_tokens(), ["ab" * 16])

    def test_asc_summary_unconfigured_is_honest(self):
        status, payload = self.request("GET", "/asc/summary")
        self.assertEqual(status, 200)
        self.assertFalse(payload["configured"])
        self.assertEqual(payload["apps"], [])

    def test_vault_capture_over_http(self):
        status, payload = self.request("POST", "/vault/capture",
                                       {"text": "note to self", "title": "Idea"})
        self.assertEqual((status, payload["ok"]), (200, True))
        self.assertIn("note to self", Path(payload["path"]).read_text())
        status, payload = self.request("POST", "/vault/capture", {"text": "   "})
        self.assertEqual((status, payload["error"]), (400, "text_required"))

    def test_company_divisions_shape_counts_and_stable_order(self):
        state = relay.company_module.new_state()
        building = relay.company_module.new_initiative("Tip Calc", "")
        building["division"] = "webapps"
        building["stage"] = "execution"
        live = relay.company_module.new_initiative("Live Site", "")
        live["division"] = "webapps"
        live["stage"] = "shipped"
        live["live_url"] = "https://tip.vercel.app"
        dead = relay.company_module.new_initiative("Dead Legal", "")
        dead["division"] = "legal"
        dead["stage"] = "killed"
        untagged = relay.company_module.new_initiative("Generic", "")
        state["initiatives"] = [building, live, dead, untagged]
        relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).save(state)

        status, payload = self.request("GET", "/company/divisions")
        self.assertEqual(status, 200)
        divisions = payload["divisions"]
        self.assertEqual([d["id"] for d in divisions],
                         ["webapps", "saas", "ecommerce", "automations",
                          "consulting", "accounting", "legal", "growth"])   # full floor, stable
        by_id = {d["id"]: d for d in divisions}
        self.assertEqual((by_id["webapps"]["name"], by_id["webapps"]["active"],
                          by_id["webapps"]["shipped"]), ("Webapps", 1, 1))
        self.assertEqual(by_id["webapps"]["live_urls"], ["https://tip.vercel.app"])
        self.assertEqual((by_id["legal"]["active"], by_id["legal"]["shipped"],
                          by_id["legal"]["live_urls"]), (0, 0, []))   # zeros included
        self.assertEqual((by_id["saas"]["active"], by_id["saas"]["shipped"]), (0, 0))

    def test_games_resume_lifecycle_over_http(self):
        # Seed a budget-paused game directly in the (temp) studio store.
        state = relay.games_module.new_studio_state()
        game = relay.games_module.seed_concept(state, "Money Pit", "hyper-casual")
        game.update({"stage": "paused", "paused_from": "playtest",
                     "paused_note": "budget exhausted",
                     "calls_used": relay.games_module.DEFAULT_BUDGET})
        relay.games_module.StudioStore(relay.GAMES_STATE_PATH).save(state)

        status, payload = self.request("POST", "/games/resume", {"id": game["id"]})
        self.assertEqual(status, 200)
        resumed = next(g for g in payload["games"] if g["id"] == game["id"])
        self.assertEqual(resumed["stage"], "playtest")   # pre-pause stage restored
        self.assertEqual(resumed["calls_used"],
                         relay.games_module.DEFAULT_BUDGET
                         - relay.games_module.RESUME_TOP_UP_CALLS)
        self.assertNotIn("paused_from", resumed)
        # The resume persisted — not just the response payload.
        saved = relay.games_module.StudioStore(relay.GAMES_STATE_PATH).load()
        self.assertEqual(saved["games"][0]["stage"], "playtest")

        status, payload = self.request("POST", "/games/resume", {"id": game["id"]})
        self.assertEqual(status, 400)                    # already running
        status, payload = self.request("POST", "/games/resume", {"id": "nope"})
        self.assertEqual((status, payload["error"]), (404, "game_not_found"))

    def test_install_status_degrades_and_export_respects_it(self):
        # No install-day.json in this temp home → honest available:false on
        # both the status poll and the export kick (no thread started).
        status, payload = self.request("GET", "/company/initiative/x/install")
        self.assertEqual((status, payload["available"]), (200, False))
        status, payload = self.request("POST", "/company/initiative/x/export-ipa", {})
        self.assertEqual((status, payload["available"]), (200, False))

    def test_install_assets_are_served_without_auth_by_token(self):
        ipa = Path(self.tmp.name) / "app.ipa"
        ipa.write_bytes(b"ipa-over-http")
        relay.set_install_entry("init1", status="ready", token="cap_token_16chars",
                                ipa_path=str(ipa), bundle_id="com.jamie.quake",
                                version="1.0", title="Quake App")
        base = "https://mac.tail4cd83c.ts.net:8443"
        with mock.patch.object(relay, "tailnet_https_base", lambda force=False: base):
            # NO Authorization header on either fetch — exactly how iOS calls it.
            req = urllib.request.Request(
                f"http://127.0.0.1:{self.port}/install/cap_token_16chars/manifest.plist")
            with urllib.request.urlopen(req, timeout=10) as response:
                self.assertEqual(response.status, 200)
                self.assertEqual(response.headers["Content-Type"], "text/xml; charset=utf-8")
                self.assertIn(b"com.jamie.quake", response.read())
            req = urllib.request.Request(
                f"http://127.0.0.1:{self.port}/install/cap_token_16chars/app.ipa")
            with urllib.request.urlopen(req, timeout=10) as response:
                self.assertEqual(response.read(), b"ipa-over-http")
            status, payload = self.request(
                "GET", "/install/WRONG-token/manifest.plist", token=None)
            self.assertEqual((status, payload["error"]), (404, "not_found"))
            status, payload = self.request("GET", "/install/", token=None)
            self.assertEqual(status, 404)


class TestFlightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.originals = (relay.INSTALL_DAY_CONFIG_PATH, relay.INSTALLS_STATE_PATH,
                          relay.COMPANY_STATE_PATH, relay.COMPANY_ARTIFACTS_ROOT,
                          relay.asc_module.ASC_CONFIG_PATH)
        relay.INSTALL_DAY_CONFIG_PATH = root / "install-day.json"
        relay.INSTALLS_STATE_PATH = root / "mobile-installs.json"
        relay.COMPANY_STATE_PATH = root / "company.json"
        relay.COMPANY_ARTIFACTS_ROOT = root / "Boardroom"
        relay.asc_module.ASC_CONFIG_PATH = root / "asc.json"
        state = relay.company_module.new_state()
        self.init = relay.company_module.new_initiative("Quake App", "p")
        state["initiatives"] = [self.init]
        relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).save(state)

    def tearDown(self):
        (relay.INSTALL_DAY_CONFIG_PATH, relay.INSTALLS_STATE_PATH,
         relay.COMPANY_STATE_PATH, relay.COMPANY_ARTIFACTS_ROOT,
         relay.asc_module.ASC_CONFIG_PATH) = self.originals
        self.tmp.cleanup()

    def configure(self):
        key = Path(self.tmp.name) / "AuthKey_KEY1.p8"
        key.write_text("fake-key")
        relay.asc_module.ASC_CONFIG_PATH.write_text(json.dumps(
            {"key_path": str(key), "key_id": "KEY1", "issuer_id": "iss-1"}))
        relay.INSTALL_DAY_CONFIG_PATH.write_text('{"team_id": "TEAM123XYZ"}')

    def test_status_degrades_without_asc_key(self):
        status = relay.submit_status(self.init["id"])
        self.assertFalse(status["available"])
        self.assertIn("asc.json", status["note"])

    def test_status_degrades_without_team_id(self):
        key = Path(self.tmp.name) / "AuthKey_KEY1.p8"
        key.write_text("fake-key")
        relay.asc_module.ASC_CONFIG_PATH.write_text(json.dumps(
            {"key_path": str(key), "key_id": "KEY1", "issuer_id": "iss-1"}))
        status = relay.submit_status(self.init["id"])
        self.assertFalse(status["available"])
        self.assertIn("install-day.json", status["note"])

    def test_tf_entries_never_leak_into_install_status(self):
        self.configure()
        relay.set_install_entry(relay._tf_key(self.init["id"]),
                                status="submitted", note="uploaded")
        self.assertEqual(relay.install_status(self.init["id"])["status"], "none")
        self.assertEqual(relay.submit_status(self.init["id"])["status"], "submitted")

    def test_begin_submit_claims_the_slot_once(self):
        self.configure()
        self.assertTrue(relay.begin_submit(self.init["id"]))
        self.assertFalse(relay.begin_submit(self.init["id"]))   # already submitting

    def test_submit_records_the_archive_failure_honestly(self):
        self.configure()
        (relay.COMPANY_ARTIFACTS_ROOT
         / relay.company_module.initiative_dirname(self.init)).mkdir(parents=True)
        # No .xcodeproj in the deliverables → the honest failure, no upload attempted.
        relay._submit_testflight(self.init["id"])
        status = relay.submit_status(self.init["id"])
        self.assertEqual(status["status"], "failed")
        self.assertIn("xcodeproj", status["note"])

    def test_successful_upload_marks_submitted(self):
        self.configure()
        artifacts = (relay.COMPANY_ARTIFACTS_ROOT
                     / relay.company_module.initiative_dirname(self.init))
        tf_dir = artifacts / ".testflight"
        app = tf_dir / "app.xcarchive" / "Products" / "Applications" / "Quake.app"

        def fake_archive(initiative_id, team_id, subdir):
            app.mkdir(parents=True, exist_ok=True)
            return tf_dir, app, ""

        def fake_run(command, timeout, cwd=None):
            if "-exportArchive" in command:
                ipa = tf_dir / "export" / "Quake.ipa"
                ipa.parent.mkdir(parents=True, exist_ok=True)
                ipa.write_bytes(b"ipa")
            self.commands.append(command)
            return subprocess.CompletedProcess(command, 0, "ok", "")

        self.commands = []
        with mock.patch.object(relay, "_archive_initiative", fake_archive), \
                mock.patch.object(relay, "run_killable", fake_run), \
                mock.patch.object(relay, "send_push", return_value=0), \
                mock.patch.object(relay, "_ensure_altool_key"):
            relay._submit_testflight(self.init["id"])
        status = relay.submit_status(self.init["id"])
        self.assertEqual(status["status"], "submitted")
        self.assertIn("TestFlight", status["note"])
        upload = self.commands[-1]
        self.assertIn("--upload-app", upload)
        self.assertEqual(upload[upload.index("--apiKey") + 1], "KEY1")
        self.assertEqual(upload[upload.index("--apiIssuer") + 1], "iss-1")


class PromoteAndPortfolioTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.originals = (relay.COMPANY_STATE_PATH, relay.COMPANY_ARTIFACTS_ROOT,
                          relay.COMPANY_VAULT_ROOT)
        relay.COMPANY_STATE_PATH = root / "company.json"
        relay.COMPANY_ARTIFACTS_ROOT = root / "Boardroom"
        relay.COMPANY_VAULT_ROOT = root / "Vault"

    def tearDown(self):
        (relay.COMPANY_STATE_PATH, relay.COMPANY_ARTIFACTS_ROOT,
         relay.COMPANY_VAULT_ROOT) = self.originals
        self.tmp.cleanup()

    def _save(self, state):
        relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).save(state)

    def test_promote_runs_prod_deploy_and_records_the_url(self):
        state = relay.company_module.new_state()
        init = relay.company_module.seed_initiative(state, "[Webapps division] tip calc")
        init["stage"] = "shipped"
        init["live_url"] = "https://preview.vercel.app"
        self._save(state)

        def fake_deploy(scratch, target, outdir, prod=False):
            self.assertTrue(prod)
            relay.company_module.log_event(scratch, "Live at https://prod.vercel.app — tip calc")
            return "https://prod.vercel.app"

        with mock.patch.object(relay.company_module, "deploy_initiative", fake_deploy):
            relay.promote_in_background(init["id"])
            time.sleep(0.3)   # daemon thread
        saved = relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).load()
        promoted = relay.company_module.find_initiative(saved, init["id"])
        self.assertEqual(promoted["live_url"], "https://prod.vercel.app")
        self.assertTrue(any("Live at https://prod.vercel.app" in e["text"]
                            for e in saved["events"]))

    def test_promote_skips_non_deploy_divisions(self):
        state = relay.company_module.new_state()
        init = relay.company_module.seed_initiative(state, "[Legal division] policies")
        init["stage"] = "shipped"
        self._save(state)
        with mock.patch.object(relay.company_module, "deploy_initiative") as deploy:
            relay.promote_in_background(init["id"])
            time.sleep(0.3)
        deploy.assert_not_called()

    def test_adopted_asset_never_gets_auto_pushed_by_ship(self):
        repo = Path(self.tmp.name) / "TipApp"
        repo.mkdir()
        init = relay.company_module.new_initiative("Portfolio: TipApp", "")
        init["workdir"] = str(repo)
        with mock.patch.object(relay, "_remote_https_url",
                               return_value="https://github.com/o/tipapp") as remote, \
                mock.patch.object(relay, "ship_commands") as commands:
            url = relay.ship_initiative(init)
        self.assertEqual(url, "https://github.com/o/tipapp")
        commands.assert_not_called()     # no git init / gh create on the owner's repo
        remote.assert_called_once_with(repo)

    def test_lessons_file_into_the_vault_once(self):
        state = relay.company_module.new_state()
        init = relay.company_module.new_initiative("Tip Calc", "")
        init["stage"] = "killed"
        relay.company_module.record_lesson(state, init)
        self.assertEqual(relay.file_unfiled_lessons(state), 1)
        notes = list((relay.COMPANY_VAULT_ROOT / "Lessons").glob("*.md"))
        self.assertEqual(len(notes), 1)
        body = notes[0].read_text()
        self.assertIn("type: lesson", body)
        self.assertIn("Tip Calc", body)
        self.assertEqual(relay.file_unfiled_lessons(state), 0)   # marked filed


class FrontierEndpointTests(unittest.TestCase):
    """/company/live, /company/portfolio/adopt, and the TestFlight status route
    over real HTTP with bearer auth."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        cls.originals = (relay.COMPANY_STATE_PATH, relay.COMPANY_ARTIFACTS_ROOT,
                         relay.INSTALLS_STATE_PATH, relay.INSTALL_DAY_CONFIG_PATH,
                         relay.asc_module.ASC_CONFIG_PATH, relay.RelayHandler.token)
        relay.COMPANY_STATE_PATH = root / "company.json"
        relay.COMPANY_ARTIFACTS_ROOT = root / "Boardroom"
        relay.INSTALLS_STATE_PATH = root / "mobile-installs.json"
        relay.INSTALL_DAY_CONFIG_PATH = root / "install-day.json"
        relay.asc_module.ASC_CONFIG_PATH = root / "asc.json"
        relay.RelayHandler.token = "test-token"
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), relay.RelayHandler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        (relay.COMPANY_STATE_PATH, relay.COMPANY_ARTIFACTS_ROOT,
         relay.INSTALLS_STATE_PATH, relay.INSTALL_DAY_CONFIG_PATH,
         relay.asc_module.ASC_CONFIG_PATH, relay.RelayHandler.token) = cls.originals
        cls.tmp.cleanup()

    def request(self, method, path, body=None, token="test-token"):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}", method=method,
            data=json.dumps(body).encode() if body is not None else None)
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read().decode())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read().decode())

    def test_new_endpoints_reject_missing_token(self):
        for method, path in (("GET", "/company/live"),
                             ("GET", "/company/initiative/x/testflight"),
                             ("POST", "/company/initiative/x/submit-testflight"),
                             ("POST", "/company/portfolio/adopt")):
            status, payload = self.request(method, path,
                                           body={} if method == "POST" else None,
                                           token=None)
            self.assertEqual((status, payload["error"]), (401, "unauthorized"), path)

    def test_live_feed_shows_the_working_initiatives_last_turn(self):
        state = relay.company_module.new_state()
        state["enabled"] = True
        init = relay.company_module.new_initiative("Tip Calc", "")
        init["stage"] = "execution"
        init["exec_phase"] = "build"
        init["calls_used"] = 4
        relay.company_module.log_minute(init, "execution", "builder", "wiring the UI " * 400)
        gated = relay.company_module.new_initiative("Waiting", "")
        gated["stage"] = "gate1"   # paused — must NOT appear as working
        state["initiatives"] = [init, gated]
        relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).save(state)

        status, payload = self.request("GET", "/company/live")
        self.assertEqual(status, 200)
        self.assertTrue(payload["enabled"])
        self.assertEqual(len(payload["working"]), 1)
        entry = payload["working"][0]
        self.assertEqual((entry["id"], entry["stage"], entry["phase"],
                          entry["role"], entry["calls_used"]),
                         (init["id"], "execution", "build", "builder", 4))
        self.assertLessEqual(len(entry["text"]), 2000)   # tail-capped

    def test_adopt_over_http_creates_the_portfolio_initiative(self):
        repo = Path(self.tmp.name) / "QuantFit"
        repo.mkdir(exist_ok=True)
        relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).save(
            relay.company_module.new_state())
        status, payload = self.request("POST", "/company/portfolio/adopt",
                                       body={"path": str(repo), "division": "webapps"})
        self.assertEqual(status, 200)
        adopted = payload["initiatives"][0]
        self.assertEqual(adopted["stage"], "planning")
        self.assertEqual(adopted["workdir"], str(repo))
        self.assertIn("QuantFit", adopted["title"])

    def test_adopt_rejects_a_bogus_path_with_400(self):
        status, payload = self.request("POST", "/company/portfolio/adopt",
                                       body={"path": "/nope/never/exists"})
        self.assertEqual(status, 400)
        self.assertIn("not a folder", payload["error"])

    def test_testflight_status_route_serves_the_honest_note(self):
        status, payload = self.request("GET", "/company/initiative/whatever/testflight")
        self.assertEqual(status, 200)
        self.assertFalse(payload["available"])
        self.assertIn("asc.json", payload["note"])

    def test_convene_requires_a_topic_then_spawns_the_meeting(self):
        status, payload = self.request("POST", "/company/meeting/convene", body={})
        self.assertEqual((status, payload["error"]), (400, "topic_required"))
        with mock.patch.object(relay, "run_scheduled_meeting") as run:
            status, payload = self.request("POST", "/company/meeting/convene",
                                           body={"topic": "Ship week planning"})
            self.assertEqual((status, payload.get("ok")), (200, True))
            time.sleep(0.3)   # the spawned daemon thread calls the (mocked) runner
            run.assert_called_once_with("Ship week planning")

    def test_one_shot_schedule_lands_with_its_fire_time(self):
        relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).save(
            relay.company_module.new_state())
        fire_at = time.time() + 3600
        status, payload = self.request("POST", "/company/schedules", body={
            "title": "Q3 kickoff", "kind": "meeting", "text": "Q3 kickoff",
            "cadence": "once", "at_ts": fire_at})
        self.assertEqual(status, 200)
        sched = payload["schedules"][-1]
        self.assertEqual((sched["cadence"], sched["kind"]), ("once", "meeting"))
        self.assertAlmostEqual(sched["at_ts"], fire_at, delta=1)


class MeetingActionsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.original = relay.COMPANY_STATE_PATH
        relay.COMPANY_STATE_PATH = Path(self.tmp.name) / "company.json"
        state = relay.company_module.new_state()
        self.meeting = relay.company_module.new_meeting("Ship week", ["ceo", "cfo"])
        self.meeting["status"] = "done"
        self.meeting["turns"] = [
            {"role": "ceo", "text": "We must fix onboarding.", "ts": "10:00"},
            {"role": "cfo", "text": "And cut the render costs.", "ts": "10:01"},
        ]
        state["meetings"] = [self.meeting]
        relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).save(state)

    def tearDown(self):
        relay.COMPANY_STATE_PATH = self.original
        self.tmp.cleanup()

    def _saved_tasks(self):
        return relay.company_module.CompanyStore(relay.COMPANY_STATE_PATH).load()["tasks"]

    def test_action_items_land_in_the_kanban(self):
        reply = ("- Fix the onboarding flow drop-off on step 2\n"
                 "1. Cut GPU render costs by batching exports\n"
                 "short\n")
        with mock.patch.object(relay, "company_cli_runner", return_value=reply):
            relay.run_meeting_actions(self.meeting["id"])
        tasks = self._saved_tasks()
        self.assertEqual([t["text"] for t in tasks],
                         ["Fix the onboarding flow drop-off on step 2",
                          "Cut GPU render costs by batching exports"])

    def test_none_reply_creates_no_tasks(self):
        with mock.patch.object(relay, "company_cli_runner", return_value="NONE"):
            relay.run_meeting_actions(self.meeting["id"])
        self.assertEqual(self._saved_tasks(), [])

    def test_runner_failure_is_swallowed_honestly(self):
        with mock.patch.object(relay, "company_cli_runner",
                               side_effect=RuntimeError("agent down")):
            relay.run_meeting_actions(self.meeting["id"])   # must not raise
        self.assertEqual(self._saved_tasks(), [])


if __name__ == "__main__":
    unittest.main()
