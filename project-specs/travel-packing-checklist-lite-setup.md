# Travel Packing Checklist Lite — Setup Specification

Date: 2026-06-20
Owner: Andrew
Pipeline owner: AgentsOrchestrator / General Manager
Status: Active — smallest shippable MVP

## Owner signal

Travel Packing Checklist Lite has been stuck. The correction is execution, not discussion. This spec defines the smallest buildable product and blocks scope creep.

## Core job

Help a traveler create a simple packing checklist, check items off, customize missing items, and trust that the checklist remains saved locally.

## Product positioning

Travel Packing Checklist Lite helps users pack for any trip in minutes with a simple checklist that works immediately — no account, no clutter, no travel-planner bloat.

## MVP behavior

1. User opens the app and sees saved trips plus a `New Trip` action.
2. User creates a trip by entering a trip name and selecting one of five templates.
3. App generates a starter packing checklist from the selected template.
4. User checks/unchecks items while packing.
5. User adds, edits, and deletes checklist items.
6. User returns later and the trip/checklist state persists locally.
7. User can delete a trip.

## Required trip templates

Exactly these five templates for MVP:

- Weekend Trip
- Business Trip
- Beach Trip
- Camping Trip
- International Trip

## Minimum template contents

### Weekend Trip

- Shirts
- Pants
- Underwear
- Socks
- Toiletries
- Phone charger
- Pajamas

### Business Trip

- Dress shirts
- Dress pants
- Blazer
- Laptop
- Laptop charger
- Business shoes
- Toiletries

### Beach Trip

- Swimsuit
- Towel
- Sunscreen
- Sandals
- Sunglasses
- Hat
- Toiletries

### Camping Trip

- Tent
- Sleeping bag
- Flashlight
- Water bottle
- Snacks
- Jacket
- Toiletries

### International Trip

- Passport
- Travel adapter
- Phone charger
- Toiletries
- Underwear
- Socks
- Medications

## Data requirements

### Trip

- `id`
- `name`
- `tripType`
- `createdAt`
- `updatedAt`
- `items`

### Checklist item

- `id`
- `title`
- `isPacked`
- `createdAt`

## Acceptance criteria

- App launches without crash.
- Fresh install shows a useful empty state and `New Trip` action.
- Empty trip names are blocked.
- Creating a trip generates the correct template items.
- Saved trips list shows trip name, trip type, and packed count.
- Tapping a trip opens its checklist.
- Checking/unchecking an item saves immediately.
- Adding an item blocks empty titles and persists valid items.
- Editing an item blocks empty titles and preserves packed state.
- Deleting an item affects only that item.
- Deleting a trip removes that trip and its items.
- Force quit and relaunch preserves trips, items, and packed states.
- No account, login, backend, payment, subscription, cloud sync, sharing, AI, weather, flight/hotel import, or notifications in MVP.

## Non-goals

- No full travel planner.
- No itinerary builder.
- No collaboration or sharing.
- No AI suggestions.
- No weather integrations.
- No monetization work before first shippable build.
- No analytics dashboard.
- No advanced theming.

## QA gate

MVP can only be marked ready when QA verifies:

- Create Weekend Trip.
- Check at least one item.
- Add a custom item.
- Edit the custom item.
- Delete an item.
- Return home and reopen the trip.
- Force quit/relaunch and confirm data remains.
- Delete the trip.
- Confirm no non-MVP account/payment/cloud surfaces appear.

## Launch asset copy

Subtitle options:

- Simple trip packing lists
- Don’t forget travel essentials
- Fast checklist for every trip

Hooks:

- Stop forgetting the obvious stuff.
- Open. Check. Pack. Go.
- No account. No itinerary. Just your packing list.

Screenshot copy:

1. Pack without forgetting essentials
2. Ready-made lists for common trips
3. Check items off as you pack
4. Customize only what matters
5. Simple, fast, no account required
