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
