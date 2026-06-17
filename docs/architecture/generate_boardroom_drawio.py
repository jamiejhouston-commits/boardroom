from __future__ import annotations

from pathlib import Path
import subprocess
from xml.sax.saxutils import escape

OUT = Path(__file__).with_name("boardroom-architecture.drawio")
REPO_SHA = subprocess.run(
    ["git", "rev-parse", "--short", "HEAD"],
    cwd=Path(__file__).parents[2],
    text=True,
    capture_output=True,
    check=False,
).stdout.strip() or "unknown"

cells: list[str] = []
next_id = 2

def eid(prefix: str = "n") -> str:
    global next_id
    value = f"{prefix}{next_id}"
    next_id += 1
    return value


def style(**parts: str) -> str:
    return ";".join(f"{k}={v}" for k, v in parts.items()) + ";"


def vertex(value: str, x: int, y: int, w: int, h: int, fill: str, stroke: str, *, shape: str = "rounded=1", font: str = "#1f2937", extra: str = "") -> str:
    id_ = eid()
    label = escape(value).replace("\n", "&#xa;")
    cell_style = f"{shape};whiteSpace=wrap;html=1;fillColor={fill};strokeColor={stroke};fontColor={font};fontSize=13;spacing=8;rounded=1;arcSize=10;{extra}"
    cells.append(
        f'<mxCell id="{id_}" value="{label}" style="{cell_style}" vertex="1" parent="1">'
        f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry" />'
        f'</mxCell>'
    )
    return id_


def text(value: str, x: int, y: int, w: int, h: int, *, size: int = 16, color: str = "#111827", bold: bool = False) -> str:
    id_ = eid("t")
    label = escape(value).replace("\n", "&#xa;")
    fw = "fontStyle=1;" if bold else ""
    cells.append(
        f'<mxCell id="{id_}" value="{label}" style="text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;whiteSpace=wrap;rounded=0;fontSize={size};fontColor={color};{fw}" vertex="1" parent="1">'
        f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry" />'
        f'</mxCell>'
    )
    return id_


def edge(source: str, target: str, label: str = "", *, color: str = "#6b7280", dashed: bool = False) -> str:
    id_ = eid("e")
    dash = "dashed=1;" if dashed else ""
    val = escape(label).replace("\n", "&#xa;")
    cells.append(
        f'<mxCell id="{id_}" value="{val}" style="edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=1;endArrow=block;endFill=1;strokeWidth=2;strokeColor={color};fontColor={color};fontSize=11;{dash}" edge="1" parent="1" source="{source}" target="{target}">'
        f'<mxGeometry relative="1" as="geometry" />'
        f'</mxCell>'
    )
    return id_

# Canvas title
text("Boardroom Architecture — iOS command center powered by Hermes Agent", 40, 20, 1180, 36, size=22, bold=True)
text(f"Source inspected: SwiftUI app, widget extension, Mac relay, company engine, XcodeGen config, README. Repo: jamiejhouston-commits/boardroom @ {REPO_SHA}", 40, 58, 1180, 30, size=12, color="#6b7280")

# Layer headers
phone = vertex("iPhone / Boardroom App\nSwiftUI native iOS 18+", 40, 120, 330, 55, "#ecfdf5", "#047857", font="#064e3b", extra="fontStyle=1;")
relay = vertex("Mac Relay\nScripts/hermes_mobile_relay.py", 445, 120, 330, 55, "#eff6ff", "#2563eb", font="#1e3a8a", extra="fontStyle=1;")
hermes = vertex("Hermes Agent Runtime\nlocal profiles + tools + skills", 850, 120, 330, 55, "#fff7ed", "#d97706", font="#7c2d12", extra="fontStyle=1;")

# iPhone layer nodes
ui = vertex("RootView Tab Shell\nHome · Chat · War Room\nAgents · Meetings", 70, 190, 270, 78, "#ffffff", "#10b981")
features = vertex("Boardroom UI Surfaces\nCommandCenter · CompanyChat\nWarRoom · Org · Meetings\nGateway · AR/3D · Cron/Kanban", 70, 292, 270, 100, "#ffffff", "#10b981")
stores = vertex("Observable State Stores\nAgentProfileStore · CompanyStore\nOrgStore · MeetingHub\nBriefingCenter · AppRouter", 70, 416, 270, 100, "#ffffff", "#10b981")
runtime = vertex("HermesRuntimeController\nboots runtime, saves relay config\nstreams chat", 70, 540, 270, 82, "#ffffff", "#10b981")
device = vertex("Device Services\nUserDefaults · Keychain\nNotifications · Calendar\nCamera/QR · Voice", 70, 646, 270, 94, "#f0fdf4", "#059669")

# Relay layer nodes
pairing = vertex("Pairing + Security\n/pair · /pair.json · /pair.png\nBearer token\n10-min pairing window", 475, 190, 270, 96, "#ffffff", "#3b82f6")
api = vertex("HTTP API + SSE\n/health · /chat · /chat/stream\n/tts · /company/*", 475, 310, 270, 86, "#ffffff", "#3b82f6")
sessions = vertex("Session Registry\nmobile key → Hermes session id\nper-profile resume", 475, 420, 270, 84, "#ffffff", "#3b82f6")
company = vertex("Autonomous Company Loop\nheartbeat · meetings · gates\ninitiative + task pipeline", 475, 528, 270, 86, "#ffffff", "#3b82f6")
state = vertex("Relay State on Mac\ncompany_state.json · artifacts\nshipped repo URLs", 475, 638, 270, 84, "#dbeafe", "#2563eb")

# Hermes/runtime nodes
cli = vertex("Hermes CLI / Profiles\nhermes chat -q / -c / -s skills\nrole-specific sessions", 880, 190, 270, 90, "#ffffff", "#f59e0b")
roles = vertex("Company Roles\nCEO · Research · CFO · CTO\nMarketing · Builder · QA", 880, 304, 270, 86, "#ffffff", "#f59e0b")
tools = vertex("Tool Execution Layer\nfiles · terminal · GitHub\nbrowser · builds · automation", 880, 414, 270, 86, "#ffffff", "#f59e0b")
models = vertex("Models + Skills + Memory\nLLM providers · reusable skills\nprofile state", 880, 524, 270, 86, "#ffffff", "#f59e0b")
outputs = vertex("Delivery Artifacts\nsource files · private GitHub repos\nmemos · Demo Day decisions", 880, 634, 270, 88, "#fffbeb", "#d97706")

# User and external resources
user = vertex("Founder / Chairman\napproves · revises · kills · ships", 40, 780, 230, 72, "#fef2f2", "#dc2626", font="#7f1d1d")
widget = vertex("Widgets + Live Activity\nCompanySnapshot via App Group\nlock/home-screen glance", 300, 780, 185, 86, "#eef2ff", "#6366f1", font="#312e81")
local = vertex("Local Machine Resources\nMac filesystem · Xcode\nGitHub auth · local tools", 520, 780, 290, 78, "#f3f4f6", "#6b7280")
github = vertex("GitHub / App Handoff\nprivate repos · public flagship repo\ncloneable delivery", 880, 780, 300, 78, "#f3f4f6", "#6b7280")

# Connections
edge(user, ui, "uses app")
edge(ui, features, "navigates")
edge(features, stores, "reads/writes")
edge(stores, runtime, "runtime + app state")
edge(runtime, api, "URLSession JSON / SSE")
edge(device, pairing, "QR/deep link saves URL + token")
edge(stores, api, "company state + gate decisions")
edge(api, sessions, "auth + session map")
edge(api, company, "start/halt/gate/iterate")
edge(company, state, "persist summary, minutes, artifacts")
edge(api, cli, "subprocess hermes chat")
edge(sessions, cli, "resume session id")
edge(company, roles, "role prompts")
edge(roles, cli, "profile turns")
edge(cli, models, "model calls")
edge(models, tools, "tool calls")
edge(tools, local, "executes on Mac")
edge(local, tools, "results")
edge(tools, outputs, "build/test/ship")
edge(outputs, github, "ship_in_background")
edge(outputs, state, "repo_url + artifacts", dashed=True)
edge(state, stores, "poll /company")
edge(stores, device, "notifications + calendar gates")
edge(stores, widget, "write snapshot")
edge(widget, user, "status glance")
edge(user, stores, "approve / revise / kill")
edge(github, user, "clone/test handoff")

# Pipeline strip
text("Autonomous initiative flow", 40, 905, 360, 28, size=18, bold=True)
steps = [
    ("Scout", "research scouts demand"),
    ("Board Debate", "CFO/CTO/Marketing + CEO brief"),
    ("Gate 1", "founder greenlight"),
    ("Plan", "small work order"),
    ("Build", "builder creates files"),
    ("QA Loop", "QA reviews + builder fixes"),
    ("Demo Day", "founder ship/revise/kill"),
]
prev = None
for i, (name, detail) in enumerate(steps):
    n = vertex(f"{name}\n{detail}", 40 + i * 165, 955, 140, 72, "#ffffff", "#9ca3af", font="#111827")
    if prev:
        edge(prev, n, "")
    prev = n

xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<mxfile host="drawio" modified="2026-06-17T00:00:00.000Z" agent="Hermes Agent drawio-skill" version="26.0.0" type="device">
  <diagram id="boardroom-architecture" name="Boardroom Architecture">
    <mxGraphModel dx="1422" dy="794" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="1260" pageHeight="1100" math="0" shadow="0">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
        {chr(10).join(cells)}
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
'''
OUT.write_text(xml, encoding="utf-8")
print(OUT)
print(f"cells={len(cells)}")
