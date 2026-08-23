# Guests Operator Source Authority Recovery Task

Status: complete
Date: 2026-08-23

## Goal

Keep guest directories, profiles, and stay history useful during partial read
failure while ensuring every Guest Record command is based on current
permission and exact record-version evidence.

## Findings

- Retained permission decisions can leave create, edit, and archive controls
  actionable after permission refresh fails.
- A directory refresh failure replaces a usable last-loaded guest list with a
  page-level error.
- React Query placeholder data from a previous page, search, or status filter
  is rendered as though it belongs to the current directory request.
- Guest-profile and stay-history refresh errors hide retained snapshots that
  remain useful for operational orientation.
- Update and archive submit the profile captured when a form opened without
  proving that the current detail source still has the same Guest Record
  version.
- Open create, edit, and archive state can survive a property switch and submit
  against the newly selected property.
- Empty-page pagination recovery runs against any retained response instead of
  only a settled current directory or stay-history response.

## Ownership

- Guests owns durable guest profiles, profile status, optimistic versions,
  operation identities, archive behavior, and the stay-history projection.
- Reservations owns reservation participation and lifecycle events consumed by
  the Guests stay projection.
- GMA Access Control owns generic permission evaluation and resolved property
  scope enforcement.
- The web application owns independent source composition, stale-snapshot
  presentation, current-evidence gates, and bounded recovery affordances.
- Existing APIs already enforce tenant scope, resolved permissions, expected
  versions, and idempotent mutation identity. No backend, schema, framework,
  module, or extension change is required here.

## Decisions

- Preserve stale guest directories, profiles, and stay history as visibly
  delayed read-only context with local retry paths.
- Do not render placeholder data from a different directory key as though it
  belongs to the current page, search, or status filter.
- Require a settled successful permission evaluation for every write.
- Require current guest detail and an exact matching Guest Record version for
  update and archive commands.
- Close property-bound reads and command forms after a current permission
  decision revokes their required capability; a failed refresh keeps the last
  permitted snapshot visible but read-only.
- Creating a Guest Record requires current create permission but does not depend
  on the guest directory being available.
- Close all command forms, clear selected records, and discard operation-attempt
  identity when the selected property changes.
- Bind in-flight mutation completion and cache invalidation to the property that
  initiated the command so a late response cannot reopen another property.
- Adjust pagination only after a settled successful response for the requested
  page.

## Delivery

- [x] Compose independent permission, directory, profile, and stay-history
  sources.
- [x] Preserve stale snapshots with local notices, fallbacks, and retry paths.
- [x] Gate create, update, and archive on their exact current evidence.
- [x] Reset all property-bound command and selection state on property change.
- [x] Add focused source-state and mutation-authority tests.
- [x] Run one complete web gate and publish the coherent slice.

## Verification

- Complete web verification passed with 68 test files and 345 tests, followed
  by lint, typecheck, and a 3,022-module production build.
- Generated OpenAPI TypeScript contracts match the backend snapshot.
- Backend and root workspace solutions regenerate deterministically, pass their
  synchronization checks, and list successfully through `dotnet sln`.
- Backend remains at `67f11b52`; endpoint permission, optimistic-version, and
  durable operation enforcement required no change.

## Publication

- Web `dev`: `cfd1479` (`Keep guest commands bound to current sources`).

## Invariants

- An unavailable directory is never represented as an authoritative empty
  guest or stay-history list.
- Stale permission or Guest Record evidence cannot enable a mutation.
- Expected versions and operation identities stay tied to the exact visible
  command intent.
- A property switch cannot reuse Guest Record state or operation identity from
  the previous property.
- Guests remains independently removable and does not gain a direct
  Reservations implementation dependency.

## Verification Cadence

Use focused Guests source-state, authority, and attempt-identity tests while
editing. At the slice boundary, run one complete web typecheck, lint, test,
build, contract-drift, and root solution-membership gate. This slice changes no
backend, database, provider, broker, container, GMA framework, or GMA extension
behavior, so no Docker or GMA gate is required.

## Deferred

- Hosted browser rehearsal with concurrent staff sessions; this remains a
  candidate evidence gate rather than repository implementation.
- Server-backed virtualization if a real property exceeds the current bounded
  guest page sizes.
