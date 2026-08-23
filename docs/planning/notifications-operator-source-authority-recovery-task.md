# Notifications Operator Source Authority Recovery Task

Status: complete
Date: 2026-08-23

## Goal

Keep personal notifications and announcements useful during independent read or
stream failures while binding read side effects, unread counters, cache state,
and late completion to the exact signed-in user and workspace.

## Findings

- Page list and detail cache keys omit both workspace and user identity. Session
  transitions currently clear most queries, but the feature itself does not
  prevent late updates or future cache reuse across an identity boundary.
- A list or detail refresh error replaces a usable last-loaded inbox snapshot
  with a generic error.
- Automatic read acknowledgement and mark-all-read use retained list state
  without proving that the source and active identity are still current.
- Optimistic unread-summary updates use a broad query prefix and can decrement
  cached summaries belonging to another workspace.
- Personal and announcement streams start only after both summary reads
  succeed, so one unavailable inbox disables live updates for the other.
- Stream reconnects use a fixed delay, synchronizing repeated client retries
  during an outage instead of applying bounded exponential jitter.
- Workspace changes reset the visual attention set but can retain an old detail
  deep link, page, tab, and mutation result.
- Pagination remains actionable while its count is stale, and empty current
  pages do not recover to the previous page after concurrent inbox shrinkage.

## Ownership

- GMA Notifications owns generic subject/scope authorization, personal and
  broadcast inbox persistence, idempotent read commands, unread counts, durable
  sequence cursors, access-leased streams, and notification API contracts.
- Operations Notifications owns BunkFy notification wording, least-privilege
  audience selection, initiating-user exclusion, typed navigation payloads,
  severity, and product notification policy.
- The web application owns source composition, identity-safe cache keys,
  stale-snapshot presentation, current-evidence gates, local optimistic state,
  stream supervision, navigation, and bounded recovery affordances.
- No backend, schema, GMA framework, GMA Notifications, or Operations
  Notifications change is required for this slice.

## Decisions

- Use one normalized user-and-workspace scope key in every list, detail,
  summary, pending-read, invalidation, and late-completion identity.
- Preserve stale list and detail snapshots with local delayed-state notices and
  retry actions; never present an unavailable inbox as authoritative empty.
- Mark an item read only when it is visible from a current list or current
  detail source in the active scope. Keep the command idempotent and reconcile
  the exact inbox after uncertain failure.
- Allow mark-all-read only from a current selected inbox and capture its exact
  scope and inbox kind in the submission.
- Keep personal and announcement summary reads and streams independent.
- Reconnect recoverable streams with bounded exponential jitter and reset the
  delay after a stable connection; terminal client failures remain terminal.
- Clear selected notification intent and local command state on an actual user
  or workspace switch, including transitions that briefly have no session.
- Use the shared pagination component and disable navigation while its source
  is not current.

## Delivery

- [x] Introduce canonical identity-scoped notification query keys and mutation
  authority helpers.
- [x] Compose independent list and detail sources with stale snapshot recovery.
- [x] Fence automatic read and mark-all commands to current source and scope.
- [x] Isolate personal and announcement live streams and add bounded reconnect
  backoff.
- [x] Reset deep links, paging, attention, and command state across identity
  boundaries.
- [x] Add focused cache, authority, partial-failure, read-state, and reconnect
  tests.
- [x] Run one complete web gate and publish the coherent slice.

## Verification

- Focused source-authority, stream, read-state, destination, and foundation
  verification passed with 4 test files and 45 tests.
- Complete web verification passed with 70 test files and 354 tests, followed
  by lint, typecheck, and a 3,029-module production build.
- Generated OpenAPI TypeScript contracts match the backend snapshot.
- Backend and root workspace solutions regenerate deterministically, pass their
  synchronization checks, and list successfully through `dotnet sln`.
- Backend remains at `67f11b52`; GMA Notifications subject/scope authorization,
  idempotent read commands, durable cursors, and stream access leases already
  enforce the server boundary and required no change.

## Publication

- Web `dev`: `e3ccab1` (`Keep notification inboxes bound to current sources`).

## Invariants

- One user or workspace cannot display or mutate another inbox through retained
  client cache state or late asynchronous completion.
- An unavailable inbox is never represented as an authoritative empty inbox.
- Stale list or detail evidence cannot trigger automatic read acknowledgement
  or mark-all-read.
- Failure of one notification source cannot stop live updates for the other.
- Retry behavior is bounded, jittered, abortable, and terminal for permanent
  client errors.
- BunkFy-specific notification semantics do not leak into GMA Notifications.

## Verification Cadence

Use focused notification source, read-state, destination, stream, and structural
tests while editing. At the slice boundary, run one complete web typecheck,
lint, test, build, contract-drift, and root solution-membership gate. This slice
changes no backend, database, provider, broker, container, GMA framework, or
GMA module behavior, so no Docker or GMA gate is required.

## Deferred

- Hosted multi-user and revoked-workspace browser rehearsal.
- Push, email, SMS, escalation, quiet-hours, and user preference product UX.
- Product-specific retention approval and production admission evidence, which
  remain tracked by the Operations Notifications production-admission task.
