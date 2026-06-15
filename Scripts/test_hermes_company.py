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


class StageMachineTests(unittest.TestCase):
    def setUp(self):
        self.state = company.new_state()
        self.init = company.new_initiative("Trend Radar", "daily digest")
        self.state["initiatives"] = [self.init]
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def advance(self, runner=None):
        company.advance_stage(self.state, self.init,
                              runner or (lambda r, p: f"{r} says fine."),
                              self.root)

    def test_research_logs_memo_and_moves_to_boardroom(self):
        self.advance()
        self.assertEqual(self.init["stage"], "boardroom")
        self.assertEqual(self.init["minutes"][0]["stage"], "research")

    def test_boardroom_runs_three_voices_plus_ceo_brief(self):
        self.init["stage"] = "boardroom"
        roles = []
        def runner(role, prompt):
            roles.append(role)
            return f"{role}: position."
        self.advance(runner)
        self.assertEqual(roles, ["cfo", "cto", "marketing", "ceo"])
        self.assertEqual(self.init["stage"], "gate1")
        self.assertIn("ceo", self.init["brief"])

    def test_planning_moves_to_execution(self):
        self.init["stage"] = "planning"
        self.advance()
        self.assertEqual(self.init["stage"], "execution")

    def test_execution_builds_reviews_and_moves_to_demo_ready(self):
        self.init["stage"] = "execution"
        outdir = self.root / company.initiative_dirname(self.init)
        roles = []
        def runner(role, prompt):
            roles.append(role)
            if role == "qa":
                return "Complete and polished.\nVERDICT: SHIP"
            outdir.mkdir(parents=True, exist_ok=True)
            (outdir / "report.md").write_text("done")
            return "Created report.md"
        self.advance(runner)
        self.assertEqual(self.init["stage"], "demo_ready")
        self.assertIn("qa", roles)              # QA actually reviewed the build
        self.assertEqual(len(self.init["artifacts"]), 1)

    def test_execution_loops_until_qa_passes(self):
        self.init["stage"] = "execution"
        outdir = self.root / company.initiative_dirname(self.init)
        outdir.mkdir(parents=True, exist_ok=True)
        (outdir / "f.txt").write_text("x")
        qa_calls = {"n": 0}
        def runner(role, prompt):
            if role == "qa":
                qa_calls["n"] += 1
                return "VERDICT: SHIP" if qa_calls["n"] >= 2 else "VERDICT: REVISE\n1. fix it"
            return "built"
        self.advance(runner)
        self.assertEqual(qa_calls["n"], 2)      # one REVISE round, then SHIP
        self.assertEqual(self.init["review_rounds"], 2)
        self.assertEqual(self.init["stage"], "demo_ready")

    def test_review_passed_parsing(self):
        self.assertTrue(company.review_passed("looks great\nVERDICT: SHIP"))
        self.assertFalse(company.review_passed("VERDICT: REVISE\n1. x"))
        self.assertFalse(company.review_passed("no verdict at all"))

    def test_demo_ready_writes_invite_brief_and_moves_to_gate2(self):
        self.init["stage"] = "demo_ready"
        self.advance(lambda r, p: "Demo Day: we built Trend Radar.")
        self.assertEqual(self.init["stage"], "gate2")
        self.assertIn("Demo Day", self.init["brief"])


class GateTests(unittest.TestCase):
    def setUp(self):
        self.state = company.new_state()
        self.init = company.new_initiative("A", "")
        self.state["initiatives"] = [self.init]

    def test_gate1_approve_moves_to_planning(self):
        self.init["stage"] = "gate1"
        company.apply_gate(self.state, self.init["id"], "approve", "go")
        self.assertEqual(self.init["stage"], "planning")
        self.assertEqual(self.init["note"], "go")

    def test_gate1_kill(self):
        self.init["stage"] = "gate1"
        company.apply_gate(self.state, self.init["id"], "kill")
        self.assertEqual(self.init["stage"], "killed")

    def test_gate1_revise_returns_to_research(self):
        self.init["stage"] = "gate1"
        company.apply_gate(self.state, self.init["id"], "revise", "narrower scope")
        self.assertEqual(self.init["stage"], "research")

    def test_gate2_approve_ships(self):
        self.init["stage"] = "gate2"
        company.apply_gate(self.state, self.init["id"], "approve")
        self.assertEqual(self.init["stage"], "shipped")

    def test_gate2_revise_returns_to_execution(self):
        self.init["stage"] = "gate2"
        company.apply_gate(self.state, self.init["id"], "revise", "fix the report")
        self.assertEqual(self.init["stage"], "execution")

    def test_gate_rejects_wrong_stage_and_unknown_id(self):
        self.init["stage"] = "research"
        with self.assertRaises(ValueError):
            company.apply_gate(self.state, self.init["id"], "approve")
        with self.assertRaises(KeyError):
            company.apply_gate(self.state, "nope", "approve")
        self.init["stage"] = "gate1"
        with self.assertRaises(ValueError):
            company.apply_gate(self.state, self.init["id"], "maybe")


NOON = time.mktime((2026, 6, 11, 12, 0, 0, 0, 0, -1))      # 12:00 local
MIDNIGHT = time.mktime((2026, 6, 11, 23, 30, 0, 0, 0, -1))  # 23:30 local


class TickTests(unittest.TestCase):
    def setUp(self):
        self.state = company.new_state()
        self.state["enabled"] = True
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def tick(self, runner=None, now=NOON):
        return company.tick(self.state, runner or (lambda r, p: SCOUT_REPLY),
                            self.root, now=now)

    def test_disabled_company_does_nothing(self):
        self.state["enabled"] = False
        self.assertEqual(self.tick(), [])

    def test_quiet_hours_do_nothing(self):
        self.assertEqual(self.tick(now=MIDNIGHT), [])
        self.assertEqual(self.state["initiatives"], [])

    def test_interval_not_elapsed_does_nothing(self):
        self.state["last_tick"] = NOON - 60   # one minute ago
        self.assertEqual(self.tick(), [])

    def test_scouts_when_capacity_available(self):
        events = self.tick()
        self.assertEqual(len(self.state["initiatives"]), 1)
        self.assertTrue(any("scouted" in e for e in events))

    def test_no_scout_when_at_capacity_even_at_gate(self):
        init = company.new_initiative("Busy", "")
        init["stage"] = "gate1"
        self.state["initiatives"] = [init]
        self.tick()
        self.assertEqual(len(self.state["initiatives"]), 1)

    def test_advances_working_initiative_one_stage(self):
        init = company.new_initiative("A", "")
        self.state["initiatives"] = [init]
        self.tick(runner=lambda r, p: "memo")
        self.assertEqual(init["stage"], "boardroom")

    def test_budget_exhaustion_kills_initiative(self):
        init = company.new_initiative("A", "")
        init["calls_used"] = 40
        self.state["initiatives"] = [init]
        self.tick(runner=lambda r, p: "memo")
        self.assertEqual(init["stage"], "killed")
        self.assertIn("budget", init["note"])

    def test_runner_crash_stalls_initiative_not_heartbeat(self):
        bad = company.new_initiative("Bad", "")
        self.state["initiatives"] = [bad]
        def runner(role, prompt):
            raise RuntimeError("relay offline")
        events = self.tick(runner=runner)
        self.assertIn("stalled", bad["note"])
        self.assertEqual(bad["stage"], "research")  # unchanged, retried next tick
        self.assertTrue(events)

    def test_repeated_stalls_kill_initiative(self):
        bad = company.new_initiative("Bad", "")
        bad["stall_count"] = company.MAX_STALLS - 1
        self.state["initiatives"] = [bad]
        def runner(role, prompt):
            raise RuntimeError("relay offline")
        self.tick(runner=runner)
        self.assertEqual(bad["stage"], "killed")   # no 20-hour silent retry loop


class IterationTests(unittest.TestCase):
    def test_reopen_reenters_planning_with_instruction(self):
        state = company.new_state()
        init = company.new_initiative("Brain Dump", "")
        init["stage"] = "shipped"
        state["initiatives"] = [init]
        company.reopen_for_iteration(state, init["id"], "add a backend with user accounts")
        self.assertEqual(init["stage"], "planning")
        self.assertEqual(init["iteration"], 1)
        self.assertEqual(init["note"], "add a backend with user accounts")
        self.assertEqual(init["review_rounds"], 0)

    def test_iteration_planning_prompt_is_extension(self):
        state = company.new_state()
        init = company.new_initiative("Brain Dump", "")
        init["stage"] = "planning"; init["iteration"] = 2; init["note"] = "add RevenueCat"
        state["initiatives"] = [init]
        seen = {}
        def runner(role, prompt):
            seen["prompt"] = prompt
            return "plan"
        import tempfile, pathlib
        with tempfile.TemporaryDirectory() as tmp:
            company.advance_stage(state, init, runner, pathlib.Path(tmp))
        self.assertIn("iteration 2", seen["prompt"])
        self.assertIn("add RevenueCat", seen["prompt"])
        self.assertEqual(init["stage"], "execution")


class MergeTickTests(unittest.TestCase):
    def setUp(self):
        self.before = company.new_state()
        self.worked = company.new_initiative("Worked", "")
        self.gated = company.new_initiative("Gated", "")
        self.gated["stage"] = "gate1"
        self.before["initiatives"] = [self.worked, self.gated]
        self.before["enabled"] = True
        # Deep copies simulating the tick working on its own snapshot.
        import copy
        self.ticked = copy.deepcopy(self.before)
        self.current = copy.deepcopy(self.before)

    def test_tick_changes_are_applied(self):
        self.ticked["initiatives"][0]["stage"] = "boardroom"
        self.ticked["last_tick"] = 100.0
        merged = company.merge_tick_results(self.current, self.ticked, self.before)
        self.assertEqual(merged["initiatives"][0]["stage"], "boardroom")
        self.assertEqual(merged["last_tick"], 100.0)

    def test_mid_tick_gate_decision_is_preserved(self):
        # Owner approves the gated initiative WHILE the tick runs (tick
        # didn't touch it) — the decision must survive the merge.
        company.apply_gate(self.current, self.gated["id"], "approve")
        merged = company.merge_tick_results(self.current, self.ticked, self.before)
        gated_after = company.find_initiative(merged, self.gated["id"])
        self.assertEqual(gated_after["stage"], "planning")

    def test_mid_tick_halt_is_preserved(self):
        self.current["enabled"] = False
        merged = company.merge_tick_results(self.current, self.ticked, self.before)
        self.assertFalse(merged["enabled"])

    def test_newly_scouted_initiative_is_inserted(self):
        fresh = company.new_initiative("Fresh", "")
        self.ticked["initiatives"].insert(0, fresh)
        merged = company.merge_tick_results(self.current, self.ticked, self.before)
        self.assertEqual(merged["initiatives"][0]["id"], fresh["id"])
        self.assertEqual(len(merged["initiatives"]), 3)


if __name__ == "__main__":
    unittest.main()
