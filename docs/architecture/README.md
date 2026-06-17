# Boardroom Architecture

This folder contains the editable architecture diagram for Boardroom: the iOS command center, Mac relay, Hermes Agent runtime, autonomous company loop, widget snapshot path, and GitHub handoff flow.

![Boardroom architecture](boardroom-architecture-preview.png)

## Files

- `boardroom-architecture.drawio` — editable Draw.io / diagrams.net source.
- `boardroom-architecture-preview.png` — rendered preview for GitHub and quick review.
- `boardroom-architecture-diagrams-net-edit-url.txt` — browser fallback edit URL for diagrams.net when the Draw.io desktop CLI is not installed.
- `generate_boardroom_drawio.py` — deterministic generator for the Draw.io XML.
- `render_drawio_preview.py` — fallback preview renderer used on Windows when the Draw.io desktop CLI is unavailable.

## What the diagram shows

- Boardroom iOS SwiftUI app layers: tab shell, UI surfaces, state stores, runtime controller, and device services.
- Mac relay layer: pairing, bearer-token security, HTTP/SSE API, session registry, company engine, and persisted state.
- Hermes Agent runtime: CLI/profile sessions, role prompts, models/skills/memory, local tool execution, and delivery artifacts.
- Founder approval gates: approve, revise, kill, and ship decisions.
- Widget/live-activity path: `CompanySnapshot` written through the shared App Group for glanceable status.
- Initiative flow: scout → board debate → gate → plan → build → QA loop → Demo Day.

## Regenerate

From the repository root:

```bash
python docs/architecture/generate_boardroom_drawio.py
python C:/Users/andre/AppData/Local/hermes/skills/design/drawio-skill/scripts/validate.py --strict docs/architecture/boardroom-architecture.drawio
python docs/architecture/render_drawio_preview.py
python C:/Users/andre/AppData/Local/hermes/skills/design/drawio-skill/scripts/encode_drawio_url.py --edit docs/architecture/boardroom-architecture.drawio > docs/architecture/boardroom-architecture-diagrams-net-edit-url.txt
```

If Draw.io desktop is installed, export a native editable PNG/SVG from the `.drawio` file using the `drawio-skill` workflow.
