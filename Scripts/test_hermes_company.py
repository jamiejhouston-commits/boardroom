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
        self.assertEqual(state["config"]["budget_calls"], 70)
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
        d = company.new_initiative("D", "")
        d["stage"] = "blocked"                          # active, not working
        c = company.new_initiative("C", "")
        c["stage"] = "killed"                           # terminal
        state["initiatives"] = [a, b, d, c]
        self.assertEqual([i["id"] for i in company.active(state)], [a["id"], b["id"], d["id"]])
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

    def test_run_scout_learns_from_killed_ideas(self):
        state = company.new_state()
        dead = company.new_initiative("Plant Watering Lite", "")
        dead["stage"] = "killed"
        state["initiatives"] = [dead]
        seen = {}
        def runner(role, prompt):
            seen["prompt"] = prompt
            return SCOUT_REPLY
        company.run_scout(state, runner)
        self.assertIn("REJECTED", seen["prompt"])            # rejection feedback loop
        self.assertIn("Plant Watering Lite", seen["prompt"])
        self.assertIn("pay", seen["prompt"].lower())         # demand evidence demanded

    def test_run_scout_feeds_back_portfolio_revenue(self):
        state = company.new_state()
        state["revenue_brief"] = "MRR: $412.00 · Active Subscriptions: 61"
        seen = {}
        def runner(role, prompt):
            seen["prompt"] = prompt
            return SCOUT_REPLY
        company.run_scout(state, runner)
        self.assertIn("MRR: $412.00", seen["prompt"])
        self.assertIn("PORTFOLIO PERFORMANCE", seen["prompt"])

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

    def advance_until(self, runner, target, limit=40):
        """Drive the per-turn execution machine until the initiative reaches
        `target` (execution now advances ONE agent turn per call)."""
        for _ in range(limit):
            if self.init["stage"] == target:
                return
            self.advance(runner)
        self.fail(f"never reached {target}; stuck at {self.init['stage']}")

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
        self.advance_until(runner, "demo_ready")
        self.assertEqual(roles, ["builder", "qa"])   # one turn per tick: build, then review
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
        self.advance_until(runner, "demo_ready")
        self.assertEqual(qa_calls["n"], 2)      # one REVISE round, then SHIP
        self.assertEqual(self.init["review_rounds"], 2)

    def test_execution_resumes_at_saved_phase_after_a_crashed_turn(self):
        # THE ship-blocker fix: a timed-out/crashed turn must cost ONE turn,
        # not restart the whole build + QA loop from scratch.
        self.init["stage"] = "execution"
        outdir = self.root / company.initiative_dirname(self.init)
        outdir.mkdir(parents=True, exist_ok=True)
        (outdir / "f.txt").write_text("x")
        roles = []
        def ok(role, prompt):
            roles.append(role)
            return "VERDICT: SHIP" if role == "qa" else "built"
        def boom(role, prompt):
            raise RuntimeError("timed out after 1800 seconds")
        self.advance(ok)                                  # build turn done
        self.assertEqual(self.init["exec_phase"], "review")
        with self.assertRaises(RuntimeError):
            self.advance(boom)                            # QA turn dies
        self.assertEqual(self.init["exec_phase"], "review")   # progress kept
        self.advance(ok)                                  # QA retried, ships
        self.assertEqual(self.init["stage"], "demo_ready")
        self.assertEqual(roles, ["builder", "qa"])        # build never re-ran

    def test_execution_exhausts_rounds_and_ships_what_exists(self):
        self.init["stage"] = "execution"
        outdir = self.root / company.initiative_dirname(self.init)
        outdir.mkdir(parents=True, exist_ok=True)
        (outdir / "f.txt").write_text("x")
        def runner(role, prompt):
            return "VERDICT: REVISE\n1. more" if role == "qa" else "built"
        self.advance_until(runner, "demo_ready")
        self.assertEqual(self.init["review_rounds"], company.MAX_REVIEW_ROUNDS)

    def test_budget_exhaustion_mid_review_still_reaches_demo_ready(self):
        self.init["stage"] = "execution"
        self.init["exec_phase"] = "review"
        def runner(role, prompt):
            raise company.BudgetExceeded("out of calls")
        self.advance(runner)
        self.assertEqual(self.init["stage"], "demo_ready")   # ship what exists

    def test_qa_prompt_forbids_unverifiable_revise_reasons(self):
        # QA may only vote on what it can verify on this machine; device-only
        # checks go to the owner checklist instead of blocking the ship.
        self.init["stage"] = "execution"
        self.init["exec_phase"] = "review"
        seen = {}
        def runner(role, prompt):
            seen["prompt"] = prompt
            return "VERDICT: SHIP"
        self.advance(runner)
        self.assertIn("OWNER CHECKLIST", seen["prompt"])

    def test_review_passed_parsing(self):
        self.assertTrue(company.review_passed("looks great\nVERDICT: SHIP"))
        self.assertFalse(company.review_passed("VERDICT: REVISE\n1. x"))
        self.assertFalse(company.review_passed("no verdict at all"))

    def test_demo_ready_captures_screenshots_then_invites(self):
        self.init["stage"] = "demo_ready"
        roles = []
        def runner(role, prompt):
            roles.append(role)
            return "Demo Day: we built Trend Radar." if role == "ceo" else "captured 3 shots"
        self.advance(runner)                      # phase 1: builder captures demo
        self.assertEqual(self.init["stage"], "demo_ready")
        self.assertEqual(self.init["demo_phase"], "invite")
        self.advance(runner)                      # phase 2: CEO writes the invite
        self.assertEqual(self.init["stage"], "gate2")
        self.assertIn("Demo Day", self.init["brief"])
        self.assertEqual(roles, ["builder", "ceo"])

    def test_demo_capture_prompt_demands_real_screenshots(self):
        self.init["stage"] = "demo_ready"
        seen = {}
        def runner(role, prompt):
            seen["prompt"] = prompt
            return "ok"
        self.advance(runner)
        self.assertIn(".demo", seen["prompt"])
        self.assertIn("NEVER fake", seen["prompt"])


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
        self.init["exec_phase"] = "review"
        self.init["review_rounds"] = 6
        company.apply_gate(self.state, self.init["id"], "revise", "fix the report")
        self.assertEqual(self.init["stage"], "execution")
        self.assertEqual(self.init["exec_phase"], "build")   # extend, fresh QA rounds
        self.assertEqual(self.init["review_rounds"], 0)

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
        # Tick behavior must not depend on the host's live load average —
        # the credit-protection gate has its own tests (OverloadGateTests).
        self._real_overloaded = company.machine_overloaded
        company.machine_overloaded = lambda *a, **k: False

    def tearDown(self):
        company.machine_overloaded = self._real_overloaded
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

    def test_advances_working_initiative_even_within_interval(self):
        # Speed fix: in-flight work no longer waits out interval_minutes between
        # stages — advancing is every heartbeat; only scouting stays throttled.
        init = company.new_initiative("A", "")
        self.state["initiatives"] = [init]
        self.state["last_tick"] = NOON - 60   # ticked a minute ago
        self.tick(runner=lambda r, p: "memo")
        self.assertEqual(init["stage"], "boardroom")

    def test_budget_exhaustion_blocks_initiative(self):
        init = company.new_initiative("A", "")
        init["calls_used"] = 70
        self.state["initiatives"] = [init]
        self.tick(runner=lambda r, p: "memo")
        self.assertEqual(init["stage"], "blocked")
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

    def test_repeated_stalls_block_initiative(self):
        bad = company.new_initiative("Bad", "")
        bad["stall_count"] = company.MAX_STALLS - 1
        self.state["initiatives"] = [bad]
        def runner(role, prompt):
            raise RuntimeError("relay offline")
        self.tick(runner=runner)
        self.assertEqual(bad["stage"], "blocked")   # no silent retry loop; no false business kill
        self.assertIn("blocked after", bad["note"])


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

    def test_tick_events_reach_the_activity_feed(self):
        # Events tick() logged used to be dropped by the merge — the log file
        # saw "advanced/stalled/paused" but the app's feed NEVER did, so a
        # hard-working company looked frozen to the owner.
        company.log_event(self.ticked, "x1 advanced to execution (review)")
        company.log_event(self.current, "meeting started: standup")  # mid-tick
        merged = company.merge_tick_results(self.current, self.ticked, self.before)
        texts = [e["text"] for e in merged["events"]]
        self.assertIn("x1 advanced to execution (review)", texts)
        self.assertIn("meeting started: standup", texts)   # both survive

    def test_engine_bookkeeping_survives_merge(self):
        self.ticked["engine"] = {"overloaded_since": 123.0}
        merged = company.merge_tick_results(self.current, self.ticked, self.before)
        self.assertEqual(merged["engine"], {"overloaded_since": 123.0})


class OverloadGateTests(unittest.TestCase):
    """The credit-protection gate: at crush load a company turn times out
    AFTER the API charged, so the engine must not spend at all."""

    def _enabled_state(self):
        state = company.new_state()
        state["enabled"] = True
        return state

    def _patched(self, overloaded: bool):
        originals = (company.machine_overloaded, company.is_quiet)
        company.machine_overloaded = lambda *a, **k: overloaded
        company.is_quiet = lambda *a, **k: False
        return originals

    def _restore(self, originals):
        company.machine_overloaded, company.is_quiet = originals

    def test_tick_defers_and_spends_nothing_when_overloaded(self):
        state = self._enabled_state()
        state["initiatives"].append({
            "id": "x1", "title": "T", "stage": "execution",
            "calls_used": 0, "stall_count": 0,
        })
        calls: list[str] = []

        def runner(role, prompt):
            calls.append(role)
            return "should never run"

        originals = self._patched(overloaded=True)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                events = company.tick(state, runner, Path(tmp))
        finally:
            self._restore(originals)
        self.assertEqual(calls, [])                       # zero API spend
        self.assertTrue(any("overloaded" in e for e in events))
        self.assertEqual(state["initiatives"][0]["stall_count"], 0)  # not a stall

    def test_overload_pause_is_visible_in_activity_feed_throttled(self):
        # The pause used to be log-file-only: the owner watched a "frozen"
        # company for hours with no explanation anywhere in the app.
        state = self._enabled_state()
        originals = self._patched(overloaded=True)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                company.tick(state, lambda r, p: "", Path(tmp), now=NOON)
                company.tick(state, lambda r, p: "", Path(tmp), now=NOON + 60)
        finally:
            self._restore(originals)
        paused = [e for e in state["events"] if "paused: Mac overloaded" in e["text"]]
        self.assertEqual(len(paused), 1)   # visible, but throttled (≤ 1 / 15 min)

    def test_starvation_escape_forces_exactly_one_turn(self):
        # Parked 45+ min at elevated-but-not-crushing load → ONE bounded turn
        # runs so the pipeline keeps inching toward shipping.
        state = self._enabled_state()
        first = company.new_initiative("First", "")
        second = company.new_initiative("Second", "")
        first["stage"] = second["stage"] = "research"
        state["initiatives"] = [first, second]
        state["engine"] = {"overloaded_since": NOON - 46 * 60}
        originals = self._patched(overloaded=True)
        real_load = company.load_per_core
        company.load_per_core = lambda: (10.0, 8.0)   # limit 20, 10 < 2×limit
        try:
            with tempfile.TemporaryDirectory() as tmp:
                company.tick(state, lambda r, p: "memo", Path(tmp), now=NOON)
        finally:
            company.load_per_core = real_load
            self._restore(originals)
        self.assertNotEqual(first["stage"], "research")    # advanced
        self.assertEqual(second["stage"], "research")      # waited its turn
        self.assertTrue(any("forcing one turn" in e["text"] for e in state["events"]))

    def test_crushing_load_never_forces_a_turn(self):
        state = self._enabled_state()
        init = company.new_initiative("First", "")
        init["stage"] = "research"
        state["initiatives"] = [init]
        state["engine"] = {"overloaded_since": NOON - 3 * 3600}
        originals = self._patched(overloaded=True)
        real_load = company.load_per_core
        company.load_per_core = lambda: (60.0, 8.0)   # 60 > 2×limit(20): futile
        try:
            with tempfile.TemporaryDirectory() as tmp:
                company.tick(state, lambda r, p: "memo", Path(tmp), now=NOON)
        finally:
            company.load_per_core = real_load
            self._restore(originals)
        self.assertEqual(init["stage"], "research")   # spent nothing

    def test_stall_note_is_truncated_to_human_size(self):
        state = self._enabled_state()
        init = company.new_initiative("First", "")
        init["stage"] = "research"
        state["initiatives"] = [init]

        def exploding_runner(role, prompt):
            raise RuntimeError("x" * 5000)   # e.g. TimeoutExpired's full prompt dump

        originals = self._patched(overloaded=False)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                company.tick(state, exploding_runner, Path(tmp), now=NOON)
        finally:
            self._restore(originals)
        self.assertLess(len(init["note"]), 350)
        self.assertIn("stalled (1/", init["note"])

    def test_no_meeting_when_overloaded(self):
        state = self._enabled_state()
        state["last_meeting"] = 0.0
        originals = self._patched(overloaded=True)
        try:
            self.assertFalse(company.should_convene_meeting(state, time.time()))
        finally:
            self._restore(originals)

    def test_meeting_allowed_when_not_overloaded(self):
        state = self._enabled_state()
        state["last_meeting"] = 0.0
        originals = self._patched(overloaded=False)
        try:
            self.assertTrue(company.should_convene_meeting(state, time.time()))
        finally:
            self._restore(originals)

    def test_machine_overloaded_thresholds(self):
        import os
        original = os.getloadavg
        try:
            os.getloadavg = lambda: (10_000.0, 0.0, 0.0)
            self.assertTrue(company.machine_overloaded())
            os.getloadavg = lambda: (0.5, 0.0, 0.0)
            self.assertFalse(company.machine_overloaded())
        finally:
            os.getloadavg = original


if __name__ == "__main__":
    unittest.main()
