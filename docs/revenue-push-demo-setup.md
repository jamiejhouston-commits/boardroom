# Boardroom — Push, Demo Day & Revenue setup

Three features shipped 2026-07-02. Each degrades gracefully when its key is
missing, so nothing breaks if you set these up later (or never).

## 1. Real push notifications (approve from anywhere)

The relay sends APNs pushes straight to your iPhone — closed app, cellular,
anywhere — the moment an initiative reaches a gate, gets blocked, or ships.
Gate pushes carry **Greenlight ✓ / Kill it** buttons (Face ID-guarded), so you
can run the company from the lock screen.

One-time setup:

1. [Apple Developer → Keys](https://developer.apple.com/account/resources/authkeys/list)
   → create a key with **Apple Push Notifications service (APNs)** enabled.
   Download `AuthKey_XXXXXXXXXX.p8` (only downloadable once) and note the
   **Key ID** and your **Team ID** (Membership page).
2. Save the file somewhere private, e.g. `~/.hermes/AuthKey_XXXXXXXXXX.p8`.
3. Create `~/.hermes/apns.json`:

   ```json
   {
     "key_path": "~/.hermes/AuthKey_XXXXXXXXXX.p8",
     "key_id": "XXXXXXXXXX",
     "team_id": "YOUR_TEAM_ID",
     "bundle_id": "com.jamiehouston.boardroom",
     "environment": "development"
   }
   ```

   `environment` — `development` for Xcode installs on your iPhone,
   `production` for TestFlight/App Store builds.
4. Rebuild the app once (`xcodegen generate`, then Run from Xcode — the
   project now carries the `aps-environment` entitlement). On first launch
   the app registers its device token with the relay automatically.
5. Check it: `curl -s http://127.0.0.1:8787/health` should show `"apns": true`,
   and the relay log prints `company - pushed: …` when a gate fires.

No key? Everything still works over the existing local notifications when the
app is open or recently backgrounded.

## 2. Demo Day screenshots (see it before you ship)

No setup. When a product finishes its QA rounds, the builder captures real
screenshots into `<project>/.demo/` (simulator for iOS apps, headless browser
for web). The initiative screen in the app shows them as a swipeable gallery
at Demo Day — your gate-2 call is never blind again. If capture is truly
impossible, the builder writes `.demo/README.md` saying why instead of faking.

## 3. Revenue loop (RevenueCat)

The Boardroom → **Revenue** screen shows what the shipped portfolio earns, and
the same numbers are briefed to the scout every cycle so the company pitches
more of what makes money.

1. [RevenueCat dashboard → API keys](https://app.revenuecat.com/) → create a
   **secret** API key (v2, read access is enough).
2. Create `~/.hermes/revenue-keys.json`:

   ```json
   {
     "revenuecat_api_key": "sk_...",
     "revenuecat_project_id": "proj..."
   }
   ```

   `revenuecat_project_id` is optional — the first project on the account is
   used when omitted.
3. Check it: `curl -s -H "Authorization: Bearer <relay token>"
   http://127.0.0.1:8787/company/revenue` returns your metrics.

On a shipped initiative, **Prepare App Store release** hands the team a
release work order (fastlane, metadata, RevenueCat paywall, a RELEASE.md
checklist of the steps only you can do). Same team, same codebase, back to
Demo Day when it's done.

## 4. Voice-cost policy (free by default, ElevenLabs for sales only)

Every **internal** voice — 1:1 calls, boardroom meetings, office chatter,
voice notes, status updates — always speaks on the **free** voice (Piper on
the Mac, Apple on device). It cannot touch ElevenLabs, ever.

The **paid ElevenLabs voice** exists only for external, revenue-facing work
(sales calls, customer calls, pitches, demos, marketing assets) and is
quadruple-guarded:

1. **Off by default** — enable it in the app under Settings → Voice.
2. **Confirmation** before each paid generation (on by default).
3. **Character budgets** enforced on the relay — `daily_char_budget` /
   `weekly_char_budget` in `~/.hermes/elevenlabs.json` (defaults 10k/40k).
   Over budget, speech silently falls back to the free voice.
4. **Visible badge** — anything using the paid voice shows a gold
   "Paid voice · ElevenLabs" chip; Settings → Voice shows live budget usage.

The relay is the enforcement point: only `/tts` requests explicitly marked
`"tier": "premium"` can reach ElevenLabs. Your key lives in
`~/.hermes/elevenlabs.json` (never in the repo).
