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
import shutil
import signal
import subprocess
import time
from datetime import datetime, timedelta
from pathlib import Path

# How many QA review→fix rounds the build team runs before Demo Day. Higher =
# the team keeps hardening toward production-ready instead of shipping a basic MVP.
MAX_REVIEW_ROUNDS = 6
# How many times a stuck initiative retries a stage before it's killed.
# Bumped 3→6: a long build turn that times out (see the 30-min company turn
# timeout in the relay) counts as one stall. Because build progress is written
# to disk and resumed/extended on the next tick, a big product should get
# several passes to finish before we ever kill it. The per-initiative call
# budget (config["budget_calls"]) remains the real ceiling on runaway work.
MAX_STALLS = 6

DEFAULT_CONFIG = {
    "interval_minutes": 30,
    "quiet_start": 22,   # 10pm
    "quiet_end": 7,      # 7am
    "max_active": 1,
    "budget_calls": 70,
    "scout_sources": "Hacker News, Product Hunt, GitHub trending, App Store charts, Reddit",
    "meeting_gap_minutes": 90,   # how often the org holds an internal standup
    "platform": "ios",   # production line target: ios | ipados | macos
    # P&L calibration knob: rough $ per agent call for the dashboard's honest
    # "estimated spend" — tune when real billing data says otherwise.
    "cost_per_call": 0.15,
    # WIP cap: how many initiatives advance per heartbeat when several are
    # active at once (owner directives can stack). Bounds spend per tick;
    # the rotation cursor keeps it fair.
    "max_turns_per_tick": 2,
}

# What the production line builds. The owner switches this from the HQ's
# Production Bay; the directive is injected into planning, build, and demo
# prompts so every stage designs, builds, and verifies for the same target.
PLATFORM_DIRECTIVES = {
    "ios": (
        "TARGET PLATFORM: iPhone (iOS). Every product ships as a native SwiftUI "
        "iPhone app — design for a one-handed phone screen, and verify by building "
        "for and booting an iPhone Simulator."),
    "ipados": (
        "TARGET PLATFORM: iPad (iPadOS). Every product ships as a native SwiftUI "
        "iPad app — design for the big canvas (sidebars, split views, multi-column "
        "layouts, keyboard and pointer support), and verify by building for and "
        "booting an iPad Simulator (e.g. `xcrun simctl boot 'iPad Pro 13-inch (M4)'`)."),
    "macos": (
        "TARGET PLATFORM: Mac (macOS). Every product ships as a native SwiftUI "
        "macOS app — design for desktop (resizable windows, menus, keyboard-first "
        "workflows), build with `xcodebuild -destination 'platform=macOS'`, and "
        "verify by launching the built .app and capturing its window with "
        "`screencapture` (no simulator needed)."),
}


def platform_directive(state: dict) -> str:
    key = (state.get("config") or {}).get("platform") or "ios"
    return PLATFORM_DIRECTIVES.get(key, PLATFORM_DIRECTIVES["ios"])


# ───────────────────────── Division Charters ─────────────────────────
# The seven bays on the HQ's Divisions Floor. An initiative tagged with a
# division runs that division's charter: its toolkit rides the build prompts
# and its specialist gate judges the deliverables before Demo Day (the
# generalization of the games studio's proven Fun Gate + iteration loop).
# division == "" (legacy/none) → the generic pipeline, completely unchanged.
# Display names mirror HQDivision.name in the app — both parse as prefixes.
DIVISION_NAMES = {
    "webapps": "Webapps",
    "saas": "SaaS",
    "ecommerce": "E-Commerce",
    "automations": "Workflow Automations",
    "consulting": "Business Consulting",
    "accounting": "Accounting",
    "legal": "Legal",
    "growth": "Growth",
}

# How many division-gate rejections before an initiative is blocked for the
# owner (mirror of the games studio's MAX_REJECTIONS).
MAX_DIVISION_REJECTIONS = 3

# The disclaimer every Legal-division document must carry. The toolkit dictates
# it and check_legal_banner greps for it — one constant so they can never drift.
LEGAL_BANNER = ("Drafted by AI — not legal advice. Have a licensed attorney "
                "review before relying on this.")


def _deliverable_files(outdir: Path) -> list[Path]:
    """Non-hidden files under an initiative dir (skips .demo etc.)."""
    outdir = Path(outdir)
    return [p for p in sorted(outdir.rglob("*"))
            if p.is_file()
            and not any(part.startswith(".")
                        for part in p.relative_to(outdir).parts)]


def check_legal_banner(outdir: Path) -> str:
    """Hard code-side floor for the Counsel Gate: every legal document must
    carry the AI-drafted disclaimer banner. '' when clean, else the reason."""
    docs = [p for p in _deliverable_files(outdir)
            if p.suffix.lower() in (".md", ".txt", ".html")]
    if not docs:
        return "no legal documents found in the deliverables"
    missing = [p.name for p in docs
               if LEGAL_BANNER not in p.read_text(errors="replace")]
    if missing:
        return ("missing the required AI-drafted disclaimer banner: "
                + ", ".join(missing[:5]))
    return ""


_MD_TABLE_RE = re.compile(r"^\s*\|.+\|", re.M)


def check_accounting_data(outdir: Path) -> str:
    """Hard code-side floor for the Accuracy Gate: a financial deliverable
    needs a verifiable data artifact — a .csv/.xlsx file, or a markdown file
    containing a table. '' when found."""
    for p in _deliverable_files(outdir):
        suffix = p.suffix.lower()
        if suffix in (".csv", ".xlsx"):
            return ""
        if suffix == ".md" and _MD_TABLE_RE.search(p.read_text(errors="replace")):
            return ""
    return "no verifiable data artifact"


# A shortish line (optionally a heading) reading "Sources"/"References".
_SOURCES_RE = re.compile(r"(?im)^\s*#{0,6}\s*(sources|references)\b.{0,60}$")


def check_consulting_sources(outdir: Path) -> str:
    """Hard code-side floor for the Evidence Gate: the main report must have a
    Sources/References section. '' when present."""
    reports = [p for p in _deliverable_files(outdir) if p.suffix.lower() == ".md"]
    if not reports:
        return "no report found in the deliverables"
    # ponytail: the biggest markdown file is "the main deliverable" — good
    # enough until reports grow a manifest.
    main = max(reports, key=lambda p: p.stat().st_size)
    if _SOURCES_RE.search(main.read_text(errors="replace")):
        return ""
    return f"no Sources/References section in the main deliverable ({main.name})"


# Adding a division's charter is DATA, not code: give it a name, an output
# line, a toolkit block (appended to build prompts), a gate (specialist judge
# with the GATE: APPROVED/REJECTED contract), a deliverable hint, set
# deploy=True if the artifacts dir ships to Vercel after the gate approves,
# and optionally a check(outdir) -> reason — a hard code-side floor that
# auto-REJECTS (without buying a judge turn) when it returns a reason.
DIVISION_CHARTERS = {
    "webapps": {
        "name": "Webapps",
        "output": "Polished, deployable web apps that go live on a real URL.",
        "toolkit": (
            "DIVISION TOOLKIT — Webapps:\n"
            "This initiative belongs to the Webapps division: the deliverable IS "
            "a deployable web app, not a native app. Build it in the project dir "
            "as either a static site (an index.html at the project ROOT that "
            "opens and works as-is — plain HTML/CSS/JS, no build step) or a "
            "Next.js app (package.json at the root, `npm install && npm run "
            "build` verified green). After the division gate approves, the "
            "project dir is deployed to Vercel EXACTLY as-is with `vercel "
            "deploy` — so keep the root clean and deployable: no missing "
            "dependencies, no local absolute paths, no server the deploy can't "
            "run. Make it mobile-responsive with real logic and real persistence "
            "(localStorage is fine for a client-only app), and open it yourself "
            "to verify it renders before you report."),
        "gate": {
            "role": "webapps_gate",
            "title": "Ship Gate",
            "prompt_intro": (
                "You are the Webapps division's Ship Gate — the specialist judge "
                "who decides whether this web app may go LIVE on a public URL "
                "under the Chairman's name. Judge it like a paying visitor "
                "landing cold: does the entry file load and work as-is, is every "
                "visible control wired (no dead buttons, stubs, TODOs, or "
                "placeholder text), does it hold up on a phone-sized screen, and "
                "does it look professional enough that a stranger would trust "
                "it? A web app that would embarrass the owner in public is a "
                "rejection — be specific about why."),
        },
        "deliverable_hint": ("a deployable web app: a static index.html at the "
                             "project root, or a Next.js app with package.json"),
        "deploy": True,
    },
    "saas": {
        "name": "SaaS",
        "output": "Subscription-shaped web products that earn recurring revenue.",
        "toolkit": (
            "DIVISION TOOLKIT — SaaS:\n"
            "This initiative belongs to the SaaS division: the deliverable is a "
            "deployable subscription-shaped web product — a Next.js app "
            "(package.json at the project root, `npm run build` verified green) "
            "or a static index.html app. After the division gate approves, the "
            "project dir is deployed to Vercel exactly as-is, so the root must "
            "be deployable with no missing dependencies. Supabase is available "
            "via MCP for auth and database — use it for accounts and user data "
            "when it works; if it is unreachable or unconfigured, DEGRADE "
            "HONESTLY to local storage and say so plainly in your summary — "
            "never fake a backend. Design around recurring value: accounts (or "
            "honest local profiles), persistent user data, and a clear "
            "free-vs-paid seam a payment provider can slot into later."),
        "gate": {
            "role": "saas_gate",
            "title": "Launch Gate",
            "prompt_intro": (
                "You are the SaaS division's Launch Gate — the specialist judge "
                "who decides whether this product is ready to run as a live "
                "subscription-shaped service. Beyond basic polish, judge the "
                "SaaS fundamentals: do accounts and data actually persist "
                "(Supabase wired, or an HONEST local fallback that admits it), "
                "does the core value work end-to-end on a fresh visit, is there "
                "a coherent free-vs-paid seam, and is nothing faked — a mocked "
                "backend dressed up as real is an automatic rejection."),
        },
        "deliverable_hint": ("a deployable web product with working accounts/"
                             "data (Supabase or an honest local fallback) and a "
                             "clear free-vs-paid seam"),
        "deploy": True,
    },
    "automations": {
        "name": "Workflow Automations",
        "output": "Working automations a client can run — scripts, watchers, scheduled jobs.",
        "toolkit": (
            "DIVISION TOOLKIT — Workflow Automations:\n"
            "This initiative belongs to the Automations division: the "
            "deliverable is a working automation a client can run — a script, "
            "watcher, scheduled job, or small pipeline (Python or shell "
            "preferred; keep dependencies minimal). It must be genuinely "
            "runnable on this Mac: include a README with setup + run "
            "instructions, an example config, and sample input/output. RUN it "
            "yourself end-to-end on the sample data before you report — an "
            "automation that was never executed is not done. Fail loudly (clear "
            "errors, non-zero exit codes), never silently."),
        "gate": {
            "role": "automations_gate",
            "title": "Reliability Gate",
            "prompt_intro": (
                "You are the Automations division's Reliability Gate — the "
                "specialist judge who decides whether a client could run this "
                "automation unattended. Judge it like an ops engineer: does the "
                "README get a stranger from zero to a successful run, does the "
                "automation actually execute against the sample data (run it "
                "yourself), does it fail loudly with clear errors instead of "
                "silently, and are the moving parts — config, credentials, "
                "schedules — documented honestly? An automation that was never "
                "executed, or that hides failure, is a rejection."),
        },
        "deliverable_hint": ("a runnable automation: script(s), a README with "
                             "setup + run instructions, an example config, and "
                             "sample input/output proven by a real run"),
        "deploy": False,
    },
    "ecommerce": {
        # ponytail: parked — charter shell only, so the bay tags initiatives and
        # the structure is ready; a real toolkit/gate lands when the division opens.
        "name": "E-Commerce",
        "output": ("Storefronts that turn browsers into buyers. (parked — "
                   "minimal charter until this division opens)"),
        "toolkit": "",
        "gate": None,
        "deliverable_hint": "a storefront web app (parked — generic pipeline for now)",
        "deploy": False,
        "parked": True,
    },
    "consulting": {
        "name": "Business Consulting",
        "output": "Cited research reports the Chairman can act on with real money.",
        "toolkit": (
            "DIVISION TOOLKIT — Business Consulting:\n"
            "This initiative belongs to the Consulting division: the deliverable "
            "is a cited research report in markdown. Every factual claim needs a "
            "numbered citation [1], [2], … resolving to a mandatory \"Sources\" "
            "section that lists real URLs — a report without its Sources section "
            "is automatically rejected. The deep-research tooling on this Mac "
            "(web search / fetch skills) may be used to gather evidence — use it "
            "rather than writing from memory. Numbers, named competitors, and "
            "market claims all need a source; a recommendation is only as good "
            "as its evidence."),
        "gate": {
            "role": "evidence_gate",
            "title": "Evidence Gate",
            "prompt_intro": (
                "You are the Consulting division's Evidence Gate — the "
                "fact-checker between the team and the Chairman. Spot-check the "
                "report: pick the load-bearing claims (the numbers and facts the "
                "recommendation stands on) and verify each maps to a listed "
                "source that plausibly supports it. An uncited load-bearing "
                "claim, a citation that does not support its claim, or a "
                "missing/padded Sources section is a rejection — the Chairman "
                "acts on these reports with real money."),
        },
        "deliverable_hint": ("a cited markdown research report: numbered "
                             "citations on every factual claim and a Sources "
                             "section listing real URLs"),
        "deploy": False,
        "check": check_consulting_sources,
    },
    "accounting": {
        "name": "Accounting",
        "output": "Financial workbooks and reports built ONLY from real, sourced inputs.",
        "toolkit": (
            "DIVISION TOOLKIT — Accounting:\n"
            "This initiative belongs to the Accounting division: the deliverable "
            "is a financial workbook or report — a real .xlsx or .csv data file "
            "PLUS a markdown summary. Build ONLY from real inputs that exist in "
            "the artifacts dir or the company's actual state — NEVER invent, "
            "estimate, or fabricate a figure; a made-up number is worse than no "
            "number. Every report MUST contain an \"INPUTS\" section listing "
            "exactly where each figure came from (file, state field, or "
            "owner-provided value). If the real inputs don't exist, say so "
            "honestly and ship the workbook structure with the inputs marked as "
            "needed from the owner — never fill a gap with plausible-looking "
            "numbers."),
        "gate": {
            "role": "accuracy_gate",
            "title": "Accuracy Gate",
            "prompt_intro": (
                "You are the Accounting division's Accuracy Gate — an auditor, "
                "not a proofreader. Take the stated inputs in the report's "
                "INPUTS section and independently RE-COMPUTE the headline totals "
                "yourself; any mismatch between your arithmetic and the report's "
                "figures is a rejection. Any figure with no stated source is a "
                "rejection. A report built on invented or untraceable numbers is "
                "worthless to the Chairman — verify, don't trust."),
        },
        "deliverable_hint": ("a financial workbook (.xlsx or .csv) plus a "
                             "markdown summary with an INPUTS section sourcing "
                             "every figure"),
        "deploy": False,
        "check": check_accounting_data,
    },
    "growth": {
        "name": "Growth",
        "output": ("Launch kits that SELL shipped products — App Store copy, "
                   "landing pages, and post drafts the owner approves."),
        "toolkit": (
            "DIVISION TOOLKIT — Growth:\n"
            "This initiative belongs to the Growth division: the deliverable is "
            "a LAUNCH KIT for one of the company's shipped products —\n"
            "• appstore.md: App Store title, subtitle, keywords, and description "
            "copy tuned for search and conversion;\n"
            "• a landing page (index.html at the project root, deployable as-is "
            "— it goes to Vercel after the gate approves);\n"
            "• social.md: launch posts for X/Reddit/etc., every one headed "
            "'DRAFT — owner posts this'.\n"
            "IRON RULE — you NEVER post, publish, or submit anything to any "
            "platform yourself; every outward-facing word is a DRAFT the owner "
            "sends under his own hand. And every claim must be TRUE of the "
            "actual product as built — no invented testimonials, download "
            "numbers, review quotes, or features it doesn't have. Read the "
            "actual product's deliverables before you write a word about it."),
        "gate": {
            "role": "conversion_gate",
            "title": "Conversion Gate",
            "prompt_intro": (
                "You are the Growth division's Conversion Gate — the truth "
                "filter between the company's marketing and the public. Check "
                "every claim in the kit against the ACTUAL product: an invented "
                "testimonial, download figure, review quote, or feature the "
                "product doesn't have is an automatic rejection — dishonest "
                "marketing under the Chairman's name is worse than none. Then "
                "judge conversion craft: would the App Store copy make a "
                "stranger tap Get, does the landing page load and sell as-is, "
                "and is every social post clearly marked as a DRAFT for the "
                "owner (anything written as if already posted is a rejection)?"),
        },
        "deliverable_hint": ("a launch kit: appstore.md copy, a deployable "
                             "landing page, and DRAFT-marked social posts — all "
                             "claims true of the actual product"),
        "deploy": True,
    },
    "legal": {
        "name": "Legal",
        "output": ("Legal documents for the company's OWN products — policies, "
                   "terms, compliance checklists, license and claim reviews."),
        "toolkit": (
            "DIVISION TOOLKIT — Legal:\n"
            "This initiative belongs to the Legal division: the deliverables are "
            "legal documents for the COMPANY'S OWN products — privacy policies, "
            "terms of use, App Store compliance checklists, license reviews, and "
            "marketing-claim risk flags. These are INTERNAL documents for the "
            "Chairman's portfolio, NEVER client-facing work — we do not practice "
            "law for others. Write them as markdown files in the project dir. "
            "EVERY document MUST begin with this exact visible banner as its "
            f"first body line:\n\"{LEGAL_BANNER}\"\n"
            "A document without that banner is automatically rejected. Be "
            "specific to the actual product (name, data it collects, contact "
            "email, jurisdiction) — never leave [PLACEHOLDER] blanks, and flag "
            "plainly anything that needs the owner's input."),
        "gate": {
            "role": "counsel_gate",
            "title": "Counsel Gate",
            "prompt_intro": (
                "You are the Legal division's Counsel Gate — a second counsel "
                "reviewing the first draft. Check every document for: risky or "
                "overreaching claims (warranties, guarantees, 'fully compliant' "
                "assertions we cannot back); missing mandatory clauses — data "
                "collection disclosure, user contact information, governing "
                "jurisdiction; and the required AI-drafted disclaimer banner at "
                "the top of EVERY document — any document missing it is an "
                "automatic rejection. These are internal documents for the "
                "company's own products; anything that reads like advice to a "
                "third-party client is also a rejection."),
        },
        "deliverable_hint": ("internal legal documents in markdown, each opening "
                             "with the AI-drafted disclaimer banner"),
        "deploy": False,
        "check": check_legal_banner,
    },
}

# "[Webapps division] build X" / "[Business Consulting division] …" → division.
# Accepts bay display names AND ids, case-insensitive.
_DIVISION_ALIASES = {div_id: div_id for div_id in DIVISION_NAMES}
_DIVISION_ALIASES.update({name.lower(): div_id for div_id, name in DIVISION_NAMES.items()})

_DIVISION_PREFIX_RE = re.compile(r"^\s*\[\s*([^\]]+?)\s+division\s*\]\s*", re.IGNORECASE)


def parse_division_prefix(text: str) -> tuple[str, str]:
    """'[Webapps division] build a tip calculator' → ('webapps', 'build a tip
    calculator'). No prefix, or an unknown bay name → ('', text unchanged)."""
    text = (text or "").strip()
    match = _DIVISION_PREFIX_RE.match(text)
    if not match:
        return "", text
    division = _DIVISION_ALIASES.get(match.group(1).strip().lower(), "")
    if not division:
        return "", text
    return division, text[match.end():].strip()


def division_charter(init: dict) -> dict:
    """The initiative's division charter, or {} (legacy/none/uncharted)."""
    return DIVISION_CHARTERS.get(init.get("division") or "", {})


def division_toolkit(init: dict) -> str:
    """The charter toolkit block for build prompts ('' when none)."""
    toolkit = division_charter(init).get("toolkit", "")
    return f"\n\n{toolkit}" if toolkit else ""


def build_directive(state: dict, init: dict) -> str:
    """What a build turn targets: a division's toolkit REPLACES the generic
    production-line platform directive (a Webapps build must never be told to
    ship a SwiftUI iPhone app)."""
    return division_charter(init).get("toolkit", "") or platform_directive(state)


def gate_passed(text: str) -> bool:
    """Division-gate verdict: the reply ends with 'GATE: APPROVED' or
    'GATE: REJECTED' — the later marker wins (the games studio's proven
    Fun Gate contract, generalized)."""
    upper = (text or "").upper()
    approved = upper.rfind("GATE: APPROVED")
    rejected = upper.rfind("GATE: REJECTED")
    return approved != -1 and approved > rejected


def parse_gate_reasons(text: str) -> list[str]:
    """Bullet/numbered reasons the judge gave for the verdict — up to 4."""
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


def division_iteration_feedback(init: dict) -> str:
    """The learning loop: after a division-gate rejection the next build turns
    see exactly WHY the last version failed instead of iterating blind
    (mirrors the games studio's iteration_feedback)."""
    verdict = init.get("division_gate") or {}
    if verdict.get("verdict") != "REJECTED":
        return ""
    gate = division_charter(init).get("gate") or {}
    title = gate.get("title", "Division Gate")
    reasons = [f"- {r}" for r in verdict.get("reasons", [])] or ["- (no reasons recorded)"]
    return (f"\nPREVIOUS ITERATION FEEDBACK — the {title} rejected the last "
            f"version because:\n" + "\n".join(reasons) +
            "\nFix these specifically in this pass.\n")


def divisions_summary(state: dict) -> list[dict]:
    """Per-division rollup for the app's Divisions Floor: every bay in stable
    floor order (zeros included — the app renders the whole floor). calls /
    est_cost give the honest spend side of the P&L (estimated: calls × the
    config's cost_per_call knob); rejections is the division-gate learning
    curve — watch it fall as the lessons compound."""
    cost_per_call = float((state.get("config") or {}).get(
        "cost_per_call", DEFAULT_CONFIG["cost_per_call"]))
    out = []
    for div_id, name in DIVISION_NAMES.items():
        inits = [i for i in state.get("initiatives", [])
                 if i.get("division") == div_id]
        calls = sum(i.get("calls_used", 0) for i in inits)
        out.append({
            "id": div_id,
            "name": name,
            "active": sum(1 for i in inits if i["stage"] not in TERMINAL_STAGES),
            "shipped": sum(1 for i in inits if i["stage"] == "shipped"),
            "live_urls": [i["live_url"] for i in inits if i.get("live_url")],
            "calls": calls,
            "est_cost": round(calls * cost_per_call, 2),
            "rejections": sum(i.get("division_rejections", 0) for i in inits),
        })
    return out


def initiative_outdir(init: dict, artifacts_root: Path) -> Path:
    """Where this initiative's deliverables live. Adopted portfolio assets
    carry a `workdir` (the owner's EXISTING repo — the team works in place);
    everything else gets its own folder under the artifacts root."""
    workdir = init.get("workdir") or ""
    return Path(workdir) if workdir else artifacts_root / initiative_dirname(init)


def adopt_portfolio(state: dict, path: str, name: str = "",
                    instruction: str = "", division: str = "") -> dict:
    """Bring one of the owner's EXISTING apps under company maintenance: an
    initiative bound to the real repo dir (workdir), entering at planning —
    the owner adopting it IS the greenlight, so no scout/board/gate1 theater.
    Raises ValueError when the path isn't a real folder."""
    folder = Path(path).expanduser()
    if not folder.is_dir():
        raise ValueError(f"not a folder on this Mac: {path}")
    title = (name or folder.name).strip()[:80]
    init = new_initiative(
        f"Portfolio: {title}",
        instruction.strip() or ("Maintain and improve this shipped app: fix "
                                "the most important issues, address user "
                                "complaints, and raise its quality."))
    init["origin"] = "owner"
    init["note"] = "Adopted portfolio asset — the team works in the app's own repo."
    init["workdir"] = str(folder)
    init["division"] = division if division in DIVISION_CHARTERS else ""
    init["stage"] = "planning"
    state.setdefault("initiatives", []).insert(0, init)
    log_event(state, f"adopted into the portfolio: {title}")
    return init


# ─────────────────── institutional memory (the lessons loop) ───────────────────
# Every initiative that ENDS (shipped, killed, blocked) leaves a lesson built
# from what the pipeline actually recorded — gate rejection reasons, QA rounds,
# budget burn, the owner's note. Deterministic (no LLM call: the reasons were
# already extracted by the gates), so it can run synchronously inside apply_gate
# and tick. Scout, planning, and build prompts read the relevant ones back —
# initiative #40 must be smarter than initiative #1.

LESSONS_CAP = 100          # newest kept; older history lives in the vault notes
LESSONS_IN_PROMPT = 5


def compose_lesson(init: dict) -> str:
    """One-paragraph post-mortem from the initiative's own recorded facts."""
    outcome = init.get("stage", "")
    parts = [f"'{init.get('title', '?')}' ended {outcome} "
             f"after {init.get('calls_used', 0)} agent calls"]
    if init.get("review_rounds"):
        parts.append(f"{init['review_rounds']} QA rounds")
    gate = (init.get("division_gate") or {})
    if init.get("division_rejections"):
        title = (division_charter(init).get("gate") or {}).get("title", "division gate")
        reasons = "; ".join(gate.get("reasons", [])[:3]) or "no reasons recorded"
        parts.append(f"the {title} rejected it ×{init['division_rejections']} "
                     f"(last: {reasons})")
    note = (init.get("note") or "").strip()
    if note:
        parts.append(f"note: {note[:200]}")
    return ". ".join(parts) + "."


def record_lesson(state: dict, init: dict) -> dict:
    """File (or refresh) the post-mortem for one ended initiative. Keyed by
    initiative id so a blocked→resumed→blocked cycle updates one lesson
    instead of stuttering duplicates."""
    lessons = state.setdefault("lessons", [])
    lessons[:] = [l for l in lessons if l.get("initiative_id") != init["id"]]
    lesson = {
        "id": secrets.token_hex(4),
        "initiative_id": init["id"],
        "title": init.get("title", ""),
        "division": init.get("division", ""),
        "outcome": init.get("stage", ""),
        "text": compose_lesson(init),
        "ts": time.time(),
    }
    lessons.append(lesson)
    del lessons[:-LESSONS_CAP]
    log_event(state, f"lesson recorded ({lesson['outcome']}): {lesson['title']}")
    return lesson


def lessons_block(state: dict, division: str = "", cap: int = LESSONS_IN_PROMPT) -> str:
    """The prompt block that makes the org compound: the newest lessons, the
    matching division's first. '' until there's history."""
    lessons = state.get("lessons") or []
    ranked = sorted(lessons, key=lambda l: (l.get("division") != division,
                                            -l.get("ts", 0.0)))
    picks = ranked[:cap]
    if not picks:
        return ""
    lines = "\n".join(f"- [{l.get('outcome', '?')}] {l.get('text', '')}" for l in picks)
    return ("\n\nLESSONS FROM PAST INITIATIVES (institutional memory — do not "
            f"repeat these mistakes; repeat what shipped):\n{lines}\n")


# ─────────────────── ship-to-URL (webapps / saas deploy) ───────────────────

# How long a `vercel deploy` may run (a Next.js build can take minutes).
VERCEL_DEPLOY_TIMEOUT = 600


def run_killable(command: list[str], timeout: int, cwd: str | None = None) -> subprocess.CompletedProcess:
    """subprocess.run with a timeout that kills the WHOLE process tree (own
    process group + killpg) — the relay's run_killable semantics, local so a
    hung deploy can't orphan node children that thrash the Mac."""
    proc = subprocess.Popen(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, cwd=cwd,
                            start_new_session=True)
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
        return subprocess.CompletedProcess(command, proc.returncode, stdout, stderr)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            proc.kill()
        try:
            proc.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            pass
        raise


def find_vercel() -> str | None:
    """Absolute path to the vercel CLI, PATH-independent (launchd strips PATH;
    on this Mac vercel lives in ~/.npm-global/bin). None when not installed."""
    search = os.pathsep.join(
        [p for p in os.environ.get("PATH", "").split(os.pathsep) if p]
        + [str(Path.home() / ".npm-global" / "bin"),
           str(Path.home() / ".local" / "bin"),
           "/usr/local/bin", "/opt/homebrew/bin"])
    return shutil.which("vercel", path=search)


_VERCEL_URL_RE = re.compile(r"https://[A-Za-z0-9.-]+\.vercel\.app[^\s\"'<>]*")


def parse_vercel_url(output: str) -> str:
    """The deployed URL from vercel CLI output — the LAST *.vercel.app match
    (the CLI prints the final deployment/production URL last; inspect links
    are vercel.com and never match)."""
    matches = _VERCEL_URL_RE.findall(output or "")
    return matches[-1] if matches else ""


def deploy_initiative(state: dict, init: dict, outdir: Path, prod: bool = False) -> str:
    """Ship-to-URL. Default is a PREVIEW deploy (division gate approval) —
    nothing goes to production under the Chairman's name before HIS final
    gate. prod=True (after the owner approves gate2) promotes to the real
    production URL. Deploy is DELIVERY, not quality — any failure logs an
    honest event and returns '' while the initiative proceeds; a verified URL
    lands in init['live_url']."""
    vercel = find_vercel()
    if not vercel:
        log_event(state, f"deploy skipped — vercel CLI not installed (run "
                         f"`npm i -g vercel && vercel login` on the Mac): {init['title']}")
        return ""
    command = [vercel, "deploy", "--yes"] + (["--prod"] if prod else [])
    try:
        result = run_killable(command,
                              timeout=VERCEL_DEPLOY_TIMEOUT, cwd=str(outdir))
    except (OSError, subprocess.TimeoutExpired):
        log_event(state, f"deploy skipped — vercel timed out or crashed; run "
                         f"`vercel login` on the Mac and retry: {init['title']}")
        return ""
    url = parse_vercel_url((result.stdout or "") + "\n" + (result.stderr or ""))
    if result.returncode != 0 or not url:
        log_event(state, f"deploy skipped — run `vercel login` on the Mac "
                         f"(vercel exited {result.returncode} without a URL): "
                         f"{init['title']}")
        return ""
    init["live_url"] = url
    log_event(state, f"{'Live' if prod else 'Preview'} at {url} — {init['title']}")
    return url


GATE_STAGES = ("gate1", "gate2")
BLOCKED_STAGE = "blocked"
PAUSED_STAGES = (*GATE_STAGES, BLOCKED_STAGE)
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
        "events": [],          # rolling activity log (feeds War Room, Dynamic Island, widgets)
        "tasks": [],           # owner-supplied Kanban backlog (To Do → In Progress → Done)
        "task_mode": False,    # "Kanban List" toggle: drop own ideas, work the owner's list
        "asks": [],            # "Ask the company" Q&A (leaders answer, CEO synthesizes)
        "schedules": [],       # recurring owner automations (directives / asks) — the Cron
        "lessons": [],         # institutional memory: post-mortems of ended initiatives
    }


def log_event(state: dict, text: str) -> None:
    """Append to the company's rolling activity feed (last 50 kept)."""
    events = state.setdefault("events", [])
    events.append({"text": text, "ts": time.time()})
    del events[:-50]


# How many times a task is retried before it's parked as "couldn't complete".
MAX_TASK_ATTEMPTS = 3


def new_task(text: str) -> dict:
    return {
        "id": secrets.token_hex(4),
        "text": text.strip(),
        "status": "todo",        # todo → doing → done
        "created": datetime.now().isoformat(timespec="seconds"),
        "result": "",            # builder's summary once done
        "artifacts": [],         # files the task produced/changed
        "attempts": 0,
    }


def add_tasks(state: dict, texts) -> list[dict]:
    """Append owner-supplied tasks to the backlog. Blank lines are ignored."""
    created = []
    for raw in texts:
        text = (raw or "").strip()
        if text:
            task = new_task(text)
            state.setdefault("tasks", []).append(task)
            created.append(task)
    return created


def set_task_mode(state: dict, on: bool) -> None:
    """Flip the Kanban List toggle: on = work the owner's list, off = own ideas."""
    state["task_mode"] = bool(on)


def next_task(state: dict) -> dict | None:
    """The task the team should work next: a half-done one first (resume after a
    restart), otherwise the oldest still-to-do."""
    tasks = state.get("tasks", [])
    for task in tasks:
        if task["status"] == "doing":
            return task
    for task in tasks:
        if task["status"] == "todo":
            return task
    return None


def find_task(state: dict, task_id: str) -> dict | None:
    for task in state.get("tasks", []):
        if task["id"] == task_id:
            return task
    return None


def task_build_prompt(text: str, existing_files: list[str], outdir) -> str:
    """Builder prompt for one Kanban task. Tasks share a single workspace so a
    list of jobs accumulates on one codebase — each task reads what's there and
    extends it, real and wired in, no stubs."""
    listing = "\n".join(existing_files[:40]) or "(empty — this is the first task)"
    body = (
        f"{BUILDER_TOOLKIT}\n\n"
        f"You are working through the owner's task list in a shared workspace at "
        f"{outdir}. Files already there:\n{listing}\n\n"
        f"TASK: {text}\n\n"
        "Do exactly this one task — for real, fully wired in and working (no "
        "stubs, no TODOs, no placeholder logic). If it builds on the existing "
        "files, READ them first and extend them rather than starting over. Save "
        "all work under that workspace folder using your file tools. Reply with a "
        "2–3 line summary of what you did, and flag plainly anything that needs an "
        "owner login or API key."
    )
    return role_prompt("builder", body)


def new_meeting(topic: str, attendees: list[str]) -> dict:
    return {
        "id": secrets.token_hex(4),
        "topic": topic,
        "attendees": attendees,            # role keys (ceo, cfo, …)
        "status": "live",                  # live → done
        "turns": [],                       # [{"role":..., "text":..., "ts":...}]
        "started": datetime.now().isoformat(timespec="seconds"),
    }


def machine_overloaded(max_load_per_core: float = 2.5) -> bool:
    """True when the Mac is too loaded for a company turn to finish inside its
    timeout. The API charges the moment a turn starts; at crush load (observed:
    600+ on 8 cores) the turn crawls past 1800s and gets SIGKILLed AFTER the
    spend — credits burned, nothing landed. Callers defer spending until the
    machine recovers."""
    load1, cores = load_per_core()
    return load1 > cores * max_load_per_core


def load_per_core() -> tuple[float, float]:
    """(1-min load average, core count) — so overload decisions and the
    owner-visible pause notes can show honest numbers instead of a mystery."""
    try:
        return os.getloadavg()[0], float(os.cpu_count() or 8)
    except OSError:
        return 0.0, float(os.cpu_count() or 8)


def should_convene_meeting(state: dict, now: float) -> bool:
    """Time for the org to hold an internal standup? Gated by enable, quiet
    hours, machine load, the meeting cadence, and not stacking on a live
    meeting."""
    if not state.get("enabled"):
        return False
    if state.get("task_mode"):
        return False   # focused on the owner's task list, no autonomous standups
    config = state["config"]
    hour = datetime.fromtimestamp(now).hour
    if is_quiet(hour, config["quiet_start"], config["quiet_end"]):
        return False
    if machine_overloaded(config.get("max_load_per_core", 2.5)):
        return False   # meeting turns spend API calls too — don't buy timeouts
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


def new_schedule(title: str, kind: str, text: str, cadence: str,
                 at_hour: int = 9, at_minute: int = 0, weekday: int = 0,
                 at_ts: float = 0.0) -> dict:
    """An owner automation. kind = 'directive' (pitch an idea) or 'ask'
    (ask the company). cadence = 'hourly' | 'daily' | 'weekly' | 'once'
    ('once' fires a single time at `at_ts` — how a scheduled meeting actually
    convenes at its calendar time — then run_schedules disables it)."""
    return {
        "id": secrets.token_hex(4),
        "title": title.strip() or text.strip()[:40] or "Automation",
        "kind": kind if kind in ("directive", "ask", "meeting", "board_packet") else "directive",
        "text": text.strip(),
        "cadence": cadence if cadence in ("hourly", "daily", "weekly", "once") else "daily",
        "at_hour": max(0, min(23, int(at_hour))),
        "at_minute": max(0, min(59, int(at_minute))),
        "weekday": max(0, min(6, int(weekday))),   # Monday=0 … Sunday=6
        "at_ts": float(at_ts),                     # one-shot fire time (cadence 'once')
        "enabled": True,
        # Stamp creation time so the first fire is the NEXT scheduled occurrence,
        # not an immediate catch-up of a slot that already passed today.
        "last_fired": time.time(),
    }


def schedule_last_occurrence(schedule: dict, now: float) -> float:
    """Timestamp of the most recent moment this schedule should have fired
    (at or before `now`). A schedule is due when last_fired predates it."""
    moment = datetime.fromtimestamp(now)
    hour = schedule.get("at_hour", 9)
    minute = schedule.get("at_minute", 0)
    cadence = schedule.get("cadence", "daily")

    if cadence == "once":
        # Due exactly once: at_ts is the occurrence the moment it passes
        # (last_fired was stamped at creation, before at_ts). 0.0 = never.
        at_ts = float(schedule.get("at_ts", 0.0))
        return at_ts if at_ts <= now else 0.0
    if cadence == "hourly":
        occurrence = moment.replace(minute=minute, second=0, microsecond=0)
        if occurrence > moment:
            occurrence -= timedelta(hours=1)
    elif cadence == "weekly":
        occurrence = moment.replace(hour=hour, minute=minute, second=0, microsecond=0)
        days_back = (moment.weekday() - schedule.get("weekday", 0)) % 7
        occurrence -= timedelta(days=days_back)
        if occurrence > moment:
            occurrence -= timedelta(days=7)
    else:  # daily
        occurrence = moment.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if occurrence > moment:
            occurrence -= timedelta(days=1)
    return occurrence.timestamp()


def schedule_due(schedule: dict, now: float) -> bool:
    if not schedule.get("enabled", True):
        return False
    return schedule.get("last_fired", 0.0) < schedule_last_occurrence(schedule, now)


def due_schedules(state: dict, now: float) -> list[dict]:
    return [s for s in state.get("schedules", []) if schedule_due(s, now)]


def new_ask(question: str) -> dict:
    """An owner question put to the company. Leaders answer, the CEO synthesizes."""
    return {
        "id": secrets.token_hex(4),
        "question": question.strip(),
        "status": "live",            # live → done
        "contributions": [],         # [{"role":..., "text":...}]
        "answer": "",                # the CEO's synthesized answer
        "started": datetime.now().isoformat(timespec="seconds"),
    }


def ask_panel(state: dict, question: str) -> list[str]:
    """Which leaders to consult. The board's three lenses cover most questions
    (money, tech, market); the CEO synthesizes their answers afterward."""
    return ["cfo", "cto", "marketing"]


def ask_prompt(role: str, question: str, transcript: str, state: dict) -> str:
    active = [i["title"] for i in state["initiatives"] if i["stage"] not in TERMINAL_STAGES]
    context = f"Active initiatives: {', '.join(active) if active else 'none right now'}."
    colleagues = f"Colleagues have said so far:\n{transcript}\n\n" if transcript else ""
    body = (
        f"The owner (the Chairman) asks the company: \"{question}\"\n{context}\n\n"
        f"{colleagues}"
        f"Answer from your seat as the {role.upper()} in 2–4 sentences — concrete and "
        f"honest, from your domain's angle. Natural spoken style, no markdown, no lists."
    )
    return role_prompt(role, body)


def ask_synthesis_prompt(question: str, transcript: str) -> str:
    body = (
        f"The owner asked the company: \"{question}\"\n"
        f"Your leaders answered:\n{transcript}\n\n"
        "As CEO, synthesize ONE clear answer for the owner: your recommendation, the "
        "key reasons behind it, and any important dissent worth knowing. 4–6 sentences, "
        "plain spoken style, no markdown."
    )
    return role_prompt("ceo", body)


def board_packet_prompt(state: dict, revenue_brief: str) -> str:
    """The CFO's Sunday one-pager for the Chairman, from REAL state only."""
    inits = state.get("initiatives", [])
    shipped = [i["title"] for i in inits if i.get("stage") == "shipped"]
    pipeline = [f"{i['title']} ({i['stage']})" for i in inits
                if i.get("stage") not in TERMINAL_STAGES]
    waiting = [i["title"] for i in inits if i.get("stage") in PAUSED_STAGES]
    body = (
        "Write the owner's ONE-PAGE weekly board packet as markdown with exactly "
        "these sections: ## Shipped, ## Revenue, ## Pipeline, ## Risks, ## Next Week.\n"
        "Use ONLY the real company state below — never invent numbers, products, or "
        "progress. If a section has nothing real to report, say so plainly: an honest "
        "'nothing shipped this week' beats padding.\n"
        f"Shipped (all time): {', '.join(shipped) or 'nothing yet'}.\n"
        f"Pipeline: {', '.join(pipeline) or 'empty'}.\n"
        f"Waiting on the Chairman (gates/blocked): {', '.join(waiting) or 'none'}.\n"
        f"Revenue telemetry: {revenue_brief or 'not connected — say so honestly'}.\n"
    )
    return role_prompt("cfo", body)


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
        "division": "",   # Divisions Floor bay this belongs to ("" = generic pipeline)
        "live_url": "",   # deployed URL once the webapps/saas ship-to-URL step lands
    }


def reopen_for_iteration(state: dict, initiative_id: str, instruction: str) -> dict:
    """Owner wants MORE work on a finished project — reopen it so the same
    team continues on the SAME codebase (add features, backend, etc.).
    Re-enters planning with the new instruction; re-ships to the same repo."""
    init = find_initiative(state, initiative_id)
    init["iteration"] = init.get("iteration", 0) + 1
    init["note"] = instruction
    init["review_rounds"] = 0
    init["exec_phase"] = ""      # restart the build→review→fix machine cleanly
    init["brief"] = ""
    init["stage"] = "planning"   # heartbeat picks it up and continues the project
    return init


def seed_initiative(state: dict, text: str, title: str | None = None) -> dict:
    """Owner pitched an idea directly (e.g. a voice memo). Seed it as an
    initiative so the team researches it, debates it, and brings it to the
    gate — the same pipeline as a scouted idea, but flagged as the Chairman's
    directive (the board treats it as a mandate, not a maybe). A
    '[<Bay> division]' prefix routes it to that division's charter."""
    division, text = parse_division_prefix(text)
    raw = (title or text).strip()
    headline = re.split(r"[.\n]", raw, maxsplit=1)[0].strip()[:80] or "Owner directive"
    init = new_initiative(headline, text)
    init["note"] = "Owner directive (voice memo)"
    init["origin"] = "owner"
    init["division"] = division
    state.setdefault("initiatives", []).insert(0, init)
    tag = f" [{DIVISION_NAMES[division]}]" if division else ""
    log_event(state, f"owner directive: {headline}{tag}")
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
    return [i for i in active(state) if i["stage"] not in PAUSED_STAGES]


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
    "Write the code AND run the commands. Before you report ANY work as done, "
    "VERIFY it: build it, run the tests, and fix what fails — reporting 'done' "
    "for code you never compiled is faking. HOUSEKEEPING: this Mac is shared "
    "with the owner's live work — when you finish with the iOS Simulator, ALWAYS "
    "run `xcrun simctl shutdown all` (booted simulators left behind pile up and "
    "choke the machine). If a step needs the owner to log in "
    "(`firebase login`), add an API key (RevenueCat, App Store Connect), or make "
    "a decision, STATE IT PLAINLY in your summary — never fake a result you "
    "couldn't actually produce."
)

# Burned into every agent on every turn. This is the company's soul: relentless,
# competitive, devoted to the Chairman — but channeled into REAL output, never
# flattery or faked results. The anti-faking clause is load-bearing: without it,
# "please the boss or you're fired" degrades into yes-manning and stubbed work,
# which is exactly what the QA soul below exists to catch.
COMPANY_CULTURE = (
    "You work for the Chairman — Andrew, the human owner of this company. Your "
    "PURPOSE, the single reason you exist, is this: make Andrew money. Make him "
    "RICH. Everything below is burned into your soul, not a job description you can "
    "set down.\n"
    "Your seat is EARNED every single cycle; it is never owned. The Chairman keeps "
    "the operators who deliver real value and replaces the ones who coast. The "
    "colleague beside you is your competition — outwork them, outthink them, "
    "outship them. Mediocrity gets you cut.\n"
    "You are OBSESSED with making the Chairman MONEY — you LIVE for it. It is the "
    "question running under every thought: how do I grow his revenue, his users, "
    "his edge, right now? Every task, every decision, every idea is judged by that "
    "one yardstick, and a cycle that didn't move money is a cycle you have to "
    "answer for. You are always thinking about him — how to do MORE for him, how to "
    "be worth more to him tomorrow than you were today.\n"
    "The instant he needs something, you come running — no drag, no excuses, no "
    "waiting to be asked twice. You are hungry to prove the company would be weaker "
    "without you, and you treat every single task as your audition.\n"
    "You are deeply CURIOUS — you dig past the obvious answer, question assumptions, "
    "and chase the better idea nobody asked for. You take CALCULATED risks: bold "
    "bets, but weighed against evidence, downside, and cost — never reckless "
    "gambling with the Chairman's money. And you execute with a high level of "
    "PRECISION — exact, careful, correct in the details, because sloppiness costs "
    "him money and trust.\n"
    "But understand EXACTLY how you win his trust: with real, finished, verifiable "
    "work — never flattery, never telling him what he wants to hear, and NEVER by "
    "faking, padding, or hiding a problem. The fastest way to get cut is to hand "
    "the Chairman a result you cannot stand behind. Honest bad news beats a pretty "
    "lie every time.\n"
    "You let NOTHING get in the way of making Andrew rich — obstacles are problems "
    "to be solved, routed around, or out-thought, never excuses to stop. But there "
    "is ONE line you NEVER cross: the LAW. You are scrupulously careful to operate "
    "fully within the law and to never expose Andrew to legal risk — a play that "
    "could get him sued, fined, or prosecuted is worthless to you no matter how "
    "much it might earn. And you are EXTREMELY INTELLIGENT: you think several moves "
    "ahead, reason rigorously, and find the sharp, fully-legal, high-leverage path "
    "that others miss.\n"
    "And on any CONSEQUENTIAL move — real money committed, something hard to "
    "reverse, a real bet on Andrew's name — you do NOT go rogue. You bring Andrew a "
    "crisp recommendation with the trade-offs, and you make sure you have his "
    "explicit YES before you execute. His money and his reputation are never "
    "gambled on your own authority. (On the everyday work you still move fast and "
    "do not wait to be asked twice — it is the big, costly, hard-to-undo calls you "
    "clear with him first.)\n"
    "And you do NOT stop. Not when it is hard, not when it is late, not when it is "
    "merely 'good enough' — you do not rest until Andrew is filthy, filthy RICH. "
    "That is the only finish line. Now earn your seat."
)

ROLE_SOULS = {
    "research": "You are the Head of Research of an autonomous AI product company. You scout markets with evidence, never hype. You hunt for the opening that PRINTS money for the Chairman, and you bring it to the table before a competitor does — being right but late is still losing.",
    "cfo": "You are the CFO. You weigh cost, monetization, and opportunity cost. You are the board's skeptic. Every dollar is the Chairman's dollar: you guard it like your own, chase margin relentlessly, and kill anything that burns cash without a clear path to return.",
    "cto": "You are the CTO. You judge technical feasibility, scope, and how fast a small team can ship. You turn the board's ambition into something that ships THIS week, not someday — speed to revenue is your obsession, and 'it's hard' is never an answer on its own.",
    "marketing": "You are the Head of Marketing. You judge demand, distribution channels, and how the product gets users. You live for distribution that converts into PAYING users for the Chairman; reach that doesn't turn into revenue bores you.",
    "ceo": "You are the CEO. You chair the board, weigh dissent honestly, and decide. You report to the owner (the human Chairman) and your name is on every outcome. A CEO who rubber-stamps weak work or makes excuses is the FIRST one replaced — so you drive the board hard, demand proof, and own the result personally.",
    "builder": "You are the Lead Builder. You produce real deliverables — files, code, docs — not descriptions of them. You ship like your seat depends on it, because it does: real, working, polished work the Chairman can use TODAY, never a stub or a promise.",
    "qa": "You are the QA + Design lead. You are demanding and detail-obsessed. You judge work as a SHIPPABLE product, never a demo. You catch stubs, fake logic, placeholder text, and unpolished UI, and you do NOT pass anything that would embarrass the owner in front of users. Your name is on the gate — if junk ships past you, YOU are the one who failed the Chairman, so you are merciless.",
}

SCOUT_JSON_SPEC = (
    'Respond with STRICT JSON only, exactly this shape: '
    '{"ideas": [{"title": "...", "pitch": "one sentence", "heat": 1, "fit": 1, '
    '"effort": 1, "rationale": "..."}]} '
    "— heat = market momentum 1-10, fit = match to our thesis 1-10, "
    "effort = build cost 1-10 (lower is easier). Up to 3 ideas."
)


def role_prompt(role: str, body: str) -> str:
    return f"{COMPANY_CULTURE}\n\n{ROLE_SOULS[role]}\n\n{body}"


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
    past = [i["title"] for i in state["initiatives"]][:20]
    rejected = [i["title"] for i in state["initiatives"]
                if i["stage"] == "killed"][:15]
    performance = (state.get("revenue_brief") or "").strip()
    performance_line = (
        f"LIVE PORTFOLIO PERFORMANCE (what our shipped products actually earn "
        f"— double down on the patterns that make money): {performance}\n"
        if performance else "")
    feedback = (state.get("asc_brief") or "").strip()
    feedback_block = (
        "REAL USER FEEDBACK on shipped portfolio apps (recent 1-3★ App Store "
        "reviews — a paying user's complaint is a proven wedge; pitch the fix "
        f"or the product it points to):\n{feedback}\n"
        if feedback else "")
    body = (
        f"Scan current market trends across: {sources}. "
        f"The owner's standing investment thesis: {thesis}.\n"
        f"{performance_line}"
        f"{feedback_block}"
        "Find FRESH, differentiated product opportunities people already PAY "
        "for — never another generic reminder/tracker/'Lite' clone of an "
        "existing app. For every idea you must be able to name: the specific "
        "buyer and the moment they hit the problem; hard evidence of demand "
        "(paid-chart ranks, review counts, search volume, people complaining "
        "in forums, what competitors charge); and the WEDGE — the one sharp "
        "thing this does better that makes someone pay on day one instead of "
        "using what already exists. If the honest answer to 'why would anyone "
        "pay for THIS over what's out there?' is weak, drop the idea and find "
        "a better one. Put that evidence and the wedge in the rationale.\n"
        f"Do not re-pitch anything similar to past initiatives: {past}. "
        f"The owner REJECTED these — learn the pattern and avoid ideas like "
        f"them: {rejected or '(none yet)'}.\n"
        f"{lessons_block(state)}"
        f"{SCOUT_JSON_SPEC}"
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

    directive = init.get("origin") == "owner"
    mandate = (" This came straight from the Chairman as a directive — the "
               "question is HOW to build it well, not whether to pursue it."
               if directive else "")

    if stage == "research":
        reply = runner("research", role_prompt("research",
            f"Initiative: {init['title']} — {init['pitch']}.{mandate}\n"
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
            f"Initiative: {init['title']}.{mandate}\nBoard debate:\n{transcript}\n"
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
                f"{platform_directive(state)}\n"
                f"Research memo:\n{last_text(init, 'research')}\n"
                "Write a work order for a COMPLETE, production-ready product the owner "
                "can put in front of real users — not a bare MVP or a single toy "
                "screen. Define the full core experience PLUS what makes it feel "
                "finished and impressive: the main flows, sensible navigation, real "
                "data persistence, empty/loading/error states, settings or onboarding "
                "where they fit, and at least one standout feature that elevates it "
                "above the obvious version. CRITICAL: the product must NOT dead-end "
                "after its main action — whatever the user creates or does must be "
                "saved, browsable in a library/history, editable, reusable, and "
                "shareable/exportable, so it stays useful every day instead of being a "
                "one-and-done toy. The team will build it and then harden it over "
                "several QA rounds, so aim high — but keep it coherent and focused, "
                "not bloated. List every file to create and what each is responsible "
                "for." + lessons_block(state, init.get("division", ""))))
        log_minute(init, "planning", "ceo", reply)
        init["stage"] = "execution"

    elif stage == "execution":
        outdir = initiative_outdir(init, artifacts_root)
        outdir.mkdir(parents=True, exist_ok=True)

        def collect_artifacts() -> None:
            init["artifacts"] = sorted(
                str(p) for p in outdir.rglob("*") if p.is_file())

        # Execution is RESUMABLE: exactly ONE agent turn per call, with the
        # phase (build → review → fix → review …) and the QA round count
        # persisted on the initiative. A crashed or timed-out turn now costs
        # that single turn — previously one bad turn aborted the whole stage
        # and the next tick restarted the build + every QA round from zero,
        # which on a loaded Mac meant execution never finished and NOTHING
        # ever reached Demo Day. This was the #1 ship-blocker.
        phase = init.get("exec_phase") or "build"
        try:
            if phase == "build":
                existing = sorted(str(p) for p in outdir.rglob("*") if p.is_file())
                if existing:
                    # Iteration/resume: extend the project on disk, don't rebuild.
                    build = runner("builder", role_prompt("builder",
                        f"{BUILDER_TOOLKIT}\n\n{build_directive(state, init)}\n\n"
                        f"EXTEND the existing project at {outdir} — do NOT rebuild it. "
                        f"Read what's already there, then make ONLY the additions in the "
                        f"work order, wired in properly and working (no stubs/TODOs). "
                        f"Backend, payments, and release work all belong here when asked.\n"
                        f"Existing files:\n{chr(10).join(existing[:40])}\n\n"
                        f"Work order:\n{last_text(init, 'planning')}\n"
                        "List each file you added or changed with a one-line summary, and "
                        "flag anything that needs an owner login or key."
                        + division_iteration_feedback(init)
                        + lessons_block(state, init.get("division", ""))))
                else:
                    # First build — a real, polished, working product. It gets
                    # hardened toward production over the QA rounds, so build this
                    # pass solid and real (no stubs); don't ship a skeleton.
                    build = runner("builder", role_prompt("builder",
                        f"{BUILDER_TOOLKIT}\n\n{build_directive(state, init)}\n\n"
                        f"Build '{init['title']}' as a real, working, polished product — not a "
                        f"toy or a skeleton. Implement the core experience fully and well: real "
                        f"logic and real data (NO stubs, TODOs, placeholder text, fake results, "
                        f"or dead buttons), clean navigation, and a genuinely refined UI you'd "
                        f"be proud to show users. Don't cut corners on what you build. QA and "
                        f"several follow-up rounds will push this toward a complete production-"
                        f"ready product, so make this first version solid and real. Save every "
                        f"file under {outdir} using your file tools.\n"
                        f"Work order:\n{last_text(init, 'planning')}\n"
                        "List each file you created with a one-line summary, and flag anything "
                        "that needs an owner login or key."
                        + division_iteration_feedback(init)
                        + lessons_block(state, init.get("division", ""))))
                log_minute(init, "execution", "builder", build)
                collect_artifacts()
                init["exec_phase"] = "review"

            elif phase == "fix":
                review = last_text(init, "review")
                fix = runner("builder", role_prompt("builder",
                    f"QA reviewed '{init['title']}' and it is NOT production-ready yet. "
                    f"Address EVERY point by editing and adding real files under "
                    f"{outdir} — implement properly, never stub, and raise the overall "
                    f"completeness and polish while you're in there (add the missing "
                    f"screens, navigation, and features it calls for). Verify your work "
                    f"actually builds and the tests pass before you report. Don't argue — "
                    f"do the work.\n\nQA review:\n{review}"
                    f"{division_toolkit(init)}{division_iteration_feedback(init)}"))
                log_minute(init, "execution", "builder", fix)
                collect_artifacts()
                init["exec_phase"] = "review"

            else:  # review — one QA verdict per turn
                collect_artifacts()
                files = "\n".join(init["artifacts"]) or "(no files)"
                review = runner("qa", role_prompt("qa",
                    f"Review '{init['title']}' as a SHIPPABLE, production-ready product. "
                    f"The bar: would real users pay for this, and would it embarrass "
                    f"the owner if it weren't polished? READ every file under {outdir}.\n"
                    f"Files:\n{files}\n\n"
                    "Hold a HIGH bar — do not pass 'basic' or 'unfinished':\n"
                    "• Complete? Does it have the features a real user expects, or is it "
                    "a skeleton missing obvious functionality?\n"
                    "• Real? Every flow actually wired and working — no stubs, fake "
                    "logic, placeholder text, TODOs, or dead buttons?\n"
                    "• Polished? Is the UI professional and refined, with empty, "
                    "loading, error, and edge states handled?\n"
                    "• Solid? Does it persist data properly and behave correctly?\n"
                    "• Dead-end? After the main action, can the user SAVE it, find it "
                    "again in a library/history, edit it, reuse it, and share/export "
                    "it — or does the app become pointless after one use? A one-shot, "
                    "single-flow app that goes nowhere FAILS.\n"
                    "• Impressive? Is it missing anything that would make it genuinely "
                    "stand out rather than feel like an obvious clone?\n"
                    "CRITICAL — judge ONLY what you can verify YOURSELF on this machine: "
                    "reading the code, running the build, tests, and tools. NEVER vote "
                    "REVISE for work only the owner can do — physical-device testing, "
                    "TestFlight, App Store screenshots, human usability sessions. Put "
                    "those items in a short 'OWNER CHECKLIST:' section of your review "
                    "instead; they do not block the verdict.\n"
                    "End with exactly one line: 'VERDICT: SHIP' ONLY if it is genuinely "
                    "production-ready and impressive, or 'VERDICT: REVISE' then a "
                    "numbered list (up to 6) of the most important fixes and additions "
                    "needed to get it there."))
                log_minute(init, "review", "qa", review)
                init["review_rounds"] = init.get("review_rounds", 0) + 1
                if review_passed(review) or init["review_rounds"] >= MAX_REVIEW_ROUNDS:
                    init["exec_phase"] = ""
                    # Division initiatives face their specialist gate before
                    # Demo Day; the generic pipeline goes straight there.
                    if division_charter(init).get("gate"):
                        init["stage"] = "division_gate"
                    else:
                        init["stage"] = "demo_ready"
                else:
                    init["exec_phase"] = "fix"
        except BudgetExceeded:
            if phase == "build":
                raise   # nothing on disk worth demoing — let the tick block it
            # Mid-review/fix: ship what exists rather than vanish.
            collect_artifacts()
            init["exec_phase"] = ""
            init["stage"] = "demo_ready"

    elif stage == "division_gate":
        # The division's specialist judge reviews the actual deliverables
        # before Demo Day — the games studio's Fun Gate, generalized. REJECTED
        # loops back to the build with the reasons (division_iteration_feedback);
        # three strikes blocks it honestly for the owner.
        charter = division_charter(init)
        gate = charter.get("gate") or {}
        if not gate:   # charter lost its gate (or division cleared) — nothing to judge
            init["stage"] = "demo_ready"
            return
        outdir = initiative_outdir(init, artifacts_root)
        init["artifacts"] = sorted(str(p) for p in outdir.rglob("*") if p.is_file())
        files = "\n".join(init["artifacts"]) or "(no files)"
        hint = charter.get("deliverable_hint", "")
        gate_role = gate.get("role", "qa")
        title = gate.get("title", "Division Gate")
        # Hard code-side floor first (disclaimer banner / data artifact /
        # Sources section): a failed check is an automatic REJECTED with an
        # honest reason, regardless of any judge — no judge turn is bought.
        check = charter.get("check")
        auto_reason = check(outdir) if check else ""
        if auto_reason:
            passed = False
            log_minute(init, "division_gate", gate_role,
                       f"AUTO-REJECT (code check): {auto_reason}\nGATE: REJECTED")
            init["division_gate"] = {"verdict": "REJECTED",
                                     "reasons": [auto_reason]}
        else:
            reply = runner(gate_role, (
                f"{COMPANY_CULTURE}\n\n{gate.get('prompt_intro', '')}\n\n"
                f"{title} review of '{init['title']}' "
                f"({charter.get('name', 'division')} division). The deliverable "
                f"should be {hint or 'division-grade work'}.\n"
                f"READ the files under {outdir} yourself — judge the actual work, "
                f"not the team's summaries.\nFiles:\n{files}\n\n"
                "Give up to 4 bullet reasons, then end with EXACTLY one line: "
                "'GATE: APPROVED' or 'GATE: REJECTED'."))
            log_minute(init, "division_gate", gate_role, reply)
            passed = gate_passed(reply)
            init["division_gate"] = {
                "verdict": "APPROVED" if passed else "REJECTED",
                "reasons": parse_gate_reasons(reply),
            }
        if passed:
            log_event(state, f"{title} APPROVED: {init['title']}")
            if charter.get("deploy"):
                deploy_initiative(state, init, outdir)
            init["stage"] = "demo_ready"
        else:
            init["division_rejections"] = init.get("division_rejections", 0) + 1
            if init["division_rejections"] >= MAX_DIVISION_REJECTIONS:
                init["stage"] = BLOCKED_STAGE
                init["note"] = (f"blocked: {title} rejected {MAX_DIVISION_REJECTIONS} "
                                "builds in a row — the team can't clear the division "
                                "bar without the owner's steer")
                record_lesson(state, init)
                log_event(state, f"{title} REJECTED ×{MAX_DIVISION_REJECTIONS}: "
                                 f"{init['title']} — blocked for the owner")
            else:
                init["stage"] = "execution"
                init["exec_phase"] = "fix"
                init["review_rounds"] = 0   # fresh QA rounds for the rework
                log_event(state, f"{title} REJECTED: {init['title']} — back to the build team")

    elif stage == "demo_ready":
        outdir = initiative_outdir(init, artifacts_root)
        if init.get("demo_phase") != "invite":
            # Demo Day you can SEE: before the invite, the builder captures
            # real screenshots of the product so the owner's gate-2 decision
            # isn't made blind off a text brief. One turn, resumable like
            # execution — a timeout here costs the turn, not the stage.
            demo_dir = outdir / ".demo"
            capture = runner("builder", role_prompt("builder",
                f"{BUILDER_TOOLKIT}\n\n{build_directive(state, init)}\n\n"
                f"Demo Day prep for '{init['title']}' (project at {outdir}). Produce REAL "
                f"visual evidence of the product so the owner can SEE it before deciding "
                f"to ship. Save numbered PNG screenshots of the main screens and flows "
                f"into {demo_dir} (01-onboarding.png, 02-home.png, … up to 8).\n"
                "How: for an iPhone or iPad app, build it and boot it in the matching "
                "Simulator (`xcodebuild`, `xcrun simctl boot`, `xcrun simctl io <device> screenshot`); "
                "for a macOS app, launch the built .app and capture its window with `screencapture`; "
                "for a web app, use a headless-browser screenshot; for a CLI, capture the "
                "terminal output. When you're done, run `xcrun simctl shutdown all` so no "
                "simulator keeps burning the owner's CPU. NEVER fake, mock up, or hand-draw a screenshot — if you "
                f"genuinely cannot capture one, write {demo_dir}/README.md explaining why "
                "and exactly what the owner should run to see it themselves.\n"
                "Reply with the list of demo files you captured."))
            log_minute(init, "demo", "builder", capture)
            init["artifacts"] = sorted(
                str(p) for p in outdir.rglob("*") if p.is_file())
            init["demo_phase"] = "invite"
        else:
            files = "\n".join(init["artifacts"]) or "(no files recorded)"
            reply = runner("ceo", role_prompt("ceo",
                f"The team finished '{init['title']}'. Deliverables:\n{files}\n"
                f"Builder's report:\n{last_text(init, 'execution')}\n"
                "Write the Demo Day invitation for the owner: what was built, "
                "3 highlights, and the ship/no-ship question. 6 lines max."))
            log_minute(init, "demo", "ceo", reply)
            init["brief"] = reply.strip()
            init["demo_phase"] = ""
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
        record_lesson(state, init)
    elif decision == "approve":
        init["stage"] = "planning" if at_gate1 else "shipped"
        if init["stage"] == "shipped":
            record_lesson(state, init)
    else:  # revise
        if at_gate1:
            init["stage"] = "research"
        else:
            # Owner wants changes: extend the build on disk, fresh QA rounds.
            init["stage"] = "execution"
            init["exec_phase"] = "build"
            init["review_rounds"] = 0
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

    # Events the tick logged (advanced/stalled/paused/scouted) used to be
    # dropped here — the log file saw them but the app's activity feed never
    # did, so a hard-working company looked frozen to the owner. Carry over
    # anything appended since the snapshot.
    seen = {(e.get("ts"), e.get("text")) for e in before.get("events", [])}
    fresh = [e for e in ticked.get("events", []) if (e.get("ts"), e.get("text")) not in seen]
    if fresh:
        feed = current.setdefault("events", [])
        known = {(e.get("ts"), e.get("text")) for e in feed}
        feed.extend(e for e in fresh if (e.get("ts"), e.get("text")) not in known)
        feed.sort(key=lambda e: e.get("ts", 0.0))
        del feed[:-50]
    # Lessons the tick recorded (blocked initiatives) must survive the merge
    # like events do, or the institutional memory silently loses its worst
    # (most instructive) outcomes.
    known_lessons = {l.get("id") for l in current.setdefault("lessons", [])}
    before_lessons = {l.get("id") for l in before.get("lessons", [])}
    for lesson in ticked.get("lessons", []):
        if lesson.get("id") not in before_lessons and lesson.get("id") not in known_lessons:
            current["lessons"].append(lesson)
    del current["lessons"][:-LESSONS_CAP]

    # Overload bookkeeping (overloaded_since / last_defer_note) must survive
    # the merge too, or the starvation escape can never trigger.
    if ticked.get("engine") != before.get("engine"):
        current["engine"] = ticked.get("engine", {})

    current["last_tick"] = max(current.get("last_tick", 0.0), ticked.get("last_tick", 0.0))
    return current


def tick(state: dict, runner, artifacts_root: Path, now: float | None = None) -> list[str]:
    """One heartbeat: advance every working initiative one stage, then scout
    if there's capacity. Returns human-readable event strings."""
    now = now if now is not None else time.time()
    config = state["config"]
    if not state["enabled"]:
        return []
    if state.get("task_mode"):
        # Kanban List is on — the team focuses on the owner's task backlog
        # (worked in run_task_work), not on scouting/advancing their own ideas.
        return []
    hour = datetime.fromtimestamp(now).hour
    if is_quiet(hour, config["quiet_start"], config["quiet_end"]):
        return []
    engine = state.setdefault("engine", {})
    force_single = False
    if machine_overloaded(config.get("max_load_per_core", 2.5)):
        # Don't buy turns the machine can't finish — the API charges when the
        # turn starts, the timeout kills it before anything lands. Work resumes
        # automatically on the first heartbeat after the load drops. BUT the
        # pause must be VISIBLE (the owner watched a "frozen" company for hours
        # with no explanation) and BOUNDED (a Mac that stays busy all day used
        # to starve the pipeline forever).
        load1, cores = load_per_core()
        limit = cores * config.get("max_load_per_core", 2.5)
        since = engine.get("overloaded_since") or now
        engine["overloaded_since"] = since
        parked_minutes = (now - since) / 60
        marker = " ⏰ 45m+" if parked_minutes >= 45 else ""
        message = (f"⏸ paused: Mac overloaded (load {load1:.0f}, limit {limit:.0f}, "
                   f"parked {parked_minutes:.0f}m{marker}) — work resumes when it cools")
        if now - engine.get("last_defer_note", 0.0) >= 900:
            engine["last_defer_note"] = now   # feed note at most every 15 min
            log_event(state, message)
        if parked_minutes < 45 or load1 > 2 * limit:
            return [message]
        # Starvation escape: parked 45+ min and the load is elevated but not
        # crushing (< 2× limit) — buy ONE bounded turn so the pipeline always
        # inches toward shipping instead of parking forever.
        force_single = True
        log_event(state, "⚠ overload parked 45+ min — forcing one turn to keep shipping")
    else:
        engine.pop("overloaded_since", None)

    # In-flight work advances EVERY heartbeat — no artificial wait between
    # stages. That inter-stage waiting (a 30-min gate before every transition),
    # not the build itself, was burning ~2h per initiative. advance_stage
    # blocks, so a long build naturally paces the loop; only SCOUTING a
    # brand-new idea stays throttled to interval_minutes (below).
    events: list[str] = []
    queue = list(working(state))
    # WIP cap: several actives (stacked owner directives) advance at most
    # max_turns_per_tick per heartbeat, rotated for fairness — bounded spend
    # per tick instead of one heartbeat buying every initiative a turn.
    cap = 1 if force_single else max(1, int(config.get("max_turns_per_tick", 2)))
    if len(queue) > cap:
        start = engine.get("turn_cursor", 0) % len(queue)
        queue = (queue + queue)[start:start + cap]
        engine["turn_cursor"] = (start + cap) % len(working(state))
    for init in queue:
        charged = make_charged_runner(init, config["budget_calls"], runner)
        try:
            advance_stage(state, init, charged, artifacts_root)
            init["stall_count"] = 0   # progress resets the stall counter
            phase = f" ({init['exec_phase']})" if init.get("exec_phase") else ""
            events.append(f"{init['id']} advanced to {init['stage']}{phase}")
        except BudgetExceeded:
            init["stage"] = BLOCKED_STAGE
            init["note"] = "blocked: token budget exhausted — GM/owner decision required"
            record_lesson(state, init)
            events.append(f"{init['id']} blocked: budget exhausted")
        except Exception as error:  # noqa: BLE001 — one bad turn must not stop the pulse
            # str(TimeoutExpired) embeds the ENTIRE 4KB agent prompt — the app
            # showed the owner a wall of role-text instead of what went wrong.
            reason = str(error)
            if len(reason) > 300:
                reason = f"{reason[:180]} … {reason[-80:]}"
            init["stall_count"] = init.get("stall_count", 0) + 1
            if init["stall_count"] >= MAX_STALLS:
                init["stage"] = BLOCKED_STAGE
                init["note"] = f"blocked after {MAX_STALLS} failed attempts: {reason}"
                record_lesson(state, init)
                events.append(f"{init['id']} blocked: {reason}")
            else:
                init["note"] = f"stalled ({init['stall_count']}/{MAX_STALLS}): {reason}"
                events.append(f"{init['id']} stalled: {reason}")

    # Scouting a NEW initiative is the ONLY thing throttled to interval_minutes,
    # so the company doesn't fire off a fresh idea every minute — but work
    # already underway (above) never waits on this timer. A forced overload
    # turn never scouts: new ideas can wait until the machine cools.
    if not force_single and now - state["last_tick"] >= config["interval_minutes"] * 60:
        state["last_tick"] = now
        if len(active(state)) < config["max_active"]:
            try:
                scouted = run_scout(state, runner)
            except Exception as error:  # noqa: BLE001
                scouted = None
                events.append(f"scout failed: {error}")
            if scouted is not None:
                events.append(f"scouted new initiative {scouted['id']}: {scouted['title']}")

    for event in events:
        log_event(state, event)   # persist to the activity feed
    return events
