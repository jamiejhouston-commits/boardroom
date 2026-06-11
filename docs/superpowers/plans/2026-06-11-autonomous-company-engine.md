# Autonomous Company Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A heartbeat-driven engine on the Mac relay where the agent org autonomously scouts market trends, debates initiatives in a boardroom, builds real deliverables, and pauses at two owner decision gates — exposed over the relay's HTTP API so the iOS app can show briefs and one-tap approve/kill.

**Architecture:** A pure-Python state machine (`Scripts/hermes_company.py`) operating on a JSON state file. Every stage transition is driven by `tick()`, called by a heartbeat thread inside the existing relay process (`Scripts/hermes_mobile_relay.py`). All LLM work goes through an injected `runner(role, prompt) -> str` callable, so the entire pipeline is unit-testable with fakes and only Task 8 touches the real Hermes CLI. Initiative pipeline: `research → boardroom → gate1(owner) → planning → execution → demo_ready → gate2(owner) → shipped`, with `killed` reachable from gates, budget exhaustion, or errors.

**Tech Stack:** Python 3.11+ stdlib only (json, threading, re, dataclasses-free plain dicts), `unittest` (matches existing `test_hermes_mobile_relay.py` conventions), Hermes CLI via subprocess (existing relay helpers).

**State file:** `~/.hermes/mobile-company.json` (path injectable for tests). Artifacts: `~/.hermes/company/initiatives/<id>/`.

**Phase 2 (separate plan):** iOS Boardroom tab — initiative cards, gate buttons, Demo Day → MeetingHub/EventKit invite, BGAppRefresh polling + local notifications. Do NOT start it from this plan.

---

### Task 1: Company state store + model

**Files:**
- Create: `Scripts/hermes_company.py`
- Test: `Scripts/test_hermes_company.py`

- [ ] **Step 1: Write the failing tests**

```python
# Scripts/test_hermes_company.py
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


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd "/Users/chosenvessel/Documents/hermes ios" && python3 -m unittest Scripts.test_hermes_company -v 2>&1 | tail -5`
(If module-path import fails, run as: `python3 Scripts/test_hermes_company.py -v`)
Expected: FAIL / error — `hermes_company.py` does not exist.

- [ ] **Step 3: Write the implementation**

```python
# Scripts/hermes_company.py
"""Autonomous company engine for Hermes Mobile.

A heartbeat-driven pipeline: the org scouts market trends, debates
initiatives in a boardroom, builds real deliverables via Hermes agents,
and pauses at two owner decision gates. All LLM calls go through an
injected runner(role, prompt) -> str so everything is testable offline.
"""

from __future__ import annotations

import json
import re
import secrets
import time
from datetime import datetime
from pathlib import Path

DEFAULT_CONFIG = {
    "interval_minutes": 30,
    "quiet_start": 22,   # 10pm
    "quiet_end": 7,      # 7am
    "max_active": 1,
    "budget_calls": 40,
    "scout_sources": "Hacker News, Product Hunt, GitHub trending, App Store charts, Reddit",
}

GATE_STAGES = ("gate1", "gate2")
TERMINAL_STAGES = ("shipped", "killed")


def new_state() -> dict:
    return {
        "enabled": False,
        "thesis": "",
        "config": dict(DEFAULT_CONFIG),
        "initiatives": [],
        "last_tick": 0.0,
    }


def new_initiative(title: str, pitch: str, score: dict | None = None) -> dict:
    return {
        "id": secrets.token_hex(4),
        "title": title,
        "pitch": pitch,
        "stage": "research",
        "created": datetime.now().isoformat(timespec="seconds"),
        "score": score or {},
        "calls_used": 0,
        "brief": "",
        "minutes": [],    # [{"stage":..., "role":..., "text":..., "ts":...}]
        "artifacts": [],  # file paths produced during execution
        "note": "",
    }


class CompanyStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> dict:
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text())
                if isinstance(data, dict) and "initiatives" in data:
                    base = new_state()
                    base.update(data)
                    merged = dict(DEFAULT_CONFIG)
                    merged.update(base.get("config") or {})
                    base["config"] = merged
                    return base
            except json.JSONDecodeError:
                pass
        return new_state()

    def save(self, state: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(state, indent=2))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd "/Users/chosenvessel/Documents/hermes ios" && python3 Scripts/test_hermes_company.py -v 2>&1 | tail -5`
Expected: `OK`, 4 tests passed.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chosenvessel/Documents/hermes ios"
git add Scripts/hermes_company.py Scripts/test_hermes_company.py docs/superpowers/plans/2026-06-11-autonomous-company-engine.md
git commit -m "feat(company): state store and initiative model"
```

---

### Task 2: Guardrails — quiet hours, capacity, budget

**Files:**
- Modify: `Scripts/hermes_company.py` (append)
- Test: `Scripts/test_hermes_company.py` (append)

- [ ] **Step 1: Write the failing tests** (append to `Scripts/test_hermes_company.py`, above the `__main__` block)

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 Scripts/test_hermes_company.py -v 2>&1 | tail -5`
Expected: FAIL — `is_quiet` etc. not defined.

- [ ] **Step 3: Write the implementation** (append to `Scripts/hermes_company.py`)

```python
class BudgetExceeded(Exception):
    pass


def is_quiet(hour: int, start: int, end: int) -> bool:
    if start == end:
        return False
    if start > end:  # overnight window, e.g. 22 → 7
        return hour >= start or hour < end
    return start <= hour < end


def active(state: dict) -> list[dict]:
    return [i for i in state["initiatives"] if i["stage"] not in TERMINAL_STAGES]


def working(state: dict) -> list[dict]:
    return [i for i in active(state) if i["stage"] not in GATE_STAGES]


def make_charged_runner(initiative: dict, budget: int, runner):
    def charged(role: str, prompt: str) -> str:
        if initiative["calls_used"] >= budget:
            raise BudgetExceeded(f"{initiative['id']} exhausted {budget} calls")
        initiative["calls_used"] += 1
        return runner(role, prompt)
    return charged
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 Scripts/test_hermes_company.py -v 2>&1 | tail -3`
Expected: `OK`, 9 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Scripts/hermes_company.py Scripts/test_hermes_company.py
git commit -m "feat(company): quiet hours, capacity partitions, call budget"
```

---

### Task 3: Market Scout — prompt + idea parsing + initiative creation

**Files:**
- Modify: `Scripts/hermes_company.py` (append)
- Test: `Scripts/test_hermes_company.py` (append)

- [ ] **Step 1: Write the failing tests** (append)

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 Scripts/test_hermes_company.py -v 2>&1 | tail -3`
Expected: FAIL — `parse_ideas` not defined.

- [ ] **Step 3: Write the implementation** (append)

```python
ROLE_SOULS = {
    "research": "You are the Head of Research of an autonomous AI product company. You scout markets with evidence, never hype.",
    "cfo": "You are the CFO. You weigh cost, monetization, and opportunity cost. You are the board's skeptic.",
    "cto": "You are the CTO. You judge technical feasibility, scope, and how fast a small team can ship.",
    "marketing": "You are the Head of Marketing. You judge demand, distribution channels, and how the product gets users.",
    "ceo": "You are the CEO. You chair the board, weigh dissent honestly, and decide. You report to the owner (the human Chairman).",
    "builder": "You are the Lead Builder. You produce real deliverables — files, code, docs — not descriptions of them.",
}

SCOUT_JSON_SPEC = (
    'Respond with STRICT JSON only, exactly this shape: '
    '{"ideas": [{"title": "...", "pitch": "one sentence", "heat": 1, "fit": 1, '
    '"effort": 1, "rationale": "..."}]} '
    "— heat = market momentum 1-10, fit = match to our thesis 1-10, "
    "effort = build cost 1-10 (lower is easier). Up to 3 ideas."
)


def role_prompt(role: str, body: str) -> str:
    return f"{ROLE_SOULS[role]}\n\n{body}"


def parse_ideas(text: str) -> list[dict]:
    match = re.search(r"\{.*\}", text, re.S)
    if not match:
        return []
    try:
        data = json.loads(match.group(0))
    except json.JSONDecodeError:
        return []
    ideas = data.get("ideas") if isinstance(data, dict) else None
    if not isinstance(ideas, list):
        return []
    return [i for i in ideas if isinstance(i, dict) and i.get("title")]


def idea_score(idea: dict) -> int:
    def num(key):
        value = idea.get(key, 0)
        return value if isinstance(value, (int, float)) else 0
    return num("heat") + num("fit") - num("effort")


def run_scout(state: dict, runner) -> dict | None:
    thesis = state.get("thesis") or "small, useful products that ship in days"
    sources = state["config"].get("scout_sources", DEFAULT_CONFIG["scout_sources"])
    body = (
        f"Scan current market trends across: {sources}. "
        f"The owner's standing investment thesis: {thesis}. "
        f"Avoid re-pitching ideas similar to past initiatives: "
        f"{[i['title'] for i in state['initiatives']][:20]}. "
        f"Propose buildable product opportunities. {SCOUT_JSON_SPEC}"
    )
    ideas = parse_ideas(runner("research", role_prompt("research", body)))
    if not ideas:
        return None
    best = max(ideas, key=idea_score)
    initiative = new_initiative(
        str(best["title"]),
        str(best.get("pitch", "")),
        score={k: best.get(k) for k in ("heat", "fit", "effort", "rationale")},
    )
    state["initiatives"].insert(0, initiative)
    return initiative
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 Scripts/test_hermes_company.py -v 2>&1 | tail -3`
Expected: `OK`, 14 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Scripts/hermes_company.py Scripts/test_hermes_company.py
git commit -m "feat(company): market scout with thesis filter and idea scoring"
```

---

### Task 4: Stage machine — research, boardroom, planning, execution, demo

**Files:**
- Modify: `Scripts/hermes_company.py` (append)
- Test: `Scripts/test_hermes_company.py` (append)

- [ ] **Step 1: Write the failing tests** (append)

```python
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

    def test_execution_collects_artifacts_and_moves_to_demo_ready(self):
        self.init["stage"] = "execution"
        outdir = self.root / self.init["id"]
        def runner(role, prompt):
            outdir.mkdir(parents=True, exist_ok=True)
            (outdir / "report.md").write_text("done")
            return "Created report.md"
        self.advance(runner)
        self.assertEqual(self.init["stage"], "demo_ready")
        self.assertEqual(len(self.init["artifacts"]), 1)
        self.assertTrue(self.init["artifacts"][0].endswith("report.md"))

    def test_demo_ready_writes_invite_brief_and_moves_to_gate2(self):
        self.init["stage"] = "demo_ready"
        self.advance(lambda r, p: "Demo Day: we built Trend Radar.")
        self.assertEqual(self.init["stage"], "gate2")
        self.assertIn("Demo Day", self.init["brief"])
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 Scripts/test_hermes_company.py -v 2>&1 | tail -3`
Expected: FAIL — `advance_stage` not defined.

- [ ] **Step 3: Write the implementation** (append)

```python
def log_minute(initiative: dict, stage: str, role: str, text: str) -> None:
    initiative["minutes"].append({
        "stage": stage,
        "role": role,
        "text": text.strip(),
        "ts": datetime.now().isoformat(timespec="seconds"),
    })


def last_text(initiative: dict, stage: str) -> str:
    for entry in reversed(initiative["minutes"]):
        if entry["stage"] == stage:
            return entry["text"]
    return ""


def advance_stage(state: dict, init: dict, runner, artifacts_root: Path) -> None:
    """Advance one initiative by exactly one stage. Gates are no-ops here —
    they advance only via apply_gate (the owner's decision)."""
    stage = init["stage"]

    if stage == "research":
        reply = runner("research", role_prompt("research",
            f"Initiative: {init['title']} — {init['pitch']}.\n"
            "Produce a focused research memo: market, competitors, target user, "
            "risks, and a recommended scope a tiny team ships in days. Be concrete."))
        log_minute(init, "research", "research", reply)
        init["stage"] = "boardroom"

    elif stage == "boardroom":
        transcript = ""
        memo = last_text(init, "research")
        for role in ("cfo", "cto", "marketing"):
            reply = runner(role, role_prompt(role,
                f"Boardroom review of: {init['title']} — {init['pitch']}.\n"
                f"Research memo:\n{memo}\n\nDebate so far:\n{transcript}\n"
                "Give your honest position in 3-5 sentences: support or oppose, and why. "
                "Disagree openly when warranted."))
            log_minute(init, "boardroom", role, reply)
            transcript += f"\n{role.upper()}: {reply}"
        verdict = runner("ceo", role_prompt("ceo",
            f"Initiative: {init['title']}.\nBoard debate:\n{transcript}\n"
            "Write a 5-line decision brief for the owner: WHAT we'd build, WHY now, "
            "WHO works on it, EFFORT estimate, and any board dissent. "
            "End with your recommendation: GREENLIGHT or PASS."))
        log_minute(init, "boardroom", "ceo", verdict)
        init["brief"] = verdict.strip()
        init["stage"] = "gate1"

    elif stage == "planning":
        note = f" The owner added: {init['note']}." if init["note"] else ""
        reply = runner("ceo", role_prompt("ceo",
            f"The owner GREENLIT '{init['title']}'.{note}\n"
            f"Research memo:\n{last_text(init, 'research')}\n"
            "Write concrete work orders for the build team: numbered deliverables "
            "with acceptance criteria. Only what ships in days."))
        log_minute(init, "planning", "ceo", reply)
        init["stage"] = "execution"

    elif stage == "execution":
        outdir = artifacts_root / init["id"]
        outdir.mkdir(parents=True, exist_ok=True)
        reply = runner("builder", role_prompt("builder",
            f"Execute these work orders for '{init['title']}'. "
            f"Save EVERY deliverable as a real file under {outdir} using your file tools.\n"
            f"Work orders:\n{last_text(init, 'planning')}\n"
            "When done, list each file you created with a one-line summary."))
        log_minute(init, "execution", "builder", reply)
        init["artifacts"] = sorted(
            str(p) for p in outdir.rglob("*") if p.is_file())
        init["stage"] = "demo_ready"

    elif stage == "demo_ready":
        files = "\n".join(init["artifacts"]) or "(no files recorded)"
        reply = runner("ceo", role_prompt("ceo",
            f"The team finished '{init['title']}'. Deliverables:\n{files}\n"
            f"Builder's report:\n{last_text(init, 'execution')}\n"
            "Write the Demo Day invitation for the owner: what was built, "
            "3 highlights, and the ship/no-ship question. 6 lines max."))
        log_minute(init, "demo", "ceo", reply)
        init["brief"] = reply.strip()
        init["stage"] = "gate2"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 Scripts/test_hermes_company.py -v 2>&1 | tail -3`
Expected: `OK`, 19 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Scripts/hermes_company.py Scripts/test_hermes_company.py
git commit -m "feat(company): five-stage pipeline with boardroom debate and real artifacts"
```

---

### Task 5: Owner decision gates

**Files:**
- Modify: `Scripts/hermes_company.py` (append)
- Test: `Scripts/test_hermes_company.py` (append)

- [ ] **Step 1: Write the failing tests** (append)

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 Scripts/test_hermes_company.py -v 2>&1 | tail -3`
Expected: FAIL — `apply_gate` not defined.

- [ ] **Step 3: Write the implementation** (append)

```python
def find_initiative(state: dict, initiative_id: str) -> dict:
    for init in state["initiatives"]:
        if init["id"] == initiative_id:
            return init
    raise KeyError(initiative_id)


def apply_gate(state: dict, initiative_id: str, decision: str, note: str = "") -> dict:
    init = find_initiative(state, initiative_id)
    if init["stage"] not in GATE_STAGES:
        raise ValueError(f"initiative {initiative_id} is not awaiting a decision")
    if decision not in ("approve", "kill", "revise"):
        raise ValueError(f"unknown decision: {decision}")
    init["note"] = note
    at_gate1 = init["stage"] == "gate1"
    if decision == "kill":
        init["stage"] = "killed"
    elif decision == "approve":
        init["stage"] = "planning" if at_gate1 else "shipped"
    else:  # revise
        init["stage"] = "research" if at_gate1 else "execution"
    return init
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 Scripts/test_hermes_company.py -v 2>&1 | tail -3`
Expected: `OK`, 25 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Scripts/hermes_company.py Scripts/test_hermes_company.py
git commit -m "feat(company): chairman decision gates (approve/kill/revise)"
```

---

### Task 6: tick() — the heartbeat brain

**Files:**
- Modify: `Scripts/hermes_company.py` (append)
- Test: `Scripts/test_hermes_company.py` (append)

- [ ] **Step 1: Write the failing tests** (append)

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 Scripts/test_hermes_company.py -v 2>&1 | tail -3`
Expected: FAIL — `tick` not defined.

- [ ] **Step 3: Write the implementation** (append)

```python
def tick(state: dict, runner, artifacts_root: Path, now: float | None = None) -> list[str]:
    """One heartbeat: advance every working initiative one stage, then scout
    if there's capacity. Returns human-readable event strings."""
    now = now if now is not None else time.time()
    config = state["config"]
    if not state["enabled"]:
        return []
    hour = datetime.fromtimestamp(now).hour
    if is_quiet(hour, config["quiet_start"], config["quiet_end"]):
        return []
    if now - state["last_tick"] < config["interval_minutes"] * 60:
        return []
    state["last_tick"] = now

    events: list[str] = []
    for init in list(working(state)):
        charged = make_charged_runner(init, config["budget_calls"], runner)
        try:
            advance_stage(state, init, charged, artifacts_root)
            events.append(f"{init['id']} advanced to {init['stage']}")
        except BudgetExceeded:
            init["stage"] = "killed"
            init["note"] = "token budget exhausted"
            events.append(f"{init['id']} killed: budget exhausted")
        except Exception as error:  # noqa: BLE001 — one bad turn must not stop the pulse
            init["note"] = f"stalled: {error}"
            events.append(f"{init['id']} stalled: {error}")

    if len(active(state)) < config["max_active"]:
        try:
            scouted = run_scout(state, runner)
        except Exception as error:  # noqa: BLE001
            scouted = None
            events.append(f"scout failed: {error}")
        if scouted is not None:
            events.append(f"scouted new initiative {scouted['id']}: {scouted['title']}")
    return events
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 Scripts/test_hermes_company.py -v 2>&1 | tail -3`
Expected: `OK`, 33 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Scripts/hermes_company.py Scripts/test_hermes_company.py
git commit -m "feat(company): heartbeat tick with guardrails and crash isolation"
```

---

### Task 7: Relay HTTP endpoints + heartbeat thread

**Files:**
- Modify: `Scripts/hermes_mobile_relay.py`
- Test: `Scripts/test_hermes_mobile_relay.py` (append)

- [ ] **Step 1: Write the failing tests** (append to `Scripts/test_hermes_mobile_relay.py`, inside a new class)

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 Scripts/test_hermes_mobile_relay.py -v 2>&1 | tail -3`
Expected: FAIL — `company_chat_command` not defined.

- [ ] **Step 3: Write the implementation.** In `Scripts/hermes_mobile_relay.py`:

**3a.** Below the existing imports, load the company module and define shared state:

```python
import importlib.util
import threading

_COMPANY_SPEC = importlib.util.spec_from_file_location(
    "hermes_company", Path(__file__).with_name("hermes_company.py"))
company_module = importlib.util.module_from_spec(_COMPANY_SPEC)
assert _COMPANY_SPEC.loader is not None
_COMPANY_SPEC.loader.exec_module(company_module)

COMPANY_STATE_PATH = Path.home() / ".hermes" / "mobile-company.json"
COMPANY_ARTIFACTS_ROOT = Path.home() / ".hermes" / "company" / "initiatives"
COMPANY_LOCK = threading.Lock()
```

**3b.** Below `chat_command(...)`, add the company runner and summary helpers:

```python
def company_chat_command(message: str, role: str, resume_session_id: str | None) -> list[str]:
    command = ["hermes", "chat", "-Q", "--source", "mobile"]
    if resume_session_id:
        command.extend(["--resume", resume_session_id])
    command.extend(["-q", message])
    return command


def company_cli_runner(role: str, prompt: str) -> str:
    """runner(role, prompt) for the company engine: one Hermes CLI call per
    turn, with a persistent session per role so agents keep their memory."""
    store = RelayConfigStore(CONFIG_PATH)
    session_key = f"company-{role}"
    resume = store.session_id("default", session_key)
    result = subprocess.run(
        company_chat_command(prompt, role, resume),
        text=True, capture_output=True, timeout=600, check=False,
    )
    output = (result.stdout or "") + "\n" + (result.stderr or "")
    session_id = extract_session_id(output) or latest_session_id("default")
    if session_id:
        store.save_session("default", session_key, session_id)
    if result.returncode != 0:
        raise RuntimeError(f"hermes exited {result.returncode} for role {role}")
    return clean_reply(result.stdout)


def company_summary(state: dict) -> dict:
    """State for the app: everything except the bulky per-stage minutes."""
    slim = []
    for init in state["initiatives"]:
        item = {k: v for k, v in init.items() if k != "minutes"}
        slim.append(item)
    return {
        "enabled": state["enabled"],
        "thesis": state["thesis"],
        "config": state["config"],
        "last_tick": state["last_tick"],
        "initiatives": slim,
    }


def company_heartbeat_loop() -> None:
    store = company_module.CompanyStore(COMPANY_STATE_PATH)
    while True:
        try:
            with COMPANY_LOCK:
                state = store.load()
                events = company_module.tick(state, company_cli_runner, COMPANY_ARTIFACTS_ROOT)
                store.save(state)
            for event in events:
                print(f"company - {event}", flush=True)
        except Exception as error:  # noqa: BLE001 — the pulse must survive anything
            print(f"company - heartbeat error: {error}", flush=True)
        time.sleep(60)
```

(Add `import time` to the imports if not present.)

**3c.** In `RelayHandler.do_GET`, before the 404 fallthrough, add:

```python
        if self.path == "/company":
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            store = company_module.CompanyStore(COMPANY_STATE_PATH)
            with COMPANY_LOCK:
                self.send_json(company_summary(store.load()))
            return
        if self.path.startswith("/company/initiative/"):
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            initiative_id = self.path.rsplit("/", 1)[-1]
            store = company_module.CompanyStore(COMPANY_STATE_PATH)
            with COMPANY_LOCK:
                try:
                    self.send_json(company_module.find_initiative(store.load(), initiative_id))
                except KeyError:
                    self.send_json({"error": "not_found"}, status=404)
            return
```

**3d.** In `RelayHandler.do_POST`, change the path gate at the top to also accept company routes, and handle them before the chat logic:

```python
        if self.path not in {"/chat", "/chat/stream", "/company/start", "/company/halt", "/company/gate"}:
            self.send_json({"error": "not_found"}, status=404)
            return

        if not self.is_authorized():
            self.send_json({"error": "unauthorized"}, status=401)
            return

        if self.path.startswith("/company/"):
            try:
                body = self.read_json()
            except Exception as error:
                self.send_json({"error": f"invalid_json: {error}"}, status=400)
                return
            store = company_module.CompanyStore(COMPANY_STATE_PATH)
            with COMPANY_LOCK:
                state = store.load()
                try:
                    if self.path == "/company/start":
                        state["enabled"] = True
                        if "thesis" in body:
                            state["thesis"] = str(body["thesis"])
                        state["last_tick"] = 0.0   # first tick fires within a minute
                    elif self.path == "/company/halt":
                        state["enabled"] = False
                    else:  # /company/gate
                        company_module.apply_gate(
                            state,
                            str(body.get("id", "")),
                            str(body.get("decision", "")),
                            str(body.get("note", "")),
                        )
                except KeyError:
                    self.send_json({"error": "initiative_not_found"}, status=404)
                    return
                except ValueError as error:
                    self.send_json({"error": str(error)}, status=400)
                    return
                store.save(state)
                self.send_json(company_summary(state))
            return
```

**3e.** In `main()`, just before `server = ThreadingHTTPServer(...)`, start the heartbeat:

```python
    heartbeat = threading.Thread(target=company_heartbeat_loop, daemon=True)
    heartbeat.start()
    print("Company heartbeat: running (60s check, tick interval from config)\n", flush=True)
```

- [ ] **Step 4: Run both test files to verify they pass**

Run: `python3 Scripts/test_hermes_mobile_relay.py -v 2>&1 | tail -3 && python3 Scripts/test_hermes_company.py -v 2>&1 | tail -3`
Expected: `OK` for both (existing relay tests + 3 new ones; company suite 33).

- [ ] **Step 5: Commit**

```bash
git add Scripts/hermes_mobile_relay.py Scripts/test_hermes_mobile_relay.py
git commit -m "feat(company): relay endpoints, role sessions, and heartbeat thread"
```

---

### Task 8: End-to-end dry run through the live relay (fake-free, one real call, then full fake pipeline)

**Files:**
- Modify: none (verification only)

- [ ] **Step 1: Restart the relay** (MUST be unsandboxed — see memory note: sandboxed children lose network)

```bash
pkill -f hermes_mobile_relay.py; sleep 1
cd "/Users/chosenvessel/Documents/hermes ios" && nohup /Users/chosenvessel/.hermes/hermes-agent/venv/bin/python -u Scripts/hermes_mobile_relay.py >> ~/Library/Logs/hermes-mobile-relay.log 2>&1 & disown
sleep 2; curl -s -m 5 http://127.0.0.1:8787/health
```

Expected: `{"ok": true, ...}` and the log shows `Company heartbeat: running`.

- [ ] **Step 2: Exercise the API surface with auth**

```bash
TOKEN=$(python3 -c "import json,pathlib;print(json.load(open(pathlib.Path.home()/'.hermes'/'mobile-relay.json'))['token'])")
curl -s -X POST http://127.0.0.1:8787/company/start -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"thesis":"small consumer utilities, shippable in days, no crypto"}'
curl -s http://127.0.0.1:8787/company -H "Authorization: Bearer $TOKEN"
```

Expected: both return JSON with `"enabled": true` and the thesis.

- [ ] **Step 3: Verify one REAL scout tick fires within ~60s** (this costs a handful of model calls — acceptable; it proves the real runner)

```bash
sleep 75; tail -5 ~/Library/Logs/hermes-mobile-relay.log | grep company
curl -s http://127.0.0.1:8787/company -H "Authorization: Bearer $TOKEN" | python3 -m json.tool | head -30
```

Expected: log shows `company - scouted new initiative <id>: <title>`; state shows one initiative at stage `research` with a real market-derived title.

- [ ] **Step 4: Halt the company (don't burn tokens while Phase 2 is built)**

```bash
curl -s -X POST http://127.0.0.1:8787/company/halt -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}'
```

Expected: `"enabled": false`.

- [ ] **Step 5: Commit the plan checkboxes + report**

```bash
git add docs/superpowers/plans/2026-06-11-autonomous-company-engine.md
git commit -m "docs(company): engine verified end-to-end against live relay"
```

---

## Self-Review (done at planning time)

- **Spec coverage:** heartbeat (Task 6/7), market scout + thesis (Task 3), boardroom debate w/ dissent (Task 4), real artifacts (Task 4 execution), two owner gates (Task 5 + endpoints Task 7), budgets/quiet hours/concurrency/kill switch (Tasks 2/6/7: `/company/halt`), owner invite content (demo brief, Task 4). App-side UI = Phase 2 plan, explicitly out of scope.
- **Placeholder scan:** none — every step has full code/commands.
- **Type consistency:** `runner(role, prompt) -> str` everywhere; state is plain dicts; `tick(state, runner, artifacts_root, now)` matches tests; relay reuses `RelayConfigStore`, `extract_session_id`, `clean_reply`, `latest_session_id`, `CONFIG_PATH` — all already exist in `hermes_mobile_relay.py`.
