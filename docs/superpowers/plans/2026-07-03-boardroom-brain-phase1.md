# Boardroom "Second Brain" — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the autonomous Boardroom company a persisted Constitution and feed it (plus recent decisions) back into every deliberative agent turn, so agents reason with the company's real history.

**Architecture:** Three pure, fail-safe helpers in `Scripts/hermes_mobile_relay.py` — `ensure_constitution` (seed `Company.md`), `build_memory_block` (read constitution + recent decisions, capped), `compose_company_prompt` (gated prepend) — wired into the single company-turn chokepoint `company_cli_runner`. The pure engine `hermes_company.py` is untouched.

**Tech Stack:** Python 3, `unittest` (tests run under pytest), existing relay module loaded via importlib as `relay`.

## Global Constraints

- **Server-side only.** No Swift/iOS changes. Verified via pytest + relay restart; owner does not rebuild the app.
- **Fail-safe reads.** Any vault-read error → return `""` / no-op. A vault read must NEVER break an agent turn (mirrors `:1151`).
- **Gated injection.** Inject memory ONLY for deliberative roles `{ceo, cfo, cto, marketing, builder, qa}`. NEVER for `research` (Scout strict JSON) or `lena` (minutes) — prose would corrupt their formats.
- **Never overwrite `Company.md`** — the owner edits it in Obsidian; seeding is one-time.
- **Size cap** the memory block at `MEMORY_BLOCK_CAP = 2800` chars.
- **Vault root:** `COMPANY_VAULT_ROOT = ~/Documents/Boardroom-Vault` (`hermes_mobile_relay.py:102`). New functions take optional `root: Path | None = None` defaulting to it (for testability).
- **No new dependencies.**
- **Branch:** work on `feature/boardroom-brain-phase1` (repo is on `main`; do not commit to `main`, do not push).

## File Structure

- Modify: `Scripts/hermes_mobile_relay.py`
  - Add module constants: `CONSTITUTION_FILENAME`, `CONSTITUTION_SEED`, `MEMORY_BLOCK_CAP`, `DELIBERATIVE_ROLES` (near other vault code, ~line 1065).
  - Add functions `ensure_constitution`, `build_memory_block`, `compose_company_prompt` (in the "Company Vault" section, after `ensure_vault_home`, ~line 1089).
  - Wire `ensure_constitution()` into `ensure_vault_home` (`:1077`) and `compose_company_prompt` into `company_cli_runner` (`:579`).
- Modify: `Scripts/test_hermes_mobile_relay.py`
  - Add `CompanyBrainTests(unittest.TestCase)` with the tests below.

---

### Task 1: Constitution seed (`ensure_constitution`)

**Files:**
- Modify: `Scripts/hermes_mobile_relay.py` (add constants ~1065; add function after `ensure_vault_home` ~1089; call it inside `ensure_vault_home`)
- Test: `Scripts/test_hermes_mobile_relay.py`

**Interfaces:**
- Produces: `ensure_constitution(root: Path | None = None) -> None`; constant `CONSTITUTION_FILENAME = "Company.md"`.

- [ ] **Step 1: Write the failing tests**

Add to `Scripts/test_hermes_mobile_relay.py`:
```python
class CompanyBrainTests(unittest.TestCase):
    def test_ensure_constitution_seeds_when_absent(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            relay.ensure_constitution(root)
            con = root / "Company.md"
            self.assertTrue(con.exists())
            self.assertIn("Constitution", con.read_text())

    def test_ensure_constitution_never_overwrites(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("MY EDITS")
            relay.ensure_constitution(root)
            self.assertEqual((root / "Company.md").read_text(), "MY EDITS")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest Scripts/test_hermes_mobile_relay.py::CompanyBrainTests -v`
Expected: FAIL with `AttributeError: module 'hermes_mobile_relay' has no attribute 'ensure_constitution'`

- [ ] **Step 3: Add constants + function**

Add constants near the Company Vault section (~line 1065, before `_vault_slug`):
```python
CONSTITUTION_FILENAME = "Company.md"
CONSTITUTION_SEED = (
    "# Company — Constitution\n\n"
    "> The single source of truth for this company. Edit me in Obsidian — every "
    "board agent reads this before it decides.\n\n"
    "## Thesis\n"
    "<One paragraph: what this company is, who it serves, and how it wins. "
    "Replace this line.>\n\n"
    "## Chain of command\n"
    "- Chairman (Andrew) — owner, final authority\n"
    "- CEO — chairs the board, owns outcomes\n"
    "- CFO / CTO / Head of Marketing / Head of Research — the board\n"
    "- Lead Builder, QA + Design lead — execution & the shipping gate\n"
    "- Lena — the Chairman's executive assistant\n\n"
    "## Operating principles\n"
    "- Real, finished, verifiable work — never faked, padded, or hidden.\n"
    "- Consequential or hard-to-reverse moves get the Chairman's explicit YES first.\n"
    "- Stay fully within the law.\n\n"
    "## Current priorities\n"
    "<Edit: e.g. 'Ship one revenue-positive initiative this month.'>\n"
)
```

Add the function right after `ensure_vault_home` (~line 1089):
```python
def ensure_constitution(root: Path | None = None) -> None:
    """Seed the company Constitution (Company.md) if absent. NEVER overwrites —
    the owner edits it in Obsidian. Idempotent; safe on every vault touch."""
    base = root or COMPANY_VAULT_ROOT
    path = base / CONSTITUTION_FILENAME
    if path.exists():
        return
    base.mkdir(parents=True, exist_ok=True)
    path.write_text(CONSTITUTION_SEED)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest Scripts/test_hermes_mobile_relay.py::CompanyBrainTests -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Wire into `ensure_vault_home`**

In `ensure_vault_home` (`:1077`), add `ensure_constitution()` as the FIRST line of the function body (before the `home.exists()` early-return), so the constitution seeds even when `Home.md` already exists:
```python
def ensure_vault_home() -> None:
    ensure_constitution()
    home = COMPANY_VAULT_ROOT / "Home.md"
    if home.exists():
        return
    ...
```

- [ ] **Step 6: Run the full relay suite (no regressions)**

Run: `python3 -m pytest Scripts/test_hermes_mobile_relay.py -v`
Expected: PASS (all prior tests + the 2 new)

- [ ] **Step 7: Commit**

```bash
git add Scripts/hermes_mobile_relay.py Scripts/test_hermes_mobile_relay.py
git commit -m "feat(boardroom): seed company Constitution (Company.md) in vault"
```

---

### Task 2: Memory retriever (`build_memory_block`)

**Files:**
- Modify: `Scripts/hermes_mobile_relay.py` (add constants + function after `ensure_constitution`)
- Test: `Scripts/test_hermes_mobile_relay.py`

**Interfaces:**
- Consumes: `CONSTITUTION_FILENAME`, `COMPANY_VAULT_ROOT`.
- Produces: `build_memory_block(root: Path | None = None) -> str`; constant `MEMORY_BLOCK_CAP = 2800`.

- [ ] **Step 1: Write the failing tests**

Add to `CompanyBrainTests`:
```python
    def test_memory_block_empty_when_vault_missing(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(relay.build_memory_block(Path(d) / "nope"), "")

    def test_memory_block_includes_constitution_and_decisions(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("# Constitution\nThesis: win.")
            (root / "decisions").mkdir()
            (root / "decisions" / "Decision Log.md").write_text(
                "# Decision Log\n\n## Ship widget — 2026-07-01\n- Approved widget\n")
            block = relay.build_memory_block(root)
            self.assertIn("Thesis: win.", block)
            self.assertIn("Approved widget", block)
            self.assertIn("Company memory", block)

    def test_memory_block_respects_cap(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("x" * 5000)
            block = relay.build_memory_block(root)
            self.assertLessEqual(len(block), relay.MEMORY_BLOCK_CAP)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest Scripts/test_hermes_mobile_relay.py::CompanyBrainTests -v`
Expected: FAIL with `AttributeError: ... has no attribute 'build_memory_block'`

- [ ] **Step 3: Add constant + function**

Add near the other new constants (~1065):
```python
MEMORY_BLOCK_CAP = 2800
_CONSTITUTION_CAP = 1500
_DECISIONS_CAP = 1200
```

Add the function after `ensure_constitution`:
```python
def build_memory_block(root: Path | None = None) -> str:
    """Compact 'company memory' for deliberative agent turns: the Constitution +
    the most recent decisions, size-capped. Fail-safe: ANY error → '' (a vault
    read must never break a turn)."""
    base = root or COMPANY_VAULT_ROOT
    try:
        parts: list[str] = []
        con = base / CONSTITUTION_FILENAME
        if con.exists():
            parts.append("### Constitution\n" + con.read_text()[:_CONSTITUTION_CAP].strip())
        log = base / "decisions" / "Decision Log.md"
        if log.exists():
            body = log.read_text().split("\n## ")[1:]   # drop the "# Decision Log" header chunk
            recent = body[-8:]
            if recent:
                tail = ("## " + "\n## ".join(recent)).strip()
                parts.append("### Recent decisions\n" + tail[-_DECISIONS_CAP:])
        if not parts:
            return ""
        block = ("## Company memory (shared brain — read before you decide)\n"
                 + "\n\n".join(parts))
        return block[:MEMORY_BLOCK_CAP]
    except Exception:  # noqa: BLE001 — memory read must never break a turn
        return ""
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest Scripts/test_hermes_mobile_relay.py::CompanyBrainTests -v`
Expected: PASS (5 passed total in class)

- [ ] **Step 5: Commit**

```bash
git add Scripts/hermes_mobile_relay.py Scripts/test_hermes_mobile_relay.py
git commit -m "feat(boardroom): build_memory_block reads constitution + recent decisions"
```

---

### Task 3: Gated injection (`compose_company_prompt`)

**Files:**
- Modify: `Scripts/hermes_mobile_relay.py` (add constant + function after `build_memory_block`)
- Test: `Scripts/test_hermes_mobile_relay.py`

**Interfaces:**
- Consumes: `build_memory_block`.
- Produces: `compose_company_prompt(role: str, prompt: str, root: Path | None = None) -> str`; constant `DELIBERATIVE_ROLES: set[str]`.

- [ ] **Step 1: Write the failing tests**

Add to `CompanyBrainTests`:
```python
    def test_compose_injects_for_deliberative_role(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("# Constitution\nThesis: win.")
            out = relay.compose_company_prompt("ceo", "Decide X.", root)
            self.assertIn("Thesis: win.", out)
            self.assertTrue(out.endswith("Decide X."))

    def test_compose_skips_scout_and_lena(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("# Constitution\nThesis: win.")
            self.assertEqual(relay.compose_company_prompt("research", "JSON please", root), "JSON please")
            self.assertEqual(relay.compose_company_prompt("lena", "summarize", root), "summarize")

    def test_compose_passthrough_when_no_vault(self):
        with tempfile.TemporaryDirectory() as d:
            out = relay.compose_company_prompt("ceo", "Decide X.", Path(d) / "nope")
            self.assertEqual(out, "Decide X.")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest Scripts/test_hermes_mobile_relay.py::CompanyBrainTests -v`
Expected: FAIL with `AttributeError: ... has no attribute 'compose_company_prompt'`

- [ ] **Step 3: Add constant + function**

Add near the other new constants (~1065):
```python
DELIBERATIVE_ROLES = {"ceo", "cfo", "cto", "marketing", "builder", "qa"}
```

Add the function after `build_memory_block`:
```python
def compose_company_prompt(role: str, prompt: str, root: Path | None = None) -> str:
    """Prepend the company memory block for deliberative board roles only.
    Utility calls — Scout ('research', strict JSON) and Lena ('lena', minutes) —
    are SKIPPED so injected prose can't corrupt their required output formats.
    Empty block or non-deliberative role → prompt unchanged."""
    if role not in DELIBERATIVE_ROLES:
        return prompt
    block = build_memory_block(root)
    if not block:
        return prompt
    return f"{block}\n\n{prompt}"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest Scripts/test_hermes_mobile_relay.py::CompanyBrainTests -v`
Expected: PASS (8 passed total in class)

- [ ] **Step 5: Commit**

```bash
git add Scripts/hermes_mobile_relay.py Scripts/test_hermes_mobile_relay.py
git commit -m "feat(boardroom): gated memory injection for deliberative roles only"
```

---

### Task 4: Wire injection into `company_cli_runner`

**Files:**
- Modify: `Scripts/hermes_mobile_relay.py:579` (`company_cli_runner`)
- Test: `Scripts/test_hermes_mobile_relay.py`

**Interfaces:**
- Consumes: `compose_company_prompt`, `company_chat_command`, `run_killable`, `RelayConfigStore`.
- Produces: no new symbol; `company_cli_runner` now injects memory before shelling out.

- [ ] **Step 1: Write the failing integration test**

Add the import at the top of `Scripts/test_hermes_mobile_relay.py` (with the other imports):
```python
from unittest import mock
```
Add to `CompanyBrainTests`:
```python
    def test_company_cli_runner_injects_memory_for_deliberative_role(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "Company.md").write_text("# Constitution\nThesis: win.")
            captured = {}

            def fake_company_chat_command(prompt, role, resume):
                captured["prompt"] = prompt
                return ["true"]

            fake_result = subprocess.CompletedProcess(["true"], 0, "Session: 20260703_1\n", "")
            with mock.patch.object(relay, "COMPANY_VAULT_ROOT", root), \
                 mock.patch.object(relay, "company_chat_command", fake_company_chat_command), \
                 mock.patch.object(relay, "run_killable", return_value=fake_result), \
                 mock.patch.object(relay.RelayConfigStore, "session_id", return_value=None), \
                 mock.patch.object(relay.RelayConfigStore, "save_session", return_value=None):
                relay.company_cli_runner("ceo", "Decide X.")

            self.assertIn("Thesis: win.", captured["prompt"])
            self.assertIn("Decide X.", captured["prompt"])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest "Scripts/test_hermes_mobile_relay.py::CompanyBrainTests::test_company_cli_runner_injects_memory_for_deliberative_role" -v`
Expected: FAIL — `captured["prompt"]` is `"Decide X."` without the constitution (memory not yet wired), so `assertIn("Thesis: win.", ...)` fails.

- [ ] **Step 3: Wire the injection**

In `company_cli_runner` (`:579`), add the composition as the first statement inside the function body (right after the docstring, before `store = RelayConfigStore(...)`):
```python
def company_cli_runner(role: str, prompt: str) -> str:
    """runner(role, prompt) for the company engine: one Hermes CLI call per
    turn, with a persistent session per role so agents keep their memory."""
    prompt = compose_company_prompt(role, prompt)   # inject shared brain (gated)
    store = RelayConfigStore(CONFIG_PATH)
    ...
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest "Scripts/test_hermes_mobile_relay.py::CompanyBrainTests::test_company_cli_runner_injects_memory_for_deliberative_role" -v`
Expected: PASS

- [ ] **Step 5: Run the FULL suite (both files)**

Run: `python3 -m pytest Scripts/test_hermes_mobile_relay.py Scripts/test_hermes_company.py -v`
Expected: PASS (all existing + 9 new)

- [ ] **Step 6: Commit**

```bash
git add Scripts/hermes_mobile_relay.py Scripts/test_hermes_mobile_relay.py
git commit -m "feat(boardroom): inject shared-brain memory into company agent turns"
```

---

## Self-Review

**1. Spec coverage:**
- Constitution (spec Component 1) → Task 1. ✓
- Memory retriever (Component 2) → Task 2. ✓
- Gated injection (Component 3) → Task 3 + wired in Task 4. ✓
- Error handling (spec §6, fail-safe) → `build_memory_block` try/except (Task 2); passthrough (Task 3). ✓
- Testing (spec §7) → all four tasks are TDD. ✓
- **Component 4 (app-chat constitution) is DEFERRED to Phase 2** — see note below. This is the one intentional scope change from the approved spec; flagged for the owner.

**2. Placeholder scan:** No TBD/TODO/"handle edge cases". `CONSTITUTION_SEED` contains `<...>` template prompts, which are intentional user-editable seed copy, not plan placeholders. ✓

**3. Type consistency:** `ensure_constitution(root)`, `build_memory_block(root)`, `compose_company_prompt(role, prompt, root)` names/signatures match across Tasks 1–4. `CONSTITUTION_FILENAME`, `MEMORY_BLOCK_CAP`, `DELIBERATIVE_ROLES` used consistently. ✓

**Deferral note (Component 4):** The spec's thin app-chat constitution injection touches the live `/chat`+`/chat/stream` HTTP handler. To keep Phase 1 fully server-side, unit-tested, and zero-risk to the interactive chat path, it moves to Phase 2 (which already reworks the chat/briefing path). Phase 1 delivers the shared brain to the autonomous company engine — the highest-value slice.

## Execution Handoff
Inline execution in this session (executing-plans), branch `feature/boardroom-brain-phase1`, commit per task, run pytest at each step. No app rebuild; owner restarts the relay to see it live.
