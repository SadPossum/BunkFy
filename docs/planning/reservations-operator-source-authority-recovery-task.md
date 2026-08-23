# Reservations Operator Source Authority Recovery Task

Status: complete
Date: 2026-08-23

## Goal

Keep reservation, availability, topology-label, history, and linked-guest
context usable during partial read failure while ensuring every reservation or
guest-link command is based on current permission and command-input evidence.

## Findings

- A reservation-directory refresh failure replaces a usable last-loaded list
  with a page-level error.
- The affected-reservations view treats one failed detail read as a failure of
  the whole collection instead of preserving successful siblings.
- Permission decisions retained by React Query can keep reservation creation,
  lifecycle, booking-detail, and guest-link controls actionable after an
  authority refresh fails.
- Reservation detail, history, linked-guest, and availability refresh errors
  hide retained snapshots that remain useful for operational orientation.
- Reservation creation accepts selected inventory without first proving that
  the latest settled availability result still contains every selected unit as
  available.
- Guest Record selection is an independent source, but existing guest-link
  commands do not distinguish a current candidate from a stale picker result.
- An open creation form can survive a property switch with selections and
  mutation-attempt identity from the previous property.

## Ownership

- Reservations owns booking identity, stay details, guest links, lifecycle,
  optimistic versions, operation identities, and its projections.
- Inventory owns sellable-unit availability, allocation, and topology-derived
  room labels. Availability is authoritative for reservation-create inventory
  selection; room inventory is presentation context only.
- Guests owns durable Guest Records, active-profile visibility, and profile
  versions. The reservation-guest workflow remains an explicit cross-module
  extension.
- GMA Access Control owns generic permission evaluation and resolved property
  scope enforcement.
- The web application owns independent source composition, stale-snapshot
  presentation, current-evidence gates, and bounded recovery affordances.
- Existing APIs already enforce tenant scope, resolved permissions, expected
  versions or revisions, idempotent mutation identity, and guest workflow
  policy. No backend, schema, framework, module, or extension change is
  required here.

## Decisions

- Preserve stale reservation lists, reservation details, history, availability,
  room labels, and linked guest profiles as visibly delayed read-only context.
- Require a settled successful permission evaluation for every write.
- Require current availability and a still-available exact unit selection for
  reservation creation. Room-label metadata may be stale or unavailable
  because it is not a command input.
- Require current reservation detail and an exact matching reservation version
  and details revision for lifecycle, booking-detail, and guest-link commands.
- Require a current Guest Record directory result containing the selected
  candidate before linking or replacing an existing Guest Record.
- Creating a new Guest Record from current reservation details does not depend
  on the Guest Record directory; it requires only its exact current permissions
  and reservation evidence.
- Keep successful affected-reservation siblings visible and retry failed reads
  without discarding the collection.
- Reset creation state and operation-attempt identity when the selected
  property changes.

## Delivery

- [x] Compose independent permission, directory, affected-detail, reservation,
  history, availability, room-label, guest-profile, and guest-picker sources.
- [x] Preserve stale snapshots with local notices, fallbacks, and retry paths.
- [x] Gate every reservation and guest-link mutation on its exact current
  evidence and record inputs.
- [x] Reconcile selected inventory only after a current availability response.
- [x] Keep partial affected-reservation results and focused-resource behavior
  stable during recovery.
- [x] Add focused source-state and mutation-authority tests.
- [x] Run one complete web gate and publish the coherent slice.

## Verification

- Complete web verification: 67 test files and 342 tests passed, followed by
  lint, typecheck, and a 3,021-module production build.
- Generated OpenAPI TypeScript contracts match the backend snapshot.
- Root solution membership and ordering are regenerated and checked by the
  canonical solution script.
- Backend remains at `67f11b52`; endpoint, permission, version, and durable
  operation enforcement required no change.

## Publication

- Web `dev`: `8a2c3f3` (`Keep reservation commands bound to current sources`).

## Invariants

- An unavailable directory is never represented as an authoritative empty
  reservation, history, availability, or guest list.
- Stale permission, availability, reservation, or guest-candidate evidence
  cannot enable a mutation.
- Expected versions, details revisions, and operation identities remain tied to
  the exact visible command intent, including safe retries after uncertain
  outcomes.
- Partial read failure cannot hide unaffected reservation records or unrelated
  detail sections.
- Module boundaries, cross-module extension ownership, raw payload handling,
  and server-side lifecycle coordination remain unchanged.

## Verification Cadence

Use focused reservation source-state, authority, attempt-identity, grouping,
and guest-workflow tests while editing. At the slice boundary, run one complete
web typecheck, lint, test, build, contract-drift, and root solution-membership
gate. This slice changes no backend, database, provider, broker, container, GMA
framework, or GMA extension behavior, so no Docker or GMA gate is required.

## Deferred

- Hosted browser rehearsal with concurrent staff sessions; this remains a
  candidate evidence gate rather than repository implementation.
- Server-backed virtualization if a real property exceeds the current bounded
  reservation and Guest Record page sizes.
- Reservation stay-amendment UI beyond the already published backend protocol;
  it should receive its own focused product slice.
