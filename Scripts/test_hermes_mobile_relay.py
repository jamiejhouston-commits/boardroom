import importlib.util
import tempfile
import unittest
from pathlib import Path


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


class ShipTests(unittest.TestCase):
    def test_ship_commands_create_private_repo_from_outdir(self):
        commands = relay.ship_commands(Path("/tmp/proj-x"), "proj-x")
        gh = commands[-1]
        self.assertEqual(gh[:3], ["gh", "repo", "create"])
        self.assertIn("--private", gh)
        self.assertIn("--push", gh)
        self.assertIn("/tmp/proj-x", gh)
        # Every git command targets the deliverables dir, not the CWD.
        for command in commands[:-1]:
            self.assertEqual(command[:3][0], "git")
            self.assertIn("/tmp/proj-x", command)


if __name__ == "__main__":
    unittest.main()
