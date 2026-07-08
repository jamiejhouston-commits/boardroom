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
import shutil
import subprocess
import time
from datetime import datetime
from pathlib import Path

# The product lines the studio makes: playable games, and sellable game-asset
# packs (2D + 3D) that flow through the same pipeline with asset-aware prompts.
GAME_LINES = ("daily-puzzle", "hyper-casual", "viral-funnel")
ASSET_LINES = ("asset-2d", "asset-3d")
LINES = GAME_LINES + ASSET_LINES

# Stage machine.
STAGE_ORDER = ("concept", "design", "build", "playtest", "fun_gate",
               "distribution", "shipped")
TERMINAL_STAGES = ("shipped", "shelved")
# Paused (budget exhausted) is NOT terminal — the owner can resume it — but
# the tick skips it so it stops burning calls.
SKIP_STAGES = TERMINAL_STAGES + ("paused",)
DISTRIBUTION_CHANNELS = ("itch", "reddit", "portals")
# Asset packs sell on marketplaces, not game portals.
ASSET_CHANNELS = ("itch", "roblox", "unity")
CHANNEL_STATES = ("planned", "submitted", "live")


def is_asset(game: dict) -> bool:
    return str(game.get("line", "")).startswith("asset-")

# How many independent playtesters sit on the couch per build.
PLAYTEST_PANEL = ("Pixel", "Bolt", "Ada")
# How many times a rejected game loops back through design before it's shelved.
MAX_REJECTIONS = 3
# Per-game call budget (mirror of the company engine's guardrail).
DEFAULT_BUDGET = 40
# How much of the built game's source a playtester gets to read.
PLAYTEST_CODE_CAP = 30_000

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
        "distribution": {c: "planned" for c in
                         (ASSET_CHANNELS if line in ASSET_LINES else DISTRIBUTION_CHANNELS)},
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
    "artist": (
        "You are the Lead Game Artist — a professional 2D/3D asset artist whose "
        "packs sell on real marketplaces. Consistency is your religion: one "
        "palette, one style, one naming convention across every piece. You "
        "produce real files with real tools, never descriptions of files."),
}

# Burned into every asset-pack build turn. The artist is a Hermes agent with
# full shell access on this Mac — these are the REAL tools it drives, so the
# output is store-ready files, not prose. The honest-fallback clause is
# load-bearing: a missing tool must degrade the format, never fake the output.
ASSET_TOOLKIT = (
    "You have FULL developer tools on this machine and you USE them:\n"
    "• 2D: author crisp vector art as hand-written SVG (consistent palette, "
    "stroke weight, and silhouette language across the whole pack), then "
    "rasterize to transparent PNGs at 1x/2x with `rsvg-convert`, `qlmanage`, or "
    "a small Python (cairosvg/Pillow) script; assemble sprite sheets and "
    "9-slices where the pack calls for them.\n"
    "• 3D: script Blender headless (`blender -b -P build.py`) to model, "
    "UV-unwrap, and texture game-ready meshes; keep sensible budgets "
    "(props ≤5k tris, hero pieces ≤10k); bake simple PBR materials; export "
    "each piece as glTF/GLB plus FBX and OBJ so every engine imports it.\n"
    "• Roblox: export FBX that imports cleanly into Roblox Studio (single "
    "material per mesh where possible, Y-up, real-world scale) and include a "
    "Roblox import note; write .rbxmx (XML) model files directly when a "
    "ready-made model tree helps buyers.\n"
    "• Store-ready packaging: organized folders per format, preview renders "
    "of every piece, LICENSE.txt (royalty-free, resale of the pack itself "
    "prohibited), and a README with per-engine import instructions (Roblox, "
    "Unity, Unreal, Godot, web).\n"
    "If a tool is genuinely missing (e.g. Blender isn't installed), SAY SO in "
    "your summary and ship the best format you can actually produce and verify "
    "— never fake a file you didn't make."
)


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


def parse_distribution(text: str, asset: bool = False, verified: bool = False) -> dict:
    """Map a distributor reply onto per-channel status. Every channel defaults
    to 'planned' — nothing is 'live' on an agent's say-so. A 'live' claim only
    sticks when `verified` is True (a real publish, e.g. butler, succeeded)."""
    lowered = (text or "").lower()
    if asset:
        channels = ASSET_CHANNELS
        aliases = {
            "itch": ["itch"],
            "roblox": ["roblox", "creator store", "creator marketplace"],
            "unity": ["unity", "unreal", "fab", "godot", "marketplace", "asset store"],
        }
    else:
        channels = DISTRIBUTION_CHANNELS
        aliases = {
            "itch": ["itch"],
            "reddit": ["reddit", "r/"],
            "portals": ["portal", "newgrounds", "crazygames", "poki", "kongregate"],
        }
    result = {c: "planned" for c in channels}
    for channel, keys in aliases.items():
        for key in keys:
            idx = lowered.find(key)
            if idx == -1:
                continue
            window = lowered[idx: idx + 60]
            for status in ("live", "submitted", "planned"):
                if status in window:
                    if status == "live" and not verified:
                        status = "planned"   # honest: unverified "live" claim
                    result[channel] = status
                    break
            break
    return result


def publish_itch(game: dict, outdir: Path | None) -> str | None:
    """REAL itch.io publish via the butler CLI. Returns the live URL on
    verified success, None on any failure or missing butler/config — the
    caller must never mark 'live' without a URL from here."""
    if outdir is None:
        return None
    butler = shutil.which("butler")
    config_path = Path.home() / ".hermes" / "itch.json"
    if not butler or not config_path.exists():
        return None
    try:
        user = str(json.loads(config_path.read_text()).get("user", "")).strip()
    except (json.JSONDecodeError, OSError):
        return None
    entry = game.get("runtime") or "index.html"
    if not user or not (Path(outdir) / entry).exists():
        return None
    slug = re.sub(r"[^a-z0-9]+", "-", game["title"].lower()).strip("-")[:40] or "game"
    try:
        result = subprocess.run(
            [butler, "push", str(outdir), f"{user}/{slug}:html5"],
            capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return f"https://{user}.itch.io/{slug}"


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
    return [g for g in state.get("games", []) if g["stage"] not in SKIP_STAGES]


def iteration_feedback(game: dict) -> str:
    """The learning loop: after a Fun-Gate rejection, the next design and build
    turns see exactly WHY the last version failed — gate reasons plus the
    playtesters' criticisms — instead of iterating blind."""
    gate = game.get("fun_gate", {})
    if gate.get("verdict") != "REJECTED":
        return ""
    gate_name = "Quality Gate" if is_asset(game) else "Fun Gate"
    reasons = [f"- {r}" for r in gate.get("reasons", [])] or ["- (no reasons recorded)"]
    block = (f"\nPREVIOUS ITERATION FEEDBACK — the {gate_name} rejected "
             f"v{game.get('iteration', 1)} because:\n" + "\n".join(reasons))
    criticisms = [f"- {t.get('tester', '?')}: {t.get('reaction', '')}"
                  for t in game.get("playtests", []) if t.get("reaction")]
    if criticisms:
        block += "\nPlaytester criticisms:\n" + "\n".join(criticisms)
    return block + "\nFix these specifically in this iteration.\n"


def advance_game(state: dict, game: dict, runner, artifacts_root: Path | None = None) -> None:
    """Advance one game by exactly one stage. Pure but for the injected runner
    and (optionally) writing the built game file to disk."""
    stage = game["stage"]

    asset = is_asset(game)
    kind = "3D" if game["line"] == "asset-3d" else "2D"

    if stage == "concept":
        if asset:
            body = (
                f"New {kind} game-asset pack concept: '{game['title']}'"
                f"{' — ' + game['pitch'] if game['pitch'] else ''}.\n"
                "In 2-3 sentences, sharpen the pack: the theme and style, roughly "
                "what pieces it contains, who buys it (Roblox creators, Unity/Unreal "
                "indies, web devs), and why it sells over free alternatives. "
                "Natural prose, no lists.")
        else:
            body = (
                f"New {game['line']} web game concept: '{game['title']}'"
                f"{' — ' + game['pitch'] if game['pitch'] else ''}.\n"
                "In 2-3 sentences, sharpen the concept: the one core action, the hook "
                "that makes it fun in ten seconds, and why a player comes back. "
                "Natural prose, no lists.")
        reply = runner("game_designer", role_prompt("game_designer", body))
        game["pitch"] = reply.strip()[:400] or game["pitch"]
        game["stage"] = "design"

    elif stage == "design":
        if asset:
            body = (
                f"Lock the spec for the {kind} asset pack '{game['title']}'. "
                f"Concept: {game['pitch']}\n"
                "Write 3-5 crisp PACK PILLARS — the non-negotiables the build must "
                "honor (art style + palette, the exact piece list, technical budget "
                "— poly counts / texture sizes / formats, naming + export "
                "conventions, and the one thing that makes it stand out on a "
                "store). One pillar per line, no preamble.")
        else:
            body = (
                f"Lock the design for '{game['title']}' ({game['line']}). "
                f"Concept: {game['pitch']}\n"
                "Write 3-5 crisp DESIGN PILLARS — the non-negotiables the build must "
                "honor (core loop, control scheme, feedback/juice, difficulty curve, "
                "session length). One pillar per line, no preamble.")
        body += iteration_feedback(game)
        reply = runner("game_designer", role_prompt("game_designer", body))
        game["pillars"] = parse_pillars(reply)
        game["stage"] = "build"

    elif stage == "build":
        outdir = None
        if artifacts_root is not None:
            outdir = Path(artifacts_root) / _game_dirname(game)
            outdir.mkdir(parents=True, exist_ok=True)
        pillars = "\n- ".join(game["pillars"] or [game["pitch"]])
        feedback = iteration_feedback(game)
        if asset:
            reply = runner("artist", role_prompt("artist",
                f"{ASSET_TOOLKIT}\n\n"
                f"Produce the {kind} asset pack '{game['title']}' honoring these "
                f"pillars:\n- {pillars}\n" +
                (f"Save every file under {outdir}/ in the store-ready layout." if outdir
                 else "Lay the pack out store-ready.") +
                "\nBuild EVERY piece in the pillar piece list — professional, "
                "consistent, sellable quality, no filler. Summarize what you made "
                "in 2-3 lines: piece count, formats, and anything a buyer must know."
                + feedback))
            game["build_notes"] = reply.strip()[:600]
            # Verify the pack actually hit the disk before advancing.
            if outdir is not None and not any(
                    p.is_file() and not p.name.startswith(".")
                    for p in outdir.rglob("*")):
                log_event(state, f"build produced no pack files — "
                                 f"retrying next tick: {game['title']}")
                return
            # Asset packs aren't playable in the cabinet — no runtime file.
        else:
            reply = runner("builder", role_prompt("builder",
                f"Build '{game['title']}' as a real, single-file HTML5 game honoring "
                f"these pillars:\n- {pillars}" +
                (f"\nSave it to {outdir}/index.html." if outdir else "") +
                "\nCanvas render loop, touch + keyboard input, WebAudio feedback, a "
                "score and a best-score, and a restart loop. No stubs. Summarize what "
                "you built in 2-3 lines and name the entry file."
                + feedback))
            game["build_notes"] = reply.strip()[:600]
            # Trust nothing: only a real, non-empty index.html on disk advances
            # the stage. A no-show build stays at `build` and retries next tick
            # (the call budget is the runaway guard).
            if outdir is not None:
                built = outdir / "index.html"
                if not built.is_file() or built.stat().st_size == 0:
                    log_event(state, f"build produced no game file — "
                                     f"retrying next tick: {game['title']}")
                    return
            # Record the runtime filename. The flagship keeps its bundled file.
            if not game["runtime"]:
                game["runtime"] = "index.html"
        game["stage"] = "playtest"

    elif stage == "playtest":
        # Playtest choreography: each tester on the couch plays and reports.
        # For asset packs the same panel sits as picky store buyers instead.
        # Testers judge the ACTUAL built code, not the builder's summary.
        game_code = ""
        if not asset and artifacts_root is not None:
            entry = game.get("runtime") or "index.html"
            built = Path(artifacts_root) / _game_dirname(game) / entry
            try:
                raw = built.read_text(errors="replace")
                truncated = len(raw) > PLAYTEST_CODE_CAP
                game_code = (
                    f"\nTHE ACTUAL GAME CODE ({entry}"
                    f"{', truncated' if truncated else ''}):\n"
                    f"```html\n{raw[:PLAYTEST_CODE_CAP]}\n```\n"
                    "Judge the ACTUAL code and mechanics — controls, feel, "
                    "game-over conditions, scoring — not the build notes.")
            except OSError:
                pass
        game["playtests"] = []
        for tester in PLAYTEST_PANEL:
            if asset:
                body = (
                    f"You are {tester}, a picky game developer browsing a store for "
                    f"a {kind} asset pack. Judge '{game['title']}'. "
                    f"Pack pillars:\n- " + "\n- ".join(game["pillars"] or ["(none)"]) +
                    f"\nBuild notes: {game['build_notes']}\n"
                    "Would you pay for this — is it consistent, complete, and easy to "
                    "drop into your engine? React in ONE honest sentence, then give a "
                    "quality rating from 1 to 10 as 'Rating: N/10'.")
            else:
                body = (
                    f"You are {tester}. Play '{game['title']}' ({game['line']}). "
                    f"Design pillars:\n- " + "\n- ".join(game["pillars"] or ["(none)"]) +
                    f"\nBuild notes: {game['build_notes']}\n" + game_code +
                    "\nReact in ONE honest sentence, then give a fun rating from 1 to 10 "
                    "as 'Rating: N/10'.")
            reply = runner("playtester", role_prompt("playtester", body))
            result = parse_playtest(reply)
            result["tester"] = tester
            game["playtests"].append(result)
        game["stage"] = "fun_gate"

    elif stage == "fun_gate":
        avg, count = playtest_scores(game)
        transcript = "\n".join(
            f"{t['tester']}: {t['rating']}/10 — {t['reaction']}"
            for t in game.get("playtests", []))
        if asset:
            body = (
                f"QUALITY GATE for the {kind} asset pack '{game['title']}'. Average "
                f"review score {avg}/10 across {count} reviewers.\nReviews:\n{transcript}\n\n"
                "Decide whether this pack is professional enough to SELL — would a "
                "real studio pay for it and not refund? Give up to 4 bullet reasons, "
                "then end with EXACTLY one line: 'GATE: APPROVED' or 'GATE: REJECTED'.")
        else:
            body = (
                f"FUN GATE for '{game['title']}'. Average playtest score {avg}/10 "
                f"across {count} testers.\nPlaytests:\n{transcript}\n\n"
                "Decide whether this build is fun enough to ship. Give up to 4 bullet "
                "reasons, then end with EXACTLY one line: 'GATE: APPROVED' or "
                "'GATE: REJECTED'.")
        reply = runner("game_designer", role_prompt("game_designer", body))
        passed = fun_gate_passed(reply)
        game["fun_gate"] = {
            "verdict": "APPROVED" if passed else "REJECTED",
            "reasons": parse_fun_reasons(reply),
        }
        gate_name = "Quality Gate" if asset else "Fun Gate"
        if passed:
            game["stage"] = "distribution"
            log_event(state, f"{gate_name} APPROVED: {game['title']}")
        else:
            game["rejections"] = game.get("rejections", 0) + 1
            game["iteration"] = game.get("iteration", 0) + 1
            log_event(state, f"{gate_name} REJECTED: {game['title']} — back to design")
            if game["rejections"] >= MAX_REJECTIONS:
                game["stage"] = "shelved"
                log_event(state, f"shelved after {MAX_REJECTIONS} rejections: {game['title']}")
            else:
                game["stage"] = "design"   # loop back and make it fun

    elif stage == "distribution":
        avg, _ = playtest_scores(game)
        if asset:
            reply = runner("distributor", role_prompt("distributor",
                f"The {kind} asset pack '{game['title']}' passed the Quality Gate "
                f"(avg {avg}/10). Put it up for sale. For each channel — itch.io, "
                "the Roblox Creator Store, and Unity Asset Store / other engine "
                "marketplaces — say whether it is 'live', 'submitted', or 'planned' "
                "and one line on pricing/positioning."))
        else:
            reply = runner("distributor", role_prompt("distributor",
                f"'{game['title']}' passed the Fun Gate (avg {avg}/10). Get it in front "
                "of players. For each channel — itch.io, Reddit, portals — say whether "
                "it is 'live', 'submitted', or 'planned' and one line on the angle."))
        # A REAL publish attempt (butler → itch.io). 'live' only on verified
        # success — never on the agent's say-so.
        itch_url = None
        if not asset:
            outdir = (Path(artifacts_root) / _game_dirname(game)
                      if artifacts_root is not None else None)
            itch_url = publish_itch(game, outdir)
        game["distribution"] = parse_distribution(
            reply, asset=asset, verified=itch_url is not None)
        if itch_url is not None:
            game["distribution"]["itch"] = "live"
            game["itch_url"] = itch_url
            game["distribution_verified"] = True
            log_event(state, f"published to itch.io: {itch_url}")
        else:
            game["distribution_verified"] = False
            log_event(state, f"distribution queued — butler/itch not configured: "
                             f"{game['title']}")
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
            # Paused, not shelved — the game keeps its progress and the owner
            # can resume it later; the tick just stops spending on it.
            game["paused_from"] = game["stage"]   # resume returns exactly here
            game["stage"] = "paused"
            game["paused_note"] = (f"call budget ({DEFAULT_BUDGET}) exhausted — "
                                   "paused, resume to continue")
            events.append(f"{game['id']} paused: budget exhausted")
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


# Budget granted back on resume so a resumed game can actually take a few
# turns instead of instantly re-pausing on the same exhausted budget.
RESUME_TOP_UP_CALLS = 15


def resume_game(state: dict, game_id: str) -> dict:
    """Owner resumes a budget-paused game: back to its pre-pause stage (stored
    in paused_from when it paused; 'build' for legacy pauses) with a small
    budget top-up. Raises KeyError (unknown id) / ValueError (not paused)."""
    game = next((g for g in state.get("games", []) if g["id"] == game_id), None)
    if game is None:
        raise KeyError(game_id)
    if game.get("stage") != "paused":
        raise ValueError(f"game {game_id} is not paused")
    game["stage"] = game.pop("paused_from", "") or "build"
    game.pop("paused_note", None)
    game["calls_used"] = max(0, game.get("calls_used", 0) - RESUME_TOP_UP_CALLS)
    log_event(state, f"resumed: {game['title']} → {game['stage']} "
                     f"(+{RESUME_TOP_UP_CALLS} calls)")
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
