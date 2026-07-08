import importlib.util
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

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
        self.assertEqual(state["config"]["platform"], "ios")

    def test_platform_directive(self):
        state = company.new_state()
        self.assertIn("iPhone", company.platform_directive(state))
        state["config"]["platform"] = "macos"
        self.assertIn("macOS", company.platform_directive(state))
        state["config"]["platform"] = "ipados"
        self.assertIn("iPad", company.platform_directive(state))
        state["config"]["platform"] = "bogus"   # unknown → safe iPhone default
        self.assertIn("iPhone", company.platform_directive(state))

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

    def test_run_scout_feeds_back_user_complaints(self):
        state = company.new_state()
        state["asc_brief"] = 'Tabula 1★ "Sync broken": lost my data after the update'
        seen = {}
        def runner(role, prompt):
            seen["prompt"] = prompt
            return SCOUT_REPLY
        company.run_scout(state, runner)
        self.assertIn("REAL USER FEEDBACK", seen["prompt"])
        self.assertIn("Sync broken", seen["prompt"])

    def test_run_scout_omits_feedback_block_when_unconfigured(self):
        state = company.new_state()
        seen = {}
        def runner(role, prompt):
            seen["prompt"] = prompt
            return SCOUT_REPLY
        company.run_scout(state, runner)
        self.assertNotIn("REAL USER FEEDBACK", seen["prompt"])

    def test_run_scout_unparseable_returns_none(self):
        state = company.new_state()
        self.assertIsNone(company.run_scout(state, lambda r, p: "imagine no json"))
        self.assertEqual(state["initiatives"], [])


class BoardPacketPromptTests(unittest.TestCase):
    def test_prompt_is_cfo_with_sections_and_real_state(self):
        state = company.new_state()
        shipped = company.new_initiative("Quake App", "p")
        shipped["stage"] = "shipped"
        working = company.new_initiative("Trend Radar", "p")
        working["stage"] = "execution"
        gated = company.new_initiative("Focus Timer", "p")
        gated["stage"] = "gate1"
        state["initiatives"] = [shipped, working, gated]
        prompt = company.board_packet_prompt(state, "MRR: $412.00")
        self.assertIn("You are the CFO", prompt)
        for section in ("## Shipped", "## Revenue", "## Pipeline", "## Risks", "## Next Week"):
            self.assertIn(section, prompt)
        self.assertIn("Quake App", prompt)
        self.assertIn("Trend Radar (execution)", prompt)
        self.assertIn("Focus Timer", prompt)          # waiting on the Chairman
        self.assertIn("MRR: $412.00", prompt)
        self.assertIn("never invent", prompt)          # honesty instruction

    def test_prompt_is_honest_about_empty_company(self):
        prompt = company.board_packet_prompt(company.new_state(), "")
        self.assertIn("nothing yet", prompt)
        self.assertIn("not connected", prompt)

    def test_new_schedule_accepts_board_packet_kind(self):
        sched = company.new_schedule("Weekly board packet", "board_packet", "",
                                     "weekly", at_hour=18, at_minute=0, weekday=6)
        self.assertEqual(sched["kind"], "board_packet")
        self.assertEqual((sched["cadence"], sched["at_hour"], sched["weekday"]),
                         ("weekly", 18, 6))
        self.assertNotEqual(company.new_schedule("x", "bogus", "", "daily")["kind"],
                            "board_packet")           # unknown kinds still coerce


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


class DivisionCharterTests(unittest.TestCase):
    def test_new_initiative_has_division_and_live_url(self):
        init = company.new_initiative("A", "")
        self.assertEqual(init["division"], "")
        self.assertEqual(init["live_url"], "")

    def test_charters_are_data_with_the_required_shape(self):
        for div_id in ("webapps", "saas", "automations"):
            charter = company.DIVISION_CHARTERS[div_id]
            self.assertTrue(charter["name"], div_id)
            self.assertTrue(charter["output"], div_id)
            self.assertIn("DIVISION TOOLKIT", charter["toolkit"])
            gate = charter["gate"]
            self.assertTrue(gate["role"].endswith("_gate"), div_id)
            self.assertTrue(gate["title"], div_id)
            self.assertTrue(gate["prompt_intro"], div_id)
            self.assertTrue(charter["deliverable_hint"], div_id)
        # Ship-to-URL applies to the web divisions only.
        self.assertTrue(company.DIVISION_CHARTERS["webapps"]["deploy"])
        self.assertTrue(company.DIVISION_CHARTERS["saas"]["deploy"])
        self.assertFalse(company.DIVISION_CHARTERS["automations"]["deploy"])

    def test_ecommerce_charter_is_parked_and_minimal(self):
        charter = company.DIVISION_CHARTERS["ecommerce"]
        self.assertTrue(charter.get("parked"))
        self.assertEqual(charter["toolkit"], "")
        self.assertIsNone(charter["gate"])
        self.assertIn("parked", charter["output"])

    def test_saas_toolkit_offers_supabase_with_honest_fallback(self):
        toolkit = company.DIVISION_CHARTERS["saas"]["toolkit"]
        self.assertIn("Supabase", toolkit)
        self.assertIn("MCP", toolkit)
        self.assertIn("local storage", toolkit)

    def test_division_and_live_url_survive_the_store(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = company.CompanyStore(Path(tmp) / "company.json")
            state = company.new_state()
            init = company.new_initiative("Tip Calc", "")
            init["division"] = "webapps"
            init["live_url"] = "https://tip.vercel.app"
            state["initiatives"] = [init]
            store.save(state)
            loaded = store.load()["initiatives"][0]
            self.assertEqual(loaded["division"], "webapps")
            self.assertEqual(loaded["live_url"], "https://tip.vercel.app")


class DivisionPrefixTests(unittest.TestCase):
    def test_all_seven_ids_parse(self):
        for div_id in company.DIVISION_NAMES:
            division, text = company.parse_division_prefix(
                f"[{div_id} division] build a thing")
            self.assertEqual((division, text), (div_id, "build a thing"))

    def test_all_seven_display_names_parse(self):
        for div_id, name in company.DIVISION_NAMES.items():
            division, text = company.parse_division_prefix(
                f"[{name} division] do it well")
            self.assertEqual((division, text), (div_id, "do it well"), name)

    def test_case_insensitive_with_stray_whitespace(self):
        division, text = company.parse_division_prefix(
            "  [ webapps DIVISION ]   build a tip calculator")
        self.assertEqual((division, text), ("webapps", "build a tip calculator"))
        division, _ = company.parse_division_prefix(
            "[BUSINESS CONSULTING Division] pricing review")
        self.assertEqual(division, "consulting")

    def test_no_prefix_and_unknown_bay_leave_text_alone(self):
        self.assertEqual(company.parse_division_prefix("build a tip calculator"),
                         ("", "build a tip calculator"))
        self.assertEqual(company.parse_division_prefix("[Space Lasers division] pew"),
                         ("", "[Space Lasers division] pew"))
        self.assertEqual(company.parse_division_prefix(""), ("", ""))

    def test_seed_initiative_sets_division_and_strips_prefix(self):
        state = company.new_state()
        init = company.seed_initiative(
            state, "[Webapps division] build a tip calculator")
        self.assertEqual(init["division"], "webapps")
        self.assertEqual(init["pitch"], "build a tip calculator")
        self.assertEqual(init["title"], "build a tip calculator")
        self.assertTrue(any("[Webapps]" in e["text"] for e in state["events"]))

    def test_seed_initiative_without_prefix_stays_generic(self):
        state = company.new_state()
        init = company.seed_initiative(state, "build a tip calculator")
        self.assertEqual(init["division"], "")


class DivisionBuildPromptTests(unittest.TestCase):
    def setUp(self):
        self.state = company.new_state()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def _execution_init(self, directive):
        init = company.seed_initiative(self.state, directive)
        init["stage"] = "execution"
        return init

    def _advance_capturing(self, init):
        seen = {}

        def runner(role, prompt):
            seen[role] = prompt
            return "built"

        company.advance_stage(self.state, init, runner, self.root)
        return seen

    def test_charter_toolkit_replaces_platform_directive_in_build(self):
        init = self._execution_init("[Webapps division] tip calculator")
        seen = self._advance_capturing(init)
        self.assertIn("DIVISION TOOLKIT — Webapps", seen["builder"])
        self.assertNotIn("TARGET PLATFORM", seen["builder"])

    def test_generic_build_prompt_is_unchanged(self):
        init = self._execution_init("tip calculator")
        seen = self._advance_capturing(init)
        self.assertIn("TARGET PLATFORM", seen["builder"])
        self.assertNotIn("DIVISION TOOLKIT", seen["builder"])

    def test_toolkit_and_gate_feedback_ride_the_fix_prompt(self):
        init = self._execution_init("[Webapps division] tip calculator")
        init["exec_phase"] = "fix"
        init["division_gate"] = {"verdict": "REJECTED",
                                 "reasons": ["Dead buy button"]}
        init["minutes"] = [{"stage": "review", "role": "qa",
                            "text": "VERDICT: REVISE\n1. x", "ts": "t"}]
        seen = self._advance_capturing(init)
        self.assertIn("DIVISION TOOLKIT — Webapps", seen["builder"])
        self.assertIn("PREVIOUS ITERATION FEEDBACK", seen["builder"])
        self.assertIn("Dead buy button", seen["builder"])

    def test_rejection_feedback_reaches_the_next_build_turn(self):
        init = self._execution_init("[Workflow Automations division] inbox sorter")
        init["division_gate"] = {"verdict": "REJECTED",
                                 "reasons": ["README never got me to a run"]}
        seen = self._advance_capturing(init)
        self.assertIn("PREVIOUS ITERATION FEEDBACK", seen["builder"])
        self.assertIn("Reliability Gate", seen["builder"])
        self.assertIn("README never got me to a run", seen["builder"])


class DivisionGateTests(unittest.TestCase):
    def setUp(self):
        self.state = company.new_state()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.init = company.seed_initiative(
            self.state, "[Webapps division] tip calculator")
        self.outdir = self.root / company.initiative_dirname(self.init)
        self.outdir.mkdir(parents=True)
        (self.outdir / "index.html").write_text("<html>app</html>")

    def tearDown(self):
        self.tmp.cleanup()

    def advance(self, runner):
        company.advance_stage(self.state, self.init, runner, self.root)

    def test_qa_ship_routes_division_initiative_to_the_gate(self):
        self.init["stage"] = "execution"
        self.init["exec_phase"] = "review"
        self.advance(lambda r, p: "solid.\nVERDICT: SHIP")
        self.assertEqual(self.init["stage"], "division_gate")

    def test_parked_division_skips_the_gate(self):
        self.init["division"] = "ecommerce"
        self.init["stage"] = "execution"
        self.init["exec_phase"] = "review"
        self.advance(lambda r, p: "VERDICT: SHIP")
        self.assertEqual(self.init["stage"], "demo_ready")

    def test_gate_judge_gets_intro_files_and_verdict_contract(self):
        self.init["stage"] = "division_gate"
        seen = {}

        def runner(role, prompt):
            seen["role"], seen["prompt"] = role, prompt
            return "- clean\nGATE: APPROVED"

        with mock.patch.object(company, "find_vercel", return_value=None):
            self.advance(runner)
        self.assertEqual(seen["role"], "webapps_gate")
        self.assertIn("Ship Gate", seen["prompt"])
        self.assertIn("paying visitor", seen["prompt"])   # the charter's intro
        self.assertIn("index.html", seen["prompt"])       # deliverables listing
        self.assertIn("READ the files", seen["prompt"])
        self.assertIn("GATE: APPROVED", seen["prompt"])

    def test_gate_approved_moves_on_with_honest_deploy_skip(self):
        self.init["stage"] = "division_gate"
        with mock.patch.object(company, "find_vercel", return_value=None):
            self.advance(lambda r, p: "- great\nGATE: APPROVED")
        self.assertEqual(self.init["stage"], "demo_ready")
        self.assertEqual(self.init["division_gate"]["verdict"], "APPROVED")
        self.assertEqual(self.init["live_url"], "")
        self.assertTrue(any("deploy skipped" in e["text"]
                            for e in self.state["events"]))

    def test_gate_rejected_returns_to_execution_with_feedback(self):
        self.init["stage"] = "division_gate"
        self.advance(lambda r, p: "- Dead buttons everywhere\nGATE: REJECTED")
        self.assertEqual(self.init["stage"], "execution")
        self.assertEqual(self.init["exec_phase"], "fix")
        self.assertEqual(self.init["review_rounds"], 0)
        self.assertEqual(self.init["division_rejections"], 1)
        self.assertEqual(self.init["division_gate"]["verdict"], "REJECTED")
        self.assertEqual(self.init["division_gate"]["reasons"],
                         ["Dead buttons everywhere"])
        feedback = company.division_iteration_feedback(self.init)
        self.assertIn("Ship Gate rejected", feedback)
        self.assertIn("Dead buttons everywhere", feedback)

    def test_approval_clears_the_feedback_block(self):
        self.init["division_gate"] = {"verdict": "APPROVED", "reasons": []}
        self.assertEqual(company.division_iteration_feedback(self.init), "")

    def test_three_rejections_block_the_initiative_honestly(self):
        self.init["stage"] = "division_gate"
        self.init["division_rejections"] = company.MAX_DIVISION_REJECTIONS - 1
        self.advance(lambda r, p: "GATE: REJECTED")
        self.assertEqual(self.init["stage"], "blocked")
        self.assertIn("Ship Gate", self.init["note"])
        self.assertIn("owner", self.init["note"])

    def test_full_reject_fix_approve_loop(self):
        # gate REJECT → fix → QA SHIP → gate APPROVE → demo_ready.
        self.init["stage"] = "division_gate"
        verdicts = iter(["GATE: REJECTED\n- feels fake",
                         "GATE: APPROVED\n- fixed"])

        def runner(role, prompt):
            if role == "webapps_gate":
                return next(verdicts)
            if role == "qa":
                return "VERDICT: SHIP"
            return "reworked"

        with mock.patch.object(company, "find_vercel", return_value=None):
            self.advance(runner)                       # gate rejects
            self.assertEqual(self.init["stage"], "execution")
            self.advance(runner)                       # builder fixes
            self.advance(runner)                       # QA ships → back to gate
            self.assertEqual(self.init["stage"], "division_gate")
            self.advance(runner)                       # gate approves
        self.assertEqual(self.init["stage"], "demo_ready")
        self.assertEqual(self.init["division_gate"]["verdict"], "APPROVED")

    def test_gate_passed_later_marker_wins(self):
        self.assertTrue(company.gate_passed("x\nGATE: APPROVED"))
        self.assertFalse(company.gate_passed("GATE: REJECTED\nboring"))
        self.assertTrue(company.gate_passed("GATE: REJECTED\n…\nGATE: APPROVED"))
        self.assertFalse(company.gate_passed("no verdict here"))


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.state = company.new_state()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.init = company.seed_initiative(
            self.state, "[Webapps division] tip calculator")
        self.outdir = self.root / company.initiative_dirname(self.init)
        self.outdir.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def test_parse_vercel_url_takes_the_deployment_url(self):
        out = ("Vercel CLI 54.9.1\n"
               "Inspect: https://vercel.com/jamie/tip/dep_abc [2s]\n"
               "https://tip-calculator-abc123-jamie.vercel.app\n")
        self.assertEqual(company.parse_vercel_url(out),
                         "https://tip-calculator-abc123-jamie.vercel.app")
        self.assertEqual(company.parse_vercel_url("no urls here"), "")
        self.assertEqual(company.parse_vercel_url(""), "")

    def test_default_deploy_is_a_preview_not_production(self):
        completed = subprocess.CompletedProcess(
            [], 0, "https://tip-jamie.vercel.app\n", "Preview: deployed")
        with mock.patch.object(company, "find_vercel", return_value="/x/vercel"), \
                mock.patch.object(company, "run_killable",
                                  return_value=completed) as run:
            url = company.deploy_initiative(self.state, self.init, self.outdir)
        self.assertEqual(url, "https://tip-jamie.vercel.app")
        self.assertEqual(self.init["live_url"], url)
        self.assertTrue(any(e["text"].startswith("Preview at https://tip-jamie.vercel.app")
                            for e in self.state["events"]))
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["/x/vercel", "deploy", "--yes"])   # NO --prod pre-gate2
        self.assertEqual(kwargs["cwd"], str(self.outdir))

    def test_prod_deploy_promotes_after_the_owner_gate(self):
        completed = subprocess.CompletedProcess(
            [], 0, "https://tip-jamie.vercel.app\n", "Production: deployed")
        with mock.patch.object(company, "find_vercel", return_value="/x/vercel"), \
                mock.patch.object(company, "run_killable",
                                  return_value=completed) as run:
            url = company.deploy_initiative(self.state, self.init, self.outdir,
                                            prod=True)
        self.assertEqual(self.init["live_url"], url)
        self.assertTrue(any(e["text"].startswith("Live at https://tip-jamie.vercel.app")
                            for e in self.state["events"]))
        self.assertEqual(run.call_args[0][0], ["/x/vercel", "deploy", "--yes", "--prod"])

    def test_missing_vercel_is_an_honest_skip(self):
        with mock.patch.object(company, "find_vercel", return_value=None):
            url = company.deploy_initiative(self.state, self.init, self.outdir)
        self.assertEqual(url, "")
        self.assertEqual(self.init["live_url"], "")
        self.assertTrue(any("deploy skipped" in e["text"] and "vercel" in e["text"]
                            for e in self.state["events"]))

    def test_unauthed_vercel_is_an_honest_skip(self):
        completed = subprocess.CompletedProcess(
            [], 1, "", "Error: The specified token is not valid")
        with mock.patch.object(company, "find_vercel", return_value="/x/vercel"), \
                mock.patch.object(company, "run_killable", return_value=completed):
            url = company.deploy_initiative(self.state, self.init, self.outdir)
        self.assertEqual((url, self.init["live_url"]), ("", ""))
        self.assertTrue(any("vercel login" in e["text"]
                            for e in self.state["events"]))

    def test_deploy_timeout_is_an_honest_skip(self):
        def boom(command, timeout, cwd=None):
            raise subprocess.TimeoutExpired(cmd=command, timeout=timeout)

        with mock.patch.object(company, "find_vercel", return_value="/x/vercel"), \
                mock.patch.object(company, "run_killable", side_effect=boom):
            url = company.deploy_initiative(self.state, self.init, self.outdir)
        self.assertEqual((url, self.init["live_url"]), ("", ""))
        self.assertTrue(any("deploy skipped" in e["text"]
                            for e in self.state["events"]))

    def test_gate_approval_deploys_web_divisions_only(self):
        for directive, expected_calls in (
                ("[SaaS division] habit tracker", 1),
                ("[Workflow Automations division] inbox sorter", 0)):
            state = company.new_state()
            init = company.seed_initiative(state, directive)
            init["stage"] = "division_gate"
            (self.root / company.initiative_dirname(init)).mkdir(parents=True,
                                                                 exist_ok=True)
            with mock.patch.object(company, "deploy_initiative") as deploy:
                company.advance_stage(state, init,
                                      lambda r, p: "GATE: APPROVED", self.root)
            self.assertEqual(deploy.call_count, expected_calls, directive)
            self.assertEqual(init["stage"], "demo_ready")


class SpecialistCharterTests(unittest.TestCase):
    """Pass B: legal / accounting / consulting charters + code-side gate floors."""

    def test_specialist_charters_shape(self):
        expected = {
            "legal": ("counsel_gate", "Counsel Gate", company.check_legal_banner),
            "accounting": ("accuracy_gate", "Accuracy Gate", company.check_accounting_data),
            "consulting": ("evidence_gate", "Evidence Gate", company.check_consulting_sources),
        }
        for div_id, (role, title, check) in expected.items():
            charter = company.DIVISION_CHARTERS[div_id]
            self.assertEqual(charter["gate"]["role"], role)
            self.assertEqual(charter["gate"]["title"], title)
            self.assertIs(charter["check"], check)
            self.assertFalse(charter["deploy"], div_id)
            self.assertIn("DIVISION TOOLKIT", charter["toolkit"])
            self.assertTrue(charter["deliverable_hint"], div_id)

    def test_legal_toolkit_carries_banner_and_is_internal_only(self):
        toolkit = company.DIVISION_CHARTERS["legal"]["toolkit"]
        self.assertIn(company.LEGAL_BANNER, toolkit)     # dictated verbatim
        self.assertIn("NEVER client-facing", toolkit)
        self.assertIn("OWN products", toolkit)

    def test_accounting_toolkit_forbids_fabrication_and_requires_inputs(self):
        toolkit = company.DIVISION_CHARTERS["accounting"]["toolkit"]
        self.assertIn("NEVER invent", toolkit)
        self.assertIn("INPUTS", toolkit)
        self.assertIn(".xlsx or .csv", toolkit)

    def test_consulting_toolkit_requires_citations_and_sources(self):
        toolkit = company.DIVISION_CHARTERS["consulting"]["toolkit"]
        self.assertIn("citation", toolkit)
        self.assertIn("Sources", toolkit)
        self.assertIn("deep-research", toolkit)

    def test_gate_intros_demand_the_hard_checks(self):
        self.assertIn("disclaimer banner",
                      company.DIVISION_CHARTERS["legal"]["gate"]["prompt_intro"])
        self.assertIn("RE-COMPUTE",
                      company.DIVISION_CHARTERS["accounting"]["gate"]["prompt_intro"])
        self.assertIn("load-bearing",
                      company.DIVISION_CHARTERS["consulting"]["gate"]["prompt_intro"])


class CodeSideCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_legal_banner_present_passes(self):
        (self.dir / "privacy-policy.md").write_text(
            f"{company.LEGAL_BANNER}\n\n# Privacy Policy\nWe collect …")
        self.assertEqual(company.check_legal_banner(self.dir), "")

    def test_legal_banner_missing_names_the_file(self):
        (self.dir / "privacy-policy.md").write_text(
            f"{company.LEGAL_BANNER}\n\n# Privacy Policy")
        (self.dir / "terms.md").write_text("# Terms of Use\nno banner")
        reason = company.check_legal_banner(self.dir)
        self.assertIn("disclaimer banner", reason)
        self.assertIn("terms.md", reason)
        self.assertNotIn("privacy-policy.md", reason)

    def test_legal_no_documents_at_all_fails(self):
        self.assertIn("no legal documents", company.check_legal_banner(self.dir))

    def test_legal_check_ignores_hidden_dirs(self):
        (self.dir / "policy.md").write_text(f"{company.LEGAL_BANNER}\nok")
        demo = self.dir / ".demo"
        demo.mkdir()
        (demo / "README.md").write_text("screenshot notes — no banner")
        self.assertEqual(company.check_legal_banner(self.dir), "")

    def test_accounting_needs_a_data_artifact(self):
        self.assertEqual(company.check_accounting_data(self.dir),
                         "no verifiable data artifact")
        (self.dir / "summary.md").write_text("prose only, no table")
        self.assertEqual(company.check_accounting_data(self.dir),
                         "no verifiable data artifact")

    def test_accounting_csv_or_md_table_passes(self):
        (self.dir / "q2.csv").write_text("month,revenue\nJan,5")
        self.assertEqual(company.check_accounting_data(self.dir), "")
        (self.dir / "q2.csv").unlink()
        (self.dir / "summary.md").write_text(
            "## INPUTS\n\n| Month | Revenue |\n|---|---|\n| Jan | $5 |")
        self.assertEqual(company.check_accounting_data(self.dir), "")

    def test_consulting_needs_a_sources_section_in_the_main_report(self):
        self.assertIn("no report found", company.check_consulting_sources(self.dir))
        (self.dir / "report.md").write_text("Big claim with no citations. " * 50)
        self.assertIn("no Sources/References section",
                      company.check_consulting_sources(self.dir))
        # A Sources section in a SIDE note doesn't rescue the main report.
        (self.dir / "notes.md").write_text("## Sources\n1. https://example.com")
        self.assertIn("report.md", company.check_consulting_sources(self.dir))

    def test_consulting_sources_or_references_heading_passes(self):
        (self.dir / "report.md").write_text(
            "Market grew 12% [1].\n\n## Sources\n1. https://example.com/data")
        self.assertEqual(company.check_consulting_sources(self.dir), "")
        (self.dir / "report.md").write_text(
            "Claim [1].\n\nReferences:\n1. https://example.com")
        self.assertEqual(company.check_consulting_sources(self.dir), "")


class SpecialistGateTests(unittest.TestCase):
    """The three new gates through the actual stage machine, including the
    code-side auto-reject that never buys a judge turn."""

    def setUp(self):
        self.state = company.new_state()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def _gate_init(self, directive):
        init = company.seed_initiative(self.state, directive)
        init["stage"] = "division_gate"
        outdir = self.root / company.initiative_dirname(init)
        outdir.mkdir(parents=True)
        return init, outdir

    def _no_runner(self, role, prompt):
        self.fail("a code-side auto-reject must not buy a judge turn")

    def test_legal_missing_banner_auto_rejects_without_a_judge(self):
        init, outdir = self._gate_init("[Legal division] privacy policy for Tabula")
        (outdir / "privacy-policy.md").write_text("# Privacy Policy\nno banner")
        company.advance_stage(self.state, init, self._no_runner, self.root)
        self.assertEqual(init["stage"], "execution")
        self.assertEqual(init["division_gate"]["verdict"], "REJECTED")
        self.assertIn("disclaimer banner", init["division_gate"]["reasons"][0])
        self.assertIn("disclaimer banner",
                      company.division_iteration_feedback(init))

    def test_legal_with_banner_reaches_the_counsel_judge(self):
        init, outdir = self._gate_init("[Legal division] privacy policy for Tabula")
        (outdir / "privacy-policy.md").write_text(
            f"{company.LEGAL_BANNER}\n\n# Privacy Policy")
        seen = {}

        def runner(role, prompt):
            seen["role"], seen["prompt"] = role, prompt
            return "- clauses present\nGATE: APPROVED"

        company.advance_stage(self.state, init, runner, self.root)
        self.assertEqual(seen["role"], "counsel_gate")
        self.assertIn("Counsel Gate", seen["prompt"])
        self.assertEqual(init["stage"], "demo_ready")
        self.assertEqual(init["live_url"], "")   # legal never deploys

    def test_accounting_no_data_artifact_auto_rejects(self):
        init, outdir = self._gate_init("[Accounting division] Q2 revenue workbook")
        (outdir / "summary.md").write_text("prose only")
        company.advance_stage(self.state, init, self._no_runner, self.root)
        self.assertEqual(init["division_gate"]["reasons"],
                         ["no verifiable data artifact"])
        self.assertEqual(init["stage"], "execution")

    def test_accounting_with_csv_reaches_the_accuracy_judge(self):
        init, outdir = self._gate_init("[Accounting division] Q2 revenue workbook")
        (outdir / "q2.csv").write_text("month,revenue\nJan,5")
        seen = {}

        def runner(role, prompt):
            seen["role"], seen["prompt"] = role, prompt
            return "- totals recompute clean\nGATE: APPROVED"

        company.advance_stage(self.state, init, runner, self.root)
        self.assertEqual(seen["role"], "accuracy_gate")
        self.assertIn("RE-COMPUTE", seen["prompt"])
        self.assertEqual(init["stage"], "demo_ready")

    def test_consulting_no_sources_auto_rejects(self):
        init, outdir = self._gate_init("[Business Consulting division] market study")
        (outdir / "report.md").write_text("Uncited claims everywhere.")
        company.advance_stage(self.state, init, self._no_runner, self.root)
        self.assertEqual(init["stage"], "execution")
        self.assertIn("no Sources/References section",
                      init["division_gate"]["reasons"][0])

    def test_consulting_with_sources_judge_can_still_reject(self):
        init, outdir = self._gate_init("[Business Consulting division] market study")
        (outdir / "report.md").write_text(
            "Market grew 12% [1].\n\n## Sources\n1. https://example.com")
        company.advance_stage(
            self.state, init,
            lambda r, p: "- claim [1] not supported by its source\nGATE: REJECTED",
            self.root)
        self.assertEqual(init["stage"], "execution")
        self.assertEqual(init["division_gate"]["verdict"], "REJECTED")

    def test_auto_rejects_count_toward_the_three_strikes(self):
        init, outdir = self._gate_init("[Legal division] terms of use")
        (outdir / "terms.md").write_text("no banner")
        init["division_rejections"] = company.MAX_DIVISION_REJECTIONS - 1
        company.advance_stage(self.state, init, self._no_runner, self.root)
        self.assertEqual(init["stage"], "blocked")
        self.assertIn("Counsel Gate", init["note"])


class DivisionsSummaryTests(unittest.TestCase):
    def test_all_eight_in_stable_order_with_zeros(self):
        summary = company.divisions_summary(company.new_state())
        self.assertEqual([d["id"] for d in summary],
                         ["webapps", "saas", "ecommerce", "automations",
                          "consulting", "accounting", "legal", "growth"])
        self.assertEqual([d["name"] for d in summary],
                         ["Webapps", "SaaS", "E-Commerce", "Workflow Automations",
                          "Business Consulting", "Accounting", "Legal", "Growth"])
        for division in summary:
            self.assertEqual((division["active"], division["shipped"],
                              division["live_urls"], division["calls"],
                              division["est_cost"], division["rejections"]),
                             (0, 0, [], 0, 0.0, 0))

    def test_pnl_cost_estimate_uses_the_config_knob(self):
        state = company.new_state()
        state["config"]["cost_per_call"] = 0.25
        init = company.new_initiative("Tip Calc", "")
        init["division"] = "webapps"
        init["calls_used"] = 8
        init["division_rejections"] = 2
        state["initiatives"] = [init]
        by_id = {d["id"]: d for d in company.divisions_summary(state)}
        self.assertEqual((by_id["webapps"]["calls"], by_id["webapps"]["est_cost"],
                          by_id["webapps"]["rejections"]), (8, 2.0, 2))

    def test_counts_and_live_urls_roll_up_per_division(self):
        state = company.new_state()
        building = company.new_initiative("Tip Calc", "")
        building["division"] = "webapps"
        building["stage"] = "execution"
        live = company.new_initiative("Live Site", "")
        live["division"] = "webapps"
        live["stage"] = "shipped"
        live["live_url"] = "https://tip.vercel.app"
        dead = company.new_initiative("Dead Legal", "")
        dead["division"] = "legal"
        dead["stage"] = "killed"
        untagged = company.new_initiative("Generic", "")
        state["initiatives"] = [building, live, dead, untagged]
        by_id = {d["id"]: d for d in company.divisions_summary(state)}
        self.assertEqual((by_id["webapps"]["active"], by_id["webapps"]["shipped"]),
                         (1, 1))
        self.assertEqual(by_id["webapps"]["live_urls"], ["https://tip.vercel.app"])
        self.assertEqual((by_id["legal"]["active"], by_id["legal"]["shipped"],
                          by_id["legal"]["live_urls"]), (0, 0, []))
        self.assertEqual((by_id["saas"]["active"], by_id["saas"]["shipped"]), (0, 0))


class LessonTests(unittest.TestCase):
    """Institutional memory: ended initiatives leave post-mortems the next
    prompts read back — initiative #40 must be smarter than #1."""

    def _ended(self, stage="killed", division="webapps"):
        init = company.new_initiative("Tip Calc", "a calculator")
        init["stage"] = stage
        init["division"] = division
        init["calls_used"] = 12
        init["review_rounds"] = 3
        return init

    def test_kill_at_gate_records_a_lesson(self):
        state = company.new_state()
        init = company.new_initiative("Tip Calc", "")
        init["stage"] = "gate2"
        state["initiatives"] = [init]
        company.apply_gate(state, init["id"], "kill", "owner passed")
        self.assertEqual(len(state["lessons"]), 1)
        lesson = state["lessons"][0]
        self.assertEqual((lesson["outcome"], lesson["initiative_id"]),
                         ("killed", init["id"]))
        self.assertIn("owner passed", lesson["text"])

    def test_ship_approval_records_a_lesson_too(self):
        state = company.new_state()
        init = company.new_initiative("Tip Calc", "")
        init["stage"] = "gate2"
        state["initiatives"] = [init]
        company.apply_gate(state, init["id"], "approve")
        self.assertEqual(state["lessons"][0]["outcome"], "shipped")

    def test_gate1_approve_records_nothing(self):
        state = company.new_state()
        init = company.new_initiative("Tip Calc", "")
        init["stage"] = "gate1"
        state["initiatives"] = [init]
        company.apply_gate(state, init["id"], "approve")
        self.assertEqual(state["lessons"], [])

    def test_lesson_carries_the_gate_rejection_reasons(self):
        init = self._ended(stage="blocked")
        init["division_rejections"] = 3
        init["division_gate"] = {"verdict": "REJECTED",
                                 "reasons": ["dead buttons", "no persistence"]}
        text = company.compose_lesson(init)
        self.assertIn("Ship Gate", text)
        self.assertIn("dead buttons", text)
        self.assertIn("×3", text)

    def test_record_lesson_dedupes_by_initiative(self):
        state = company.new_state()
        init = self._ended()
        company.record_lesson(state, init)
        init["stage"] = "blocked"
        company.record_lesson(state, init)
        self.assertEqual(len(state["lessons"]), 1)
        self.assertEqual(state["lessons"][0]["outcome"], "blocked")

    def test_lessons_block_prefers_the_matching_division(self):
        state = company.new_state()
        for n, division in enumerate(["legal", "webapps", "saas", "webapps"]):
            init = self._ended(division=division)
            init["id"] = f"i{n}"
            init["title"] = f"{division}-{n}"
            company.record_lesson(state, init)
        block = company.lessons_block(state, "webapps", cap=2)
        self.assertIn("webapps-3", block)
        self.assertIn("webapps-1", block)
        self.assertNotIn("legal-0", block)
        self.assertEqual(company.lessons_block(company.new_state()), "")

    def test_scout_and_planning_prompts_carry_lessons(self):
        state = company.new_state()
        state["enabled"] = True
        company.record_lesson(state, self._ended())
        prompts = []

        def runner(role, prompt):
            prompts.append(prompt)
            return '{"ideas": []}'
        company.run_scout(state, runner)
        init = company.new_initiative("Next", "")
        init["stage"] = "planning"
        state["initiatives"].append(init)
        with tempfile.TemporaryDirectory() as tmp:
            company.advance_stage(state, init, runner, Path(tmp))
        self.assertTrue(all("LESSONS FROM PAST INITIATIVES" in p for p in prompts))

    def test_tick_blocked_lesson_survives_the_merge(self):
        import json as jsonlib
        current = company.new_state()
        before = jsonlib.loads(jsonlib.dumps(current))
        ticked = jsonlib.loads(jsonlib.dumps(current))
        company.record_lesson(ticked, self._ended(stage="blocked"))
        merged = company.merge_tick_results(current, ticked, before)
        self.assertEqual(len(merged["lessons"]), 1)


class PortfolioAdoptionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "TipApp"
        self.repo.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_adopt_binds_the_existing_repo_and_skips_the_theater(self):
        state = company.new_state()
        init = company.adopt_portfolio(state, str(self.repo), division="webapps")
        self.assertEqual(init["stage"], "planning")
        self.assertEqual(init["workdir"], str(self.repo))
        self.assertEqual(init["division"], "webapps")
        self.assertEqual(init["origin"], "owner")
        self.assertIn("TipApp", init["title"])
        self.assertTrue(any("adopted into the portfolio" in e["text"]
                            for e in state["events"]))

    def test_adopt_rejects_a_missing_path(self):
        with self.assertRaises(ValueError):
            company.adopt_portfolio(company.new_state(), str(self.repo / "nope"))

    def test_outdir_prefers_the_workdir(self):
        init = company.new_initiative("Portfolio: TipApp", "")
        root = Path("/tmp/artifacts")
        self.assertEqual(company.initiative_outdir(init, root),
                         root / company.initiative_dirname(init))
        init["workdir"] = str(self.repo)
        self.assertEqual(company.initiative_outdir(init, root), self.repo)

    def test_execution_works_inside_the_adopted_repo(self):
        state = company.new_state()
        init = company.adopt_portfolio(state, str(self.repo))
        init["stage"] = "execution"
        (self.repo / "main.swift").write_text("// existing code")
        seen = {}

        def runner(role, prompt):
            seen["prompt"] = prompt
            return "extended the app"
        company.advance_stage(state, init, runner, Path(self.tmp.name) / "other")
        self.assertIn(str(self.repo), seen["prompt"])
        self.assertIn("main.swift", seen["prompt"])   # resumed, not rebuilt


class GrowthCharterTests(unittest.TestCase):
    def test_growth_charter_shape(self):
        charter = company.DIVISION_CHARTERS["growth"]
        self.assertEqual(charter["gate"]["role"], "conversion_gate")
        self.assertEqual(charter["gate"]["title"], "Conversion Gate")
        self.assertTrue(charter["deploy"])   # landing pages get preview URLs

    def test_growth_toolkit_never_posts_and_never_lies(self):
        toolkit = company.DIVISION_CHARTERS["growth"]["toolkit"]
        self.assertIn("NEVER post", toolkit)
        self.assertIn("DRAFT", toolkit)
        self.assertIn("TRUE of the actual product", toolkit)
        intro = company.DIVISION_CHARTERS["growth"]["gate"]["prompt_intro"]
        self.assertIn("invented testimonial", intro)
        self.assertIn("DRAFT", intro)

    def test_growth_prefix_parses(self):
        division, rest = company.parse_division_prefix(
            "[Growth division] launch kit for Tip Calc")
        self.assertEqual((division, rest), ("growth", "launch kit for Tip Calc"))


class OnceScheduleTests(unittest.TestCase):
    """cadence 'once' — how a calendar-scheduled meeting actually convenes."""

    def test_once_fires_exactly_once_at_its_time(self):
        now = time.time()
        sched = company.new_schedule("Q3 kickoff", "meeting", "Q3 kickoff",
                                     "once", at_ts=now + 60)
        self.assertFalse(company.schedule_due(sched, now))          # not yet
        self.assertTrue(company.schedule_due(sched, now + 61))      # at time: due
        sched["last_fired"] = now + 61                              # runner fired it
        self.assertFalse(company.schedule_due(sched, now + 3600))   # never again

    def test_once_without_a_time_never_fires(self):
        sched = company.new_schedule("t", "meeting", "t", "once")
        self.assertFalse(company.schedule_due(sched, time.time() + 9e6))


class TurnCapTests(unittest.TestCase):
    def _state_with_actives(self, n):
        state = company.new_state()
        state["enabled"] = True
        state["config"]["quiet_start"] = state["config"]["quiet_end"] = 0
        state["last_tick"] = time.time()   # no scouting during the test
        for i in range(n):
            init = company.new_initiative(f"P{i}", "")
            init["id"] = f"i{i}"
            init["stage"] = "research"
            state["initiatives"].append(init)
        return state

    def test_tick_advances_at_most_the_cap_and_rotates(self):
        state = self._state_with_actives(4)
        state["config"]["max_turns_per_tick"] = 2
        advanced = []

        def runner(role, prompt):
            return "memo"
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(company, "machine_overloaded", return_value=False):
            events = company.tick(state, runner, Path(tmp))
            advanced.extend(e.split()[0] for e in events if "advanced" in e)
            events = company.tick(state, runner, Path(tmp))
            advanced.extend(e.split()[0] for e in events if "advanced" in e)
        self.assertEqual(advanced, ["i0", "i1", "i2", "i3"])   # fair rotation


if __name__ == "__main__":
    unittest.main()
