# Scripts/hermes_games_studio.py
"""Games Studio — the first Boardroom division engine.

A heartbeat-driven pipeline that takes a web/HTML5 game idea from concept to
shipped, exactly the way `hermes_company.py` takes a business initiative from
scout to Demo Day. Every LLM call goes through an injected
`runner(role, prompt) -> str`, so the whole pipeline — including the **Fun Gate**
that can reject an un-fun build — is deterministic and unit-testable offline.

Stages:

    concept → design → build → playtest → fun_gate → distribution → shipped
                                             │
                                             └── rejected → design (iterate)

Roles (agents):
  • game_designer — writes the design pillars AND owns the Fun Gate verdict.
  • playtester    — plays a build, returns a reaction + a 1-10 fun rating.
  • distributor   — moves the game onto itch.io / Reddit / portals.

The studio's flagship is **Skyline Stack** (a real, playable, bundled game); it
is seeded as a shipped title so the room is alive the moment the app opens.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import time
from datetime import datetime
from pathlib import Path

# The three narrow product lines the studio makes.
LINES = ("daily-puzzle", "hyper-casual", "viral-funnel")

# Stage machine.
STAGE_ORDER = ("concept", "design", "build", "playtest", "fun_gate",
               "distribution", "shipped")
TERMINAL_STAGES = ("shipped", "shelved")
DISTRIBUTION_CHANNELS = ("itch", "reddit", "portals")
CHANNEL_STATES = ("planned", "submitted", "live")

# How many independent playtesters sit on the couch per build.
PLAYTEST_PANEL = ("Pixel", "Bolt", "Ada")
# How many times a rejected game loops back through design before it's shelved.
MAX_REJECTIONS = 3
# Per-game call budget (mirror of the company engine's guardrail).
DEFAULT_BUDGET = 40

# The bundled, genuinely-playable flagship. Its runtime file ships in the app.
FLAGSHIP_RUNTIME = "SkylineStack.html"


def new_studio_state() -> dict:
    return {
        "enabled": False,
        "games": [],
        "events": [],
        "last_tick": 0.0,
    }


def log_event(state: dict, text: str) -> None:
    """Append to the studio's rolling activity feed (last 40 kept)."""
    events = state.setdefault("events", [])
    events.append({"text": text, "ts": time.time()})
    del events[:-40]


def new_game(title: str, line: str, pitch: str = "") -> dict:
    return {
        "id": secrets.token_hex(4),
        "title": title.strip() or "Untitled",
        "line": line if line in LINES else "hyper-casual",
        "pitch": pitch.strip(),
        "stage": "concept",
        "pillars": [],                       # design pillars (strings)
        "build_notes": "",                   # what the build turn produced
        "runtime": "",                       # bundled/served HTML filename
        "playtests": [],                     # [{tester, rating, reaction}]
        "fun_gate": {"verdict": "", "reasons": []},   # APPROVED | REJECTED
        "distribution": {c: "planned" for c in DISTRIBUTION_CHANNELS},
        "score": None,                       # owner's best arcade score (from app)
        "created": datetime.now().isoformat(timespec="seconds"),
        "iteration": 0,                      # bumped on each Fun-Gate rejection
        "rejections": 0,
        "calls_used": 0,
    }


# ─────────────────────────────── souls ────────────────────────────────

STUDIO_CULTURE = (
    "You work in the Boardroom Games Studio — a lean web/HTML5 game shop whose "
    "only job is to ship games people actually want to play. The bar is FUN, not "
    "features. A clever idea that isn't fun in the first ten seconds is a failure. "
    "You are honest to a fault: you would rather kill your own build than let a "
    "boring game ship with your name on it."
)

ROLE_SOULS = {
    "game_designer": (
        "You are the Game Designer. You define the core loop and the design "
        "pillars, and you own the Fun Gate — the final say on whether a build is "
        "actually fun enough to ship. You are ruthless about fun and specific "
        "about why."),
    "playtester": (
        "You are a Playtester. You play the build like a real player with a short "
        "attention span and you report your gut reaction honestly, plus a fun "
        "rating from 1 to 10. You do not flatter the team."),
    "distributor": (
        "You are the Distribution lead. You get finished games in front of players "
        "on itch.io, Reddit (r/WebGames, r/incremental_games, r/playmygame), and "
        "HTML5 game portals. You know what each channel wants and how to post it."),
    "builder": (
        "You are the Lead Game Developer. You build the actual playable HTML5 "
        "game — canvas, input, audio, juice — real and working, never a mockup."),
}


def role_prompt(role: str, body: str) -> str:
    soul = ROLE_SOULS.get(role, "")
    return f"{STUDIO_CULTURE}\n\n{soul}\n\n{body}"


# ─────────────────────────── pure parsers ─────────────────────────────

def parse_pillars(text: str) -> list[str]:
    """Pull design pillars out of a designer reply. Accepts bulleted, numbered,
    or newline-separated lists; returns up to 5 tidy one-liners."""
    pillars: list[str] = []
    for raw in (text or "").splitlines():
        line = raw.strip()
        if not line:
            continue
        line = re.sub(r"^[-*•\d.)\s]+", "", line).strip()
        # Drop headers / labels like "Design pillars:" that carry no content.
        if len(line) < 4 or line.lower().rstrip(":") in ("design pillars", "pillars"):
            continue
        pillars.append(line[:80])
        if len(pillars) >= 5:
            break
    return pillars


# Prefer a LABELED rating ("Rating: 8", "fun 6") or the "N/10" form, and take
# the LAST such match — so a stray number in the reaction prose ("died on
# level 4", "played 3 minutes") never overrides the rating the tester states at
# the end. A bare digit with no label and no "/10" is intentionally ignored.
_RATING_RE = re.compile(
    r"(?:rating|fun|score)\s*[:=]?\s*(\d{1,2})\b|\b(\d{1,2})\s*/\s*10\b", re.I)


def parse_playtest(text: str) -> dict:
    """A tester's reply → {rating, reaction}. Reads the tester's stated fun
    rating (defaults to 5 if none stated) and keeps a short reaction line."""
    text = (text or "").strip()
    rating = 5
    matches = list(_RATING_RE.finditer(text))
    if matches:
        value = next((g for g in matches[-1].groups() if g), None)
        if value is not None:
            rating = max(1, min(10, int(value)))
    # First non-empty sentence/line makes a compact reaction.
    reaction = ""
    for line in text.splitlines():
        line = line.strip()
        if line:
            reaction = re.split(r"(?<=[.!?])\s", line)[0][:120]
            break
    return {"rating": rating, "reaction": reaction or "(no comment)"}


def playtest_scores(game: dict) -> tuple[float, int]:
    """(average fun rating, number of playtests). Average is 0.0 with no data."""
    tests = game.get("playtests", [])
    if not tests:
        return 0.0, 0
    total = sum(t.get("rating", 0) for t in tests)
    return round(total / len(tests), 1), len(tests)


def fun_gate_passed(text: str) -> bool:
    """The designer ends the Fun-Gate verdict with 'GATE: APPROVED' or
    'GATE: REJECTED'. The later marker wins (mirrors the company engine's
    review_passed). APPROVED/REJECTED never substring-collide."""
    upper = (text or "").upper()
    approved = upper.rfind("GATE: APPROVED")
    rejected = upper.rfind("GATE: REJECTED")
    return approved != -1 and approved > rejected


def parse_fun_reasons(text: str) -> list[str]:
    """Bullet/numbered reasons the designer gave for the verdict — up to 4."""
    reasons: list[str] = []
    for raw in (text or "").splitlines():
        line = raw.strip()
        if not re.match(r"^[-*•\d]", line):
            continue
        line = re.sub(r"^[-*•\d.)\s]+", "", line).strip()
        if re.match(r"(?i)gate:\s*(approved|rejected)", line) or len(line) < 4:
            continue
        reasons.append(line[:100])
        if len(reasons) >= 4:
            break
    return reasons


def parse_distribution(text: str) -> dict:
    """Map a distributor reply onto per-channel status. Recognizes each channel
    name near a status word; anything unseen keeps a sensible default."""
    lowered = (text or "").lower()
    result = {"itch": "live", "reddit": "submitted", "portals": "planned"}
    aliases = {
        "itch": ["itch"],
        "reddit": ["reddit", "r/"],
        "portals": ["portal", "newgrounds", "crazygames", "poki", "kongregate"],
    }
    for channel, keys in aliases.items():
        for key in keys:
            idx = lowered.find(key)
            if idx == -1:
                continue
            window = lowered[idx: idx + 60]
            for status in ("live", "submitted", "planned"):
                if status in window:
                    result[channel] = status
                    break
            break
    return result


# ────────────────────────── charged runner ────────────────────────────

class BudgetExceeded(Exception):
    pass


def make_charged_runner(game: dict, budget: int, runner):
    def charged(role: str, prompt: str) -> str:
        if game["calls_used"] >= budget:
            raise BudgetExceeded(f"{game['id']} exhausted {budget} calls")
        game["calls_used"] += 1
        return runner(role, prompt)
    return charged


# ─────────────────────────── stage machine ────────────────────────────

def working(state: dict) -> list[dict]:
    return [g for g in state.get("games", []) if g["stage"] not in TERMINAL_STAGES]


def advance_game(state: dict, game: dict, runner, artifacts_root: Path | None = None) -> None:
    """Advance one game by exactly one stage. Pure but for the injected runner
    and (optionally) writing the built game file to disk."""
    stage = game["stage"]

    if stage == "concept":
        reply = runner("game_designer", role_prompt("game_designer",
            f"New {game['line']} web game concept: '{game['title']}'"
            f"{' — ' + game['pitch'] if game['pitch'] else ''}.\n"
            "In 2-3 sentences, sharpen the concept: the one core action, the hook "
            "that makes it fun in ten seconds, and why a player comes back. "
            "Natural prose, no lists."))
        game["pitch"] = reply.strip()[:400] or game["pitch"]
        game["stage"] = "design"

    elif stage == "design":
        reply = runner("game_designer", role_prompt("game_designer",
            f"Lock the design for '{game['title']}' ({game['line']}). "
            f"Concept: {game['pitch']}\n"
            "Write 3-5 crisp DESIGN PILLARS — the non-negotiables the build must "
            "honor (core loop, control scheme, feedback/juice, difficulty curve, "
            "session length). One pillar per line, no preamble."))
        game["pillars"] = parse_pillars(reply)
        game["stage"] = "build"

    elif stage == "build":
        outdir = None
        if artifacts_root is not None:
            outdir = Path(artifacts_root) / _game_dirname(game)
            outdir.mkdir(parents=True, exist_ok=True)
        reply = runner("builder", role_prompt("builder",
            f"Build '{game['title']}' as a real, single-file HTML5 game honoring "
            f"these pillars:\n- " + "\n- ".join(game["pillars"] or [game["pitch"]]) +
            (f"\nSave it to {outdir}/index.html." if outdir else "") +
            "\nCanvas render loop, touch + keyboard input, WebAudio feedback, a "
            "score and a best-score, and a restart loop. No stubs. Summarize what "
            "you built in 2-3 lines and name the entry file."))
        game["build_notes"] = reply.strip()[:600]
        # Record the runtime filename. The flagship keeps its bundled file.
        if not game["runtime"]:
            game["runtime"] = "index.html"
        game["stage"] = "playtest"

    elif stage == "playtest":
        # Playtest choreography: each tester on the couch plays and reports.
        game["playtests"] = []
        for tester in PLAYTEST_PANEL:
            reply = runner("playtester", role_prompt("playtester",
                f"You are {tester}. Play '{game['title']}' ({game['line']}). "
                f"Design pillars:\n- " + "\n- ".join(game["pillars"] or ["(none)"]) +
                f"\nBuild notes: {game['build_notes']}\n"
                "React in ONE honest sentence, then give a fun rating from 1 to 10 "
                "as 'Rating: N/10'."))
            result = parse_playtest(reply)
            result["tester"] = tester
            game["playtests"].append(result)
        game["stage"] = "fun_gate"

    elif stage == "fun_gate":
        avg, count = playtest_scores(game)
        transcript = "\n".join(
            f"{t['tester']}: {t['rating']}/10 — {t['reaction']}"
            for t in game.get("playtests", []))
        reply = runner("game_designer", role_prompt("game_designer",
            f"FUN GATE for '{game['title']}'. Average playtest score {avg}/10 "
            f"across {count} testers.\nPlaytests:\n{transcript}\n\n"
            "Decide whether this build is fun enough to ship. Give up to 4 bullet "
            "reasons, then end with EXACTLY one line: 'GATE: APPROVED' or "
            "'GATE: REJECTED'."))
        passed = fun_gate_passed(reply)
        game["fun_gate"] = {
            "verdict": "APPROVED" if passed else "REJECTED",
            "reasons": parse_fun_reasons(reply),
        }
        if passed:
            game["stage"] = "distribution"
            log_event(state, f"Fun Gate APPROVED: {game['title']}")
        else:
            game["rejections"] = game.get("rejections", 0) + 1
            game["iteration"] = game.get("iteration", 0) + 1
            log_event(state, f"Fun Gate REJECTED: {game['title']} — back to design")
            if game["rejections"] >= MAX_REJECTIONS:
                game["stage"] = "shelved"
                log_event(state, f"shelved after {MAX_REJECTIONS} rejections: {game['title']}")
            else:
                game["stage"] = "design"   # loop back and make it fun

    elif stage == "distribution":
        avg, _ = playtest_scores(game)
        reply = runner("distributor", role_prompt("distributor",
            f"'{game['title']}' passed the Fun Gate (avg {avg}/10). Get it in front "
            "of players. For each channel — itch.io, Reddit, portals — say whether "
            "it is 'live', 'submitted', or 'planned' and one line on the angle."))
        game["distribution"] = parse_distribution(reply)
        game["stage"] = "shipped"
        log_event(state, f"shipped: {game['title']}")


def _game_dirname(game: dict) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", game["title"].lower()).strip("-")[:40] or "game"
    return f"{slug}-{game['id'][:4]}"


def merge_tick_results(current: dict, ticked: dict, before: dict) -> dict:
    """Fold a long tick's changes into freshly-loaded state without stomping
    owner actions made while the tick ran (halt, a pitched concept, a recorded
    high score). Mirrors `hermes_company.merge_tick_results`, keyed on 'games'.

    `before` is the deep snapshot taken when the tick started. Only games the
    tick actually CHANGED overwrite the current on-disk version; `enabled` and
    each game's owner-set `score` are always kept from `current`, so a mid-tick
    /games/halt or /games/score survives instead of being silently reverted."""
    before_by_id = {g["id"]: g for g in before.get("games", [])}
    current_by_id = {g["id"]: g for g in current.get("games", [])}

    for ticked_game in ticked.get("games", []):
        gid = ticked_game["id"]
        snapshot = before_by_id.get(gid)
        if snapshot is None:
            # Seeded during this tick — insert at the front if not already there.
            if gid not in current_by_id:
                current.setdefault("games", []).insert(0, ticked_game)
                current_by_id[gid] = ticked_game
            continue
        if ticked_game != snapshot and gid in current_by_id:
            merged = dict(ticked_game)
            # The tick never touches `score`; the owner might have recorded one
            # mid-tick, so the current (owner) value wins.
            merged["score"] = current_by_id[gid].get("score", ticked_game.get("score"))
            index = next(i for i, g in enumerate(current["games"]) if g["id"] == gid)
            current["games"][index] = merged

    # `enabled` stays as the owner left it — so /games/halt during a tick sticks.
    seen = {(e.get("ts"), e.get("text")) for e in before.get("events", [])}
    fresh = [e for e in ticked.get("events", []) if (e.get("ts"), e.get("text")) not in seen]
    if fresh:
        feed = current.setdefault("events", [])
        known = {(e.get("ts"), e.get("text")) for e in feed}
        feed.extend(e for e in fresh if (e.get("ts"), e.get("text")) not in known)
        del feed[:-40]
    current["last_tick"] = max(current.get("last_tick", 0.0), ticked.get("last_tick", 0.0))
    return current


def tick(state: dict, runner, artifacts_root: Path | None = None,
         now: float | None = None) -> list[str]:
    """One studio heartbeat: advance every in-flight game by one stage. Returns
    human-readable event strings (also appended to the activity feed)."""
    now = now if now is not None else time.time()
    if not state.get("enabled"):
        return []
    events: list[str] = []
    for game in working(state):
        charged = make_charged_runner(game, DEFAULT_BUDGET, runner)
        try:
            advance_game(state, game, charged, artifacts_root)
            events.append(f"{game['id']} → {game['stage']}")
        except BudgetExceeded:
            game["stage"] = "shelved"
            events.append(f"{game['id']} shelved: budget exhausted")
        except Exception as error:  # noqa: BLE001 — one bad turn never stops the pulse
            reason = str(error)
            if len(reason) > 200:
                reason = reason[:120] + " … " + reason[-60:]
            events.append(f"{game['id']} stalled: {reason}")
    state["last_tick"] = now
    for event in events:
        log_event(state, event)
    return events


# ─────────────────────────────── seeds ────────────────────────────────

def seed_flagship(state: dict) -> dict:
    """Insert the studio's real, shipped, playable flagship — Skyline Stack — so
    a fresh studio already has a title of record that matches the bundled game.
    Idempotent: never adds a second copy."""
    for game in state.get("games", []):
        if game.get("runtime") == FLAGSHIP_RUNTIME:
            return game
    game = new_game("Skyline Stack", "hyper-casual",
                    "Drop each floor clean to raise the tower — one thumb, endless.")
    game.update({
        "stage": "shipped",
        "runtime": FLAGSHIP_RUNTIME,
        "pillars": [
            "One-tap core loop: drop the sliding floor, trim the overhang.",
            "Perfect landings grow the block back and build a combo.",
            "Rising speed is the only difficulty knob — pure skill.",
            "Ten-second onramp, endless ceiling, instant restart.",
        ],
        "build_notes": "Canvas + WebAudio tower-stacker. Swinging floor, overhang "
                       "trimming, perfect-combo scoring, best-score persistence.",
        "playtests": [
            {"tester": "Pixel", "rating": 9, "reaction": "One more go — the perfect chime is addictive."},
            {"tester": "Bolt", "rating": 8, "reaction": "Clean, fast, reads instantly. Combo hook lands."},
            {"tester": "Ada", "rating": 9, "reaction": "Skyline theme + juice make it feel premium."},
        ],
        "fun_gate": {
            "verdict": "APPROVED",
            "reasons": [
                "Fun in the first ten seconds — no tutorial needed.",
                "Perfect-combo loop creates the one-more-try pull.",
                "Difficulty comes purely from speed — always feels fair.",
            ],
        },
        "distribution": {"itch": "live", "reddit": "submitted", "portals": "planned"},
    })
    state.setdefault("games", []).insert(0, game)
    log_event(state, "flagship seeded: Skyline Stack (shipped)")
    return game


def seed_concept(state: dict, title: str, line: str, pitch: str = "") -> dict:
    """Owner pitches a game idea — enters the pipeline at concept."""
    game = new_game(title, line, pitch)
    state.setdefault("games", []).insert(0, game)
    log_event(state, f"new concept: {game['title']} ({game['line']})")
    return game


# ─────────────────────────────── store ────────────────────────────────

class StudioStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> dict:
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text())
                if isinstance(data, dict) and "games" in data:
                    base = new_studio_state()
                    base.update(data)
                    return base
            except json.JSONDecodeError:
                pass
        state = new_studio_state()
        seed_flagship(state)   # a fresh studio ships with the flagship of record
        return state

    def save(self, state: dict) -> None:
        # Atomic write — a crash mid-write must never corrupt studio state.
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, indent=2))
        os.replace(tmp, self.path)


def studio_summary(state: dict) -> dict:
    """Slim state for the app — everything the room needs, nothing bulky."""
    return {
        "enabled": state.get("enabled", False),
        "games": state.get("games", []),
        "events": state.get("events", [])[-30:],
        "last_tick": state.get("last_tick", 0.0),
    }
