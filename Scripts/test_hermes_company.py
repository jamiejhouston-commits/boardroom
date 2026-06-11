import importlib.util
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).with_name("hermes_company.py")
SPEC = importlib.util.spec_from_file_location("hermes_company", SCRIPT_PATH)
company = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(company)


class StateStoreTests(unittest.TestCase):
    def test_new_state_defaults(self):
        state = company.new_state()
        self.assertFalse(state["enabled"])
        self.assertEqual(state["thesis"], "")
        self.assertEqual(state["initiatives"], [])
        self.assertEqual(state["config"]["max_active"], 1)
        self.assertEqual(state["config"]["budget_calls"], 40)
        self.assertEqual(state["config"]["interval_minutes"], 30)

    def test_store_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = company.CompanyStore(Path(tmp) / "company.json")
            state = company.new_state()
            state["thesis"] = "small consumer apps"
            store.save(state)
            loaded = store.load()
            self.assertEqual(loaded["thesis"], "small consumer apps")

    def test_store_load_missing_file_returns_new_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = company.CompanyStore(Path(tmp) / "nope.json")
            self.assertFalse(store.load()["enabled"])

    def test_new_initiative_shape(self):
        init = company.new_initiative("Trend Tracker", "tracks trends")
        self.assertEqual(init["stage"], "research")
        self.assertEqual(init["calls_used"], 0)
        self.assertEqual(init["minutes"], [])
        self.assertTrue(init["id"])


class GuardrailTests(unittest.TestCase):
    def test_quiet_hours_overnight_window(self):
        self.assertTrue(company.is_quiet(23, 22, 7))
        self.assertTrue(company.is_quiet(3, 22, 7))
        self.assertFalse(company.is_quiet(12, 22, 7))

    def test_quiet_hours_daytime_window(self):
        self.assertTrue(company.is_quiet(14, 13, 16))
        self.assertFalse(company.is_quiet(9, 13, 16))

    def test_quiet_hours_disabled_when_equal(self):
        self.assertFalse(company.is_quiet(5, 8, 8))

    def test_active_and_working_partitions(self):
        state = company.new_state()
        a = company.new_initiative("A", "")            # research → working
        b = company.new_initiative("B", "")
        b["stage"] = "gate1"                            # active, not working
        c = company.new_initiative("C", "")
        c["stage"] = "killed"                           # terminal
        state["initiatives"] = [a, b, c]
        self.assertEqual([i["id"] for i in company.active(state)], [a["id"], b["id"]])
        self.assertEqual([i["id"] for i in company.working(state)], [a["id"]])

    def test_charged_runner_counts_and_raises_over_budget(self):
        init = company.new_initiative("A", "")
        init["calls_used"] = 39
        runner = company.make_charged_runner(init, budget=40, runner=lambda r, p: "ok")
        self.assertEqual(runner("ceo", "hi"), "ok")
        self.assertEqual(init["calls_used"], 40)
        with self.assertRaises(company.BudgetExceeded):
            runner("ceo", "again")


SCOUT_REPLY = """Here's what I found.
{"ideas": [
  {"title": "Focus Timer", "pitch": "ADHD-friendly timer", "heat": 6, "fit": 8, "effort": 3, "rationale": "trending"},
  {"title": "Trend Radar", "pitch": "daily trend digest", "heat": 9, "fit": 7, "effort": 4, "rationale": "hot"}
]}
Done."""


class ScoutTests(unittest.TestCase):
    def test_parse_ideas_extracts_json_from_noise(self):
        ideas = company.parse_ideas(SCOUT_REPLY)
        self.assertEqual(len(ideas), 2)
        self.assertEqual(ideas[0]["title"], "Focus Timer")

    def test_parse_ideas_garbage_returns_empty(self):
        self.assertEqual(company.parse_ideas("no json here"), [])
        self.assertEqual(company.parse_ideas('{"ideas": "not a list"}'), [])

    def test_run_scout_creates_best_scoring_initiative(self):
        state = company.new_state()
        state["thesis"] = "consumer apps"
        init = company.run_scout(state, lambda role, prompt: SCOUT_REPLY)
        # Trend Radar: 9+7-4=12 beats Focus Timer: 6+8-3=11
        self.assertIsNotNone(init)
        self.assertEqual(init["title"], "Trend Radar")
        self.assertEqual(init["stage"], "research")
        self.assertEqual(len(state["initiatives"]), 1)

    def test_run_scout_includes_thesis_in_prompt(self):
        seen = {}
        def runner(role, prompt):
            seen["role"], seen["prompt"] = role, prompt
            return SCOUT_REPLY
        company.run_scout({"thesis": "no crypto", "config": dict(company.DEFAULT_CONFIG), "initiatives": [], "enabled": True, "last_tick": 0}, runner)
        self.assertEqual(seen["role"], "research")
        self.assertIn("no crypto", seen["prompt"])

    def test_run_scout_unparseable_returns_none(self):
        state = company.new_state()
        self.assertIsNone(company.run_scout(state, lambda r, p: "imagine no json"))
        self.assertEqual(state["initiatives"], [])


if __name__ == "__main__":
    unittest.main()
