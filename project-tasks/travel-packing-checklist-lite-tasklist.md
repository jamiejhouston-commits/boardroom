# Travel Packing Checklist Lite — Implementation Task List

Date: 2026-06-20
Source spec: `project-specs/travel-packing-checklist-lite-setup.md`
Pipeline: PM → ArchitectUX → Dev/QA loop → Integration
Retry rule: maximum 3 Dev attempts per task before escalation.

## Current-state audit

- Repo search found no existing Travel Packing Checklist Lite implementation, spec, or tasklist.
- Created the missing setup spec and this execution tasklist.
- Existing repo has unrelated modified/untracked files; do not overwrite them.

## Phase 1 — PM scope lock

### Task 1: Confirm MVP-only scope

Owner requirement: ship a Lite packing checklist, not a bloated travel planner.

Acceptance criteria:

- MVP includes trip templates, checklist CRUD, check/uncheck, local persistence, and delete trip.
- MVP explicitly excludes accounts, backend, cloud sync, payments, AI, sharing, weather, flights/hotels, and notifications.
- Any proposed feature outside MVP goes to post-launch backlog.

QA gate:

- Read spec and verify no luxury feature is required for launch.

## Phase 2 — ArchitectUX

### Task 2: Define app navigation and screens

Required screens:

1. Saved Trips / Home
2. New Trip
3. Trip Detail
4. Add/Edit Item sheet or inline editor

Acceptance criteria:

- Home screen has app title, `New Trip`, saved trips list, and empty state.
- New Trip screen has trip name field, five trip types, create/cancel actions.
- Trip Detail screen has trip title/type, packed count, checklist rows, add item, edit/delete item, and empty checklist state.
- Navigation has no dead ends.

QA gate:

- Fresh user can understand and create a trip within 60 seconds.

## Phase 3 — Dev/QA task loop

### Task 3: Implement data model and local storage

Acceptance criteria:

- `Trip` has `id`, `name`, `tripType`, `createdAt`, `updatedAt`, `items`.
- `ChecklistItem` has `id`, `title`, `isPacked`, `createdAt`.
- Create/read/update/delete works locally.
- Data survives force quit and relaunch.
- Core app works without network.

QA gate:

- Create trip, change checklist state, force quit/relaunch, verify data remains.

### Task 4: Implement static trip templates

Acceptance criteria:

- Exactly five templates exist: Weekend, Business, Beach, Camping, International.
- Selecting a template generates correct default items from the spec.
- Templates are local/static, not remote.

QA gate:

- Create at least three different trip types and confirm relevant items appear.

### Task 5: Implement home/saved trips screen

Acceptance criteria:

- Empty state: `No trips yet. Create your first packing checklist.`
- Saved trip row shows trip name, trip type, and packed count like `4/12 packed`.
- Tapping a row opens the correct trip.
- Deleting a trip removes only that trip.

QA gate:

- Create multiple trips, open each, confirm data does not mix between trips, delete one and verify others remain.

### Task 6: Implement new trip flow

Acceptance criteria:

- `New Trip` opens trip creation.
- Trip name is required.
- One of five templates can be selected.
- `Create Trip` is disabled or blocked when name is empty.
- Creating saves trip, generates preset items, and opens detail.
- Cancel returns without saving.

QA gate:

- Attempt empty trip name, then create a valid Beach Trip and verify details.

### Task 7: Implement trip detail checklist

Acceptance criteria:

- Shows trip name, trip type, checklist items, and packed progress.
- Each item has title and checked/unchecked state.
- Toggle saves immediately.
- Back navigation returns to home without losing state.

QA gate:

- Check/uncheck several items, navigate away/back, verify state remains.

### Task 8: Implement add/edit/delete item

Acceptance criteria:

- Add item blocks empty titles.
- New item appears immediately and starts unpacked.
- Edit item blocks empty titles and preserves packed state.
- Delete item removes only that item.
- Custom item changes persist after relaunch.
- If all items are deleted, show `No items yet. Add something to pack.`

QA gate:

- Add, edit, check, delete, relaunch, verify all expected state.

## Phase 4 — Integration QA

### Task 9: End-to-end release gate

Must pass:

- Fresh install launch.
- Create Weekend Trip.
- Check at least one item.
- Add custom item.
- Edit custom item.
- Delete item.
- Return home and reopen trip.
- Force quit/relaunch and confirm data remains.
- Delete trip.
- Confirm no login/payment/cloud/AI surfaces appear.
- VoiceOver smoke test: main controls have meaningful labels and checklist state is understandable.
- Dynamic Type smoke test: core flow remains usable.

Failure handling:

- If QA fails, return task to Dev with exact reproduction steps.
- Retry up to 3 times.
- After 3 failures, escalate with blocker, suspected root cause, and smallest workaround.

## Phase 5 — Launch package

### Task 10: Prepare App Store-lite assets

Acceptance criteria:

- Positioning line: `Pack faster. Forget less. No setup required.`
- Subtitle selected from spec.
- 3 hooks prepared.
- 5 screenshot captions prepared.
- No claims of AI, sync, personalization, downloads, ratings, or traction unless actually implemented/verified.

QA gate:

- Marketing copy matches shipped behavior exactly.

## Agent assignments

- PM: scope lock, task acceptance criteria, no luxury additions.
- ArchitectUX: screen flow, empty states, navigation simplicity.
- Dev: implement task-by-task only after prior QA gate passes.
- QA: validate every task with evidence; failed tasks loop back to Dev.
- Integration: final build/test/package check.
- Marketing: App Store copy only after shipped behavior is verified.

## Immediate next command to Dev

Implement Tasks 3–6 first as the vertical slice: local models/storage, templates, home screen, and new trip flow. Do not start monetization, cloud, AI, sharing, or travel-planner features.
