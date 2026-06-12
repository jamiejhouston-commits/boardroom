# Boardroom

**Don't use an AI. Employ one.**

Boardroom is an iOS app that turns your AI agent into an autonomous company —
and makes you the Chairman. Your agents scout real market trends, debate what
to build in a boardroom (with recorded dissent), produce real deliverables on
your Mac, and only interrupt you twice: once for your greenlight, once at Demo
Day for your ship/no-ship call.

> 🎬 **Demo video coming here** — agents debating out loud, the phone buzzing
> with "The board needs your greenlight," and Demo Day on the calendar.

## What it does

- 🏛 **The Boardroom** — flip the company on, set your investment thesis
  ("small consumer utilities, no crypto"), and the org runs itself on a
  heartbeat: *scout → research → boardroom debate → **your greenlight** →
  build → Demo Day → **your call***. Budgets, quiet hours, and a kill switch
  keep it on a leash.
- 📞 **Voice calls with your agents** — hold to talk, they answer in their own
  voice, in their own 3D office.
- 💬 **Fast chat** — a warm agent server answers in ~2–3 seconds, streamed.
- 🗣 **Boardroom debates out loud** — round-robin arguments between your
  leadership, minutes filed automatically by the secretary.
- 📅 **Real meetings** — scheduled into your Apple Calendar with alerts, prep
  memos sent to attendees, replies collected in threads.
- 🤖 **A real org** — CEO, department heads, specialists; each with its own
  persona ("soul"), accent color, and 3D office.

## Requirements

- An iPhone (iOS 18+) and a Mac on the same wifi.
- [Hermes Agent](https://hermes-agent.nousresearch.com) installed and set up
  on the Mac (free; bring your own model account).
- Xcode to build the app onto your phone (App Store build coming).

## Quick start

```bash
git clone <this-repo>
cd boardroom
./Scripts/setup.sh        # starts the relay + opens the pairing QR
```

Then build the app onto your iPhone (open `HermesMobile.xcodeproj`, ⌘R), open
**Gateway → Scan Pairing Code**, and scan the QR. That's it — say hello to
your CEO, or go straight to **Home → Boardroom** and switch the company on.

## How it works

```
iPhone (SwiftUI app)
   │  pair once via QR — then chat, voice, boardroom
   ▼
Mac relay (Scripts/hermes_mobile_relay.py, port 8787)
   │  keeps ONE warm Hermes agent (~2-3s replies)
   │  runs the company heartbeat (scout → debate → build)
   ▼
Hermes Agent on your Mac — your models, your tools, your data
```

Everything runs on hardware you own. No cloud account, no telemetry, no
third-party server — your agents, your machine, your company.

## Developing

```sh
xcodegen generate
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
python3 Scripts/test_hermes_company.py
python3 Scripts/test_hermes_acp_client.py
python3 Scripts/test_hermes_mobile_relay.py
```

## Status

Early but real: chat, voice calls, debates, meetings/memos, and the autonomous
company pipeline all work end-to-end today. Rough edges exist; issues and PRs
welcome.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md) — free for personal and
noncommercial use; commercial use requires a license. Boardroom is an
independent project, not affiliated with Nous Research.
