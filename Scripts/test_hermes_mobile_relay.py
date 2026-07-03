import importlib.util
import os
import subprocess
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
