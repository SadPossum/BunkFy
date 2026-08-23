# Properties Operator Source Authority Recovery Task

Status: complete
Date: 2026-08-23

## Goal

Keep property, room, bed, processing-policy, and topology-retirement context
usable during partial read failure while ensuring every state-changing control
is based on current permission and record evidence.

## Findings

- A property-directory refresh failure replaces the whole page with an error
  even when a usable last-loaded property snapshot remains.
- Room and bed refresh failures hide their last-loaded topology and all
  unaffected sibling context.
- Permission decisions retained by React Query can keep create, edit, policy,
  and retirement controls visible after the authority refresh has failed.
- Room, bed, and property commands consume record versions, but the UI does not
  distinguish current records from stale snapshots before opening or
  submitting their forms.
- Processing state and country-policy discovery are independent reads. A stale
  policy list can currently reopen configuration controls, while a failed
  processing refresh hides the last known governance binding.
- Retirement progress is retained as query data, but retry and cancellation
  controls do not require a current retirement receipt.

## Ownership

- Properties owns physical topology, property identity, processing state,
  country-policy binding, record versions, and its projections.
- Inventory owns safe room and bed retirement coordination, active-claim
  drainage, retries, cancellation, and affected-reservation evidence.
- GMA Access Control retains generic permission evaluation and resolved-scope
  enforcement; authentication retains recent-assurance enforcement.
- The web application owns source composition, stale-snapshot presentation,
  current-evidence gates, and operation-specific recovery affordances.
- Existing APIs already enforce tenant scope, resolved permissions, current
  versions, confirmations, mutation identities, and configured assurance. No
  backend, schema, framework, module, or extension change is required here.

## Decisions

- Preserve stale property, room, bed, processing, policy, and retirement
  snapshots as visibly delayed read-only context.
- Require a settled successful permission evaluation before exposing any
  Properties or topology mutation.
- Require current property evidence for property edits, property retirement,
  room creation, and processing changes.
- Require current room evidence for room edits and room retirement. Require
  current room and bed-directory evidence for every bed write so labels and
  the room version are drawn from one coherent topology snapshot.
- Allow property creation only from current tenant-level permission evidence;
  it does not consume an existing property version.
- Require current processing and country-policy evidence before activation or
  policy replacement, and current processing evidence before suspension.
- Require a current retirement receipt before retrying finalization or
  restoring a draining room or bed to service.
- Keep unrelated property and topology sections usable when one source fails.

## Delivery

- [x] Compose independent property, permission, room, bed, processing, policy,
  and retirement sources.
- [x] Preserve stale topology and governance snapshots with local retry paths.
- [x] Gate each mutation on its exact current authority and record inputs.
- [x] Keep selection and focused-resource behavior stable during refreshes.
- [x] Add focused source and mutation-authority tests.
- [x] Run one complete web gate and publish the coherent slice.

## Verification

- Focused Properties source, processing, lifecycle, and retirement suite: 24
  tests passed.
- Complete web verification: 66 test files and 337 tests passed, followed by
  lint, typecheck, and a 3,020-module production build.
- Generated OpenAPI TypeScript contracts match the backend snapshot.
- Root solution membership and ordering are regenerated and checked by the
  canonical solution script.

## Publication

- Web `dev`: `43d36e3` (`Keep property commands bound to current sources`).
- Web validation follow-up: `382ff5e` (`Make workspace authority test
  cross-platform`) normalizes a pre-existing multiline source assertion for
  Windows CI checkouts.
- Backend remains at `67f11b52`; the audited APIs required no change.

## Invariants

- Unavailable topology is never represented as an authoritative empty property,
  room, or bed list.
- Stale permission or record evidence cannot enable a mutation.
- Expected versions and mutation operation identities remain tied to the exact
  visible command intent.
- Retirement history, affected reservations, recent-authentication prompts,
  and server-side coordinators remain unchanged.
- Raw API payloads and internal subject or scope identifiers are not copied
  into recovery notices.

## Verification Cadence

Use focused source-state, authority, property-processing, and retirement tests
while editing, then run one complete web typecheck, lint, test, build, and
contract-drift gate. This slice changes no backend, database, provider, broker,
container, GMA framework, or GMA extension behavior, so no Docker or GMA gate
is required.

## Deferred

- Server-filtered or virtualized property and topology pickers if real tenant
  estates exceed the current bounded hostel-scale directory assumptions.
- Hosted topology and processing lifecycle evidence, which remains an external
  release gate rather than repository implementation.
