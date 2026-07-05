# The Boardroom Holding Company — Draft Roadmap

**Status: DRAFT · high-level · no implementation.** A destination and a sequenced
path for turning the Boardroom from "an autonomous company that builds iOS apps"
into a multi-division AI holding company: a **Games Studio**, a **Client Services**
arm, and a **Commerce** arm — all inside the walkable 3D HQ campus.

Date: 2026-07-04

---

## 0. The core insight

All three ideas are the **same machine** — the multi-agent company running
`brief → build → gate → deliver` — pointed at three different outputs. So we do
NOT build three apps. We build ONE platform (the "spine") and drop in three
**divisions** as modules. Roughly 80% shared infrastructure, 20% per-division.

The 3D HQ becomes the **campus**: one wing per division.

---

## 1. The shared spine (build once — every division uses it)

| Spine piece | Status | Notes |
|---|---|---|
| Multi-agent company + boardroom loop | ✅ exists | `hermes_company.py` engine |
| brief → build → **QA gate** → ship pipeline | ✅ exists | deliverables under `~/Documents/Boardroom/` |
| Deliverables + Company Vault (versioned) | ✅ exists | `Boardroom-Vault/` |
| Company constitution + shared memory | ✅ just built | Phases 1–2 |
| 3D walkable HQ (campus base) | ✅ just built | HQ 50x |
| **Asset-generation layer** | 🟡 tools installed, not wired | Higgsfield (image/video), ElevenLabs (audio) |
| **Project intake** (a job = Andrew's idea OR a client brief + data/assets) | 🔴 new | the front door for all divisions |
| **Domain "second gate"** per division | 🔴 new | Fun / Accuracy / Conversion (on top of QA) |
| **Multi-tenant infra** (auth, per-client isolation, hosting) | 🔴 new — *only if serving clients* | the biggest fork |

**Spine work before any division scales:** wire the asset layer into the builder;
build the project-intake front door; define the per-division gate pattern.

---

## 2. The three divisions

### 🎮 Division 1 — Games Studio
- **Output:** narrow **web/HTML5** games — daily-puzzle / hyper-casual / viral-funnel.
  Not "a game"; a factory for one monetizable, AI-content-friendly genre.
- **Why web, not native:** agents already write JS; a game ships as a URL (Vercel
  plugin) with no App-Store gatekeeper; instant distribution.
- **New parts:** game runtime; **Fun Gate** = a *Game Designer* agent that can
  reject an un-fun build the way QA rejects stubs; playtest choreography;
  distribution agent (itch.io / Reddit / portals).
- **3D room — Games Production Room:** arcade screen showing the live current
  build; playtest couch with two robots "playing"; design whiteboard rendering
  the real GDD. **Signature feature: the arcade cabinet is actually playable —
  walk up in your HQ and play the game your agents shipped.**
- **Money model:** viral brand funnel (drives your paid products) + ad-monetized
  volume. Lowest direct $, highest wow, lowest risk (it's *yours*, no client).
- **First milestone:** one playable daily-puzzle web game, shipped to a URL,
  playable on the HQ arcade cabinet.

### 💼 Division 2 — Client Services (consulting / workflows)
- **Output:** paid deliverables for real businesses. **Start = promo videos**
  (Higgsfield-powered, low liability) → market research → financial analysis
  (LAST, heavy guardrails).
- **New parts:** client intake + secure data upload; **Accuracy Gate** (zero
  hallucinated numbers — the hardest technical problem); liability/disclaimer
  scoping ("insights, not advice"); client-facing delivery. **Forces the
  multi-tenant infra fork.**
- **3D room — Client Services wing:** a client's project is a room they (or you)
  can walk into and watch the firm work the brief.
- **Money model:** per-deliverable or monthly retainer. **Strongest direct
  revenue of the three.**
- **First milestone:** "Give us your business + product → launch-ready promo
  video + ad copy in 24h," delivered to one paying test client.

### 🛒 Division 3 — Commerce (online stores)
- **Output:** e-commerce storefronts — for you (dropship / print-on-demand the
  company runs and earns from) or for clients (store-as-a-service).
- **New parts:** store builder (Shopify / WooCommerce / Wix — MCP connectors
  exist); product sourcing; Stripe payments; GoDaddy domains; **Conversion Gate**
  (does it actually sell?); order/inventory ops.
- **3D room — Commerce floor:** a storefront wall showing live stores + real
  sales; walk up to see a store's revenue.
- **Money model:** store revenue (yours) or build-fee/subscription (clients').
  Real money, but the most ops-heavy division.
- **First milestone:** one live, transacting store (single product line) the
  company built end-to-end.

---

## 3. Decisions needed (the forks — Andrew's call, captured here)

1. **Company vs. Firm-for-hire vs. Both.** Games + Commerce can run as "Andrew's
   company earns." Client Services is inherently client-facing. *Any* client-facing
   division triggers multi-tenant infra. *Provisional lean:* Games + Commerce are
   yours; Client Services is the client-facing arm.
2. **Sequence.** Not all three at once. *Provisional lean:* Games → Client
   Services → Commerce (rationale in §4).
3. **Hosting.** The Mac relay can't scale to multi-tenant client work — a real
   backend is required at the first client-facing division.
4. **Per-division gate owners.** Who is the Fun / Accuracy / Conversion judge
   agent, and what's their reject authority.

---

## 4. Suggested sequencing (challenge to "all three now")

Building three divisions simultaneously = three 60%-done divisions that each earn
nothing. Sequence it so every phase ships something real.

- **Phase 0 — Foundations.** Resolve the forks. Harden the spine: wire the asset
  layer, build the project-intake front door, define the gate pattern.
- **Phase 1 — Games first.** It's *yours* (no client liability), it proves the
  whole spine + asset gen + 3D-room integration on low stakes, and the playable
  arcade is a costless-if-it-flops wow demo.
- **Phase 2 — Client Services (promo-video wedge).** Once the machine is *trusted*,
  point it at paying clients on the safe, high-money deliverable. Adds the
  multi-tenant/hosting build.
- **Phase 3 — Commerce.** The ops-heaviest; do it when the pipeline is
  battle-tested.
- **Phase 4 — The campus.** Tie the wings together + a holding-company dashboard
  (all divisions' output + revenue at a glance).

Each phase runs its own `brainstorm → spec → plan → build → test` cycle — the same
discipline used for the second-brain phases.

---

## 5. What already exists to build on

- Multi-agent company + boardroom loop + build/QA/ship pipeline.
- Deliverables + Company Vault + the constitution/memory brain (Phases 1–2).
- The 3D walkable HQ (HQ 50x) — the campus base, with the room/wing pattern and
  the tappable-board plumbing already proven.
- **Tooling on hand:** Higgsfield (image/video), ElevenLabs (audio), Vercel plugin
  (deploy), and MCP connectors for Shopify / WooCommerce / Wix / Stripe / GoDaddy /
  QuickBooks — the division-specific toolkits are largely already available.

---

## 6. Risks / reality checks

- **Scope:** this is a 6–12 month vision, not a sprint. Sequencing keeps each phase
  shippable and useful on its own.
- **#1 risk — focus dilution:** one division fully working before the next.
- **Client Services is the hardest + riskiest** (multi-tenant, data, liability,
  accuracy) — deliberately later, heavily gated.
- **Every division needs its own second gate** (Fun / Accuracy / Conversion) on top
  of QA — non-negotiable for quality and, for clients, for trust.
- **Money honesty:** Games = weakest direct revenue (run it as a funnel/wow),
  Client Services = strongest, Commerce = real but ops-heavy.

---

## 7. Next step

When the forks in §3 are called, we brainstorm **Phase 1** in detail (its own spec
+ plan) before any code. This document is a draft — expect it to change as the
forks get answered.
