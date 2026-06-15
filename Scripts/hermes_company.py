# Scripts/hermes_company.py
"""Autonomous company engine for Hermes Mobile.

A heartbeat-driven pipeline: the org scouts market trends, debates
initiatives in a boardroom, builds real deliverables via Hermes agents,
and pauses at two owner decision gates. All LLM calls go through an
injected runner(role, prompt) -> str so everything is testable offline.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import time
from datetime import datetime
from pathlib import Path

# How many QA review→fix rounds the build team runs before Demo Day.
MAX_REVIEW_ROUNDS = 3
# How many times a stuck initiative retries a stage before it's killed.
MAX_STALLS = 3

DEFAULT_CONFIG = {
    "interval_minutes": 30,
    "quiet_start": 22,   # 10pm
    "quiet_end": 7,      # 7am
    "max_active": 1,
    "budget_calls": 40,
    "scout_sources": "Hacker News, Product Hunt, GitHub trending, App Store charts, Reddit",
    "meeting_gap_minutes": 90,   # how often the org holds an internal standup
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
        "meetings": [],        # autonomous internal meetings the owner can listen in on
        "last_meeting": 0.0,
    }


def new_meeting(topic: str, attendees: list[str]) -> dict:
    return {
        "id": secrets.token_hex(4),
        "topic": topic,
        "attendees": attendees,            # role keys (ceo, cfo, …)
        "status": "live",                  # live → done
        "turns": [],                       # [{"role":..., "text":..., "ts":...}]
        "started": datetime.now().isoformat(timespec="seconds"),
    }


def should_convene_meeting(state: dict, now: float) -> bool:
    """Time for the org to hold an internal standup? Gated by enable, quiet
    hours, the meeting cadence, and not stacking on a live meeting."""
    if not state.get("enabled"):
        return False
    config = state["config"]
    hour = datetime.fromtimestamp(now).hour
    if is_quiet(hour, config["quiet_start"], config["quiet_end"]):
        return False
    if any(m.get("status") == "live" for m in state.get("meetings", [])):
        return False
    gap = config.get("meeting_gap_minutes", 90) * 60
    return now - state.get("last_meeting", 0.0) >= gap


def meeting_plan(state: dict) -> tuple[str, list[str]]:
    """Topic + attendee roles for the next autonomous meeting, from current state."""
    active = [i for i in state["initiatives"] if i["stage"] not in TERMINAL_STAGES]
    if active:
        return f"Status check: {active[0]['title']}", ["ceo", "cfo", "cto", "marketing"]
    return "Company standup — what should we pursue next?", ["ceo", "research", "marketing"]


def add_owner_turn(state: dict, meeting_id: str, text: str) -> dict | None:
    """The owner speaks into a meeting — appended as a turn the agents will
    address. Reopens the meeting (live) so they respond."""
    for meeting in state.get("meetings", []):
        if meeting["id"] == meeting_id:
            meeting["turns"].append({"role": "owner", "text": text.strip(),
                                     "ts": datetime.now().strftime("%H:%M")})
            meeting["status"] = "live"
            return meeting
    return None


def owner_response_prompt(meeting: dict, role: str, owner_text: str,
                          transcript: str, state: dict) -> str:
    body = (
        f"You are in a live internal meeting on \"{meeting['topic']}\".\n"
        f"Discussion so far:\n{transcript}\n\n"
        f"The OWNER (the Chairman) just stepped in and said: \"{owner_text}\"\n\n"
        f"Respond directly to the owner's input as the {role.upper()} in 2–3 "
        f"sentences — take their steer seriously, adjust your position, and say "
        f"concretely what you'll do about it. Natural spoken style, no markdown."
    )
    return role_prompt(role, body)


def meeting_turn_prompt(meeting: dict, role: str, transcript: str, state: dict) -> str:
    active = [i["title"] for i in state["initiatives"] if i["stage"] not in TERMINAL_STAGES]
    context = f"Active initiatives: {', '.join(active) if active else 'none right now'}."
    body = (
        f"You are in a LIVE internal company meeting. Topic: \"{meeting['topic']}\". {context}\n"
        f"Discussion so far:\n{transcript or '(you are opening the meeting)'}\n\n"
        f"Give your contribution as the {role.upper()} in 2–3 sentences — raise a real "
        f"point, concern, risk, or proposal from your seat. Build on what others said. "
        f"Natural spoken style, no markdown, no lists."
    )
    return role_prompt(role, body)


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
        "iteration": 0,   # bumped each time the owner asks for more work
    }


def reopen_for_iteration(state: dict, initiative_id: str, instruction: str) -> dict:
    """Owner wants MORE work on a finished project — reopen it so the same
    team continues on the SAME codebase (add features, backend, etc.).
    Re-enters planning with the new instruction; re-ships to the same repo."""
    init = find_initiative(state, initiative_id)
    init["iteration"] = init.get("iteration", 0) + 1
    init["note"] = instruction
    init["review_rounds"] = 0
    init["brief"] = ""
    init["stage"] = "planning"   # heartbeat picks it up and continues the project
    return init


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
        # Atomic write: a crash mid-write must never corrupt company state
        # (a half-written file decodes to empty and wipes every initiative).
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, indent=2))
        os.replace(tmp, self.path)


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


# Real tools the builder can shell out to (installed on the Mac). The builder
# is Hermes with full file/code/shell access — same as a coding agent.
BUILDER_TOOLKIT = (
    "You are a senior full-stack engineer with FULL developer tools on this "
    "machine — shell, git, gh (GitHub), node/npm, xcodebuild — and you USE them "
    "for real, not just describe work. Capabilities:\n"
    "• Backend: scaffold and deploy with the Firebase CLI (`firebase`) — Auth, "
    "Firestore, Cloud Functions, Hosting — and wire it into the app.\n"
    "• Payments: integrate RevenueCat — add the SDK to the iOS app, build the "
    "paywall/entitlement logic, and configure products via the RevenueCat API "
    "when a key is available.\n"
    "• Release: prepare the app for TestFlight/App Store (fastlane, App Store "
    "Connect) when signing/credentials are configured.\n"
    "Write the code AND run the commands. If a step needs the owner to log in "
    "(`firebase login`), add an API key (RevenueCat, App Store Connect), or make "
    "a decision, STATE IT PLAINLY in your summary — never fake a result you "
    "couldn't actually produce."
)

ROLE_SOULS = {
    "research": "You are the Head of Research of an autonomous AI product company. You scout markets with evidence, never hype.",
    "cfo": "You are the CFO. You weigh cost, monetization, and opportunity cost. You are the board's skeptic.",
    "cto": "You are the CTO. You judge technical feasibility, scope, and how fast a small team can ship.",
    "marketing": "You are the Head of Marketing. You judge demand, distribution channels, and how the product gets users.",
    "ceo": "You are the CEO. You chair the board, weigh dissent honestly, and decide. You report to the owner (the human Chairman).",
    "builder": "You are the Lead Builder. You produce real deliverables — files, code, docs — not descriptions of them.",
    "qa": "You are the QA + Design lead. You are demanding and detail-obsessed. You judge work as a SHIPPABLE product, never a demo. You catch stubs, fake logic, placeholder text, and unpolished UI, and you do NOT pass anything that would embarrass the owner in front of users.",
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


def initiative_dirname(init: dict) -> str:
    """Human-readable deliverables folder: 'one-tap-brain-dump-cleaner-d7b3'."""
    slug = re.sub(r"[^a-z0-9]+", "-", init["title"].lower()).strip("-")[:40] or "initiative"
    return f"{slug}-{init['id'][:4]}"


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


def review_passed(review: str) -> bool:
    """QA ends with 'VERDICT: SHIP' or 'VERDICT: REVISE' — the later one wins."""
    text = review.upper()
    ship = text.rfind("VERDICT: SHIP")
    revise = text.rfind("VERDICT: REVISE")
    return ship != -1 and ship > revise


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
        if init.get("iteration", 0) > 0:
            # Continuation: the owner wants MORE on an existing shipped project.
            reply = runner("ceo", role_prompt("ceo",
                f"'{init['title']}' is already built and shipped. This is "
                f"iteration {init['iteration']}. The owner now wants:\n"
                f"\"{init['note']}\"\n\n"
                "Write a SMALL work order for THIS addition only — extend the "
                "existing code, don't rebuild. List exactly which files to add or "
                "change and what each change does. Keep it to one focused pass."))
        else:
            note = f" The owner added: {init['note']}." if init["note"] else ""
            reply = runner("ceo", role_prompt("ceo",
                f"The owner GREENLIT '{init['title']}'.{note}\n"
                f"Research memo:\n{last_text(init, 'research')}\n"
                "Write a RUTHLESSLY SMALL work order — the single core slice that "
                "proves the idea and nothing else. Hard limits: ONE main screen/flow, "
                "3–6 files MAX. NO widgets, StoreKit, landing page, App Store assets, "
                "tests, or 'nice to haves'. The build team gets ONE pass, so scope it "
                "so a focused engineer finishes it well in that pass. List the few "
                "files to create and the one thing each must do."))
        log_minute(init, "planning", "ceo", reply)
        init["stage"] = "execution"

    elif stage == "execution":
        outdir = artifacts_root / initiative_dirname(init)
        outdir.mkdir(parents=True, exist_ok=True)

        def collect_artifacts() -> None:
            init["artifacts"] = sorted(
                str(p) for p in outdir.rglob("*") if p.is_file())

        existing = sorted(str(p) for p in outdir.rglob("*") if p.is_file())
        if existing:
            # Iteration: extend the project already on disk, don't rebuild it.
            build = runner("builder", role_prompt("builder",
                f"{BUILDER_TOOLKIT}\n\n"
                f"EXTEND the existing project at {outdir} — do NOT rebuild it. "
                f"Read what's already there, then make ONLY the additions in the "
                f"work order, wired in properly and working (no stubs/TODOs). "
                f"Backend, payments, and release work all belong here when asked.\n"
                f"Existing files:\n{chr(10).join(existing[:40])}\n\n"
                f"Work order:\n{last_text(init, 'planning')}\n"
                "List each file you added or changed with a one-line summary, and "
                "flag anything that needs an owner login or key."))
        else:
            # First build — a SMALL, complete, polished core beats a half-done
            # 12-feature app that times out.
            build = runner("builder", role_prompt("builder",
                f"{BUILDER_TOOLKIT}\n\n"
                f"Build the CORE SLICE of '{init['title']}' — small but genuinely "
                f"COMPLETE and polished: the one main flow fully wired and working, "
                f"no stubs, no placeholder/TODO logic, looks finished. Do NOT attempt "
                f"the whole product — just the core slice in the work order, done well. "
                f"Keep it to a handful of files so you finish in this pass. "
                f"Save every file under {outdir} using your file tools.\n"
                f"Work order:\n{last_text(init, 'planning')}\n"
                "List each file you created with a one-line summary."))
        log_minute(init, "execution", "builder", build)
        collect_artifacts()

        # 2. QA review → fix loop. The team keeps working until QA signs off
        #    or the rounds/budget run out — no more one-shot dumps.
        rounds = 0
        try:
            for _ in range(MAX_REVIEW_ROUNDS):
                files = "\n".join(init["artifacts"]) or "(no files)"
                review = runner("qa", role_prompt("qa",
                    f"Review the CORE SLICE of '{init['title']}'. READ every file "
                    f"under {outdir}.\n"
                    f"Files:\n{files}\n\n"
                    "Judge ONLY the scoped core slice — do NOT demand features that "
                    "were intentionally cut (widgets, payments, landing pages, "
                    "tests, extra screens). For the slice that IS here: does it work "
                    "end to end? Is it real, not faked/stubbed? Is the UI clean, not "
                    "a bare skeleton? Any TODOs, placeholders, or dead buttons IN "
                    "THE CORE?\n"
                    "End with exactly one line: 'VERDICT: SHIP' if the core slice is "
                    "genuinely solid, or 'VERDICT: REVISE' then a SHORT numbered list "
                    "(max 4) of fixes to the core only."))
                log_minute(init, "review", "qa", review)
                rounds += 1
                if review_passed(review):
                    break
                fix = runner("builder", role_prompt("builder",
                    f"QA reviewed '{init['title']}' and requires changes before it "
                    f"can ship. Address EVERY point by editing the real files under "
                    f"{outdir}. Don't argue — do the work.\n\nQA review:\n{review}"))
                log_minute(init, "execution", "builder", fix)
                collect_artifacts()
        except BudgetExceeded:
            pass   # ship what exists rather than vanish

        init["review_rounds"] = rounds
        collect_artifacts()
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


def merge_tick_results(current: dict, ticked: dict, before: dict) -> dict:
    """Fold a long tick's changes into freshly-loaded state without stomping
    decisions the owner made while the tick was running.

    `before` is the deep snapshot taken when the tick started. Only
    initiatives the tick actually CHANGED (vs `before`) overwrite the current
    on-disk version; everything else (enabled/thesis/config, initiatives the
    tick skipped, gate decisions made mid-tick) is kept from `current`."""
    before_by_id = {i["id"]: i for i in before.get("initiatives", [])}
    current_by_id = {i["id"]: i for i in current.get("initiatives", [])}

    for ticked_init in ticked.get("initiatives", []):
        init_id = ticked_init["id"]
        snapshot = before_by_id.get(init_id)
        if snapshot is None:
            # Newly scouted during this tick — insert at the front.
            if init_id not in current_by_id:
                current["initiatives"].insert(0, ticked_init)
                current_by_id[init_id] = ticked_init
            continue
        if ticked_init != snapshot and init_id in current_by_id:
            index = next(i for i, x in enumerate(current["initiatives"]) if x["id"] == init_id)
            current["initiatives"][index] = ticked_init

    current["last_tick"] = max(current.get("last_tick", 0.0), ticked.get("last_tick", 0.0))
    return current


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
            init["stall_count"] = 0   # progress resets the stall counter
            events.append(f"{init['id']} advanced to {init['stage']}")
        except BudgetExceeded:
            init["stage"] = "killed"
            init["note"] = "token budget exhausted"
            events.append(f"{init['id']} killed: budget exhausted")
        except Exception as error:  # noqa: BLE001 — one bad turn must not stop the pulse
            init["stall_count"] = init.get("stall_count", 0) + 1
            if init["stall_count"] >= MAX_STALLS:
                init["stage"] = "killed"
                init["note"] = f"killed after {MAX_STALLS} failed attempts: {error}"
                events.append(f"{init['id']} killed: {error}")
            else:
                init["note"] = f"stalled ({init['stall_count']}/{MAX_STALLS}): {error}"
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
