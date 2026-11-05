# Retention Operator Source Authority Recovery Task

Status: implemented and repository-verified
Date: 2026-08-23

## Goal

Keep automatic-retention health useful during independent read failures while
binding every retry, password step-up, cache update, and convergence refresh to
the exact signed-in workspace operator and current failed-schedule evidence.

## Existing Foundation

- The Retention backend already pins retry admission to the current failed run,
  owner, data class, target scope, property, policy version, and evidence
  version under the exact tenant schedule lock.
- The public endpoint already requires `retention.retry`, recent authentication,
  explicit confirmation, no-store responses, and deliberate stale, closed,
  unavailable, and conflict result mappings.
- Durable recovery requests and the Worker revalidate the same evidence before
  delegating generic retry behavior to GMA Task Runtime.

## Findings

- The health query cache key contains the tenant and page but not the exact
  signed-in operator, and local retry state resets only when the tenant changes.
- A refresh error discards a retained health snapshot and its whole-snapshot
  metrics instead of presenting it as delayed, inspection-only evidence.
- An open retry dialog can remain actionable after workspace, permission, or
  schedule evidence starts refreshing or becomes stale.
- Retry dispatch and completion callbacks do not capture and re-check their
  operator scope, page, permission authority, health source, and exact intent
  before mutating cache or local convergence state.
- Pagination and empty-page recovery use fetching state rather than current
  source authority, so stale empty data can be treated as authoritative.
- Rapid convergence polling stops as soon as a retry becomes accepted even
  when the failed schedule evidence has not yet advanced to running or a new
  terminal result.

## Ownership

- Retention owns schedule coordinates, current health evidence, retry admission,
  recovery receipts, and product polling semantics.
- Owner modules own legal holds, eligible records, destructive mutation, and
  exact owner-operation receipts.
- GMA Task Runtime owns generic run state, retry eligibility, leases,
  concurrency, and worker execution. Its existing contracts are sufficient.
- The web application owns identity-safe query keys, retained-snapshot
  presentation, current-source command gates, scope resets, late-completion
  fencing, and bounded convergence polling.
- No GMA, backend, schema, migration, broker, or container change is required.

## Decisions

- Append a normalized user-and-workspace identity to the existing Retention
  query prefix so cache invalidation remains compatible while operator data is
  isolated.
- Retain non-empty health snapshots and whole-snapshot metrics with an explicit
  delayed-state notice. A stale empty snapshot cannot prove that no schedules
  exist.
- Capture operator scope, page, and immutable retry intent in every submission.
  Dispatch and completion require current permission authority, current health
  evidence, and an exact current failed schedule.
- Keep an opened dialog visible when its evidence changes, but replace its
  destructive action with a refresh path. A late response from another scope
  cannot close the active dialog or start polling in the new scope.
- Poll at the short convergence cadence while the durable request is queued or
  accepted and the same failed schedule evidence remains visible. Stop when the
  schedule advances, retry fails, the page changes, or the bounded window ends.
- Preserve all server-side authorization, assurance, schedule locking,
  idempotency, and owner revalidation as the authority boundary.

## Delivery

- [x] Add Retention operator-scope, query-key, and retry-authority helpers.
- [x] Compose health loading, stale-snapshot, unavailable, empty, metric, and
  pagination states around current source authority.
- [x] Fence retry opening, confirmation, step-up continuation, dispatch, cache
  update, refresh, and local convergence to exact current evidence.
- [x] Keep queued and accepted retries on bounded rapid convergence until the
  schedule itself advances.
- [x] Add focused source-authority, intent, partial-failure, and convergence
  regression coverage.
- [x] Run one complete web gate and publish the coherent Retention slice.

## Invariants

- Retained health evidence may be inspected but cannot authorize a retry.
- A stale empty health page cannot become an authoritative empty state.
- A retry cannot be issued from another user, workspace, page, failed run,
  policy version, or evidence version.
- A late completion cannot mutate the active scope, close its dialog, or start
  its convergence timer.
- Accepted recovery is not presented as completed retention work; schedule
  evidence must advance independently.
- BunkFy Retention semantics do not leak into GMA.

## Verification Cadence

Use focused pure-helper and Retention web tests during implementation. At the
domain boundary, run one complete web typecheck, lint, test, build,
contract-drift, and root solution-membership gate. This web-only slice requires
no Docker or backend-wide gate.

## Completion Evidence

- The focused Retention health, retry-intent, and operator-authority suite passed
  14 tests across 3 files while the slice was assembled.
- The complete web gate passed TypeScript, lint, all 72 test files and 365
  tests, and the 3,032-module production Vite build.
- The OpenAPI snapshot and generated TypeScript contracts are current.
- Backend and root workspace solution files match the current repository graph,
  including this task record, and all edited repositories pass
  `git diff --check`.
- No backend, GMA, extension, schema, broker, migration, or container behavior
  changed; consequently no Docker or backend-wide test run was required.

## Publication

- Web `dev`: `6070857` (`Keep retention recovery bound to current evidence`).
- Backend remains at `67f11b52`; the audited retention APIs and durable recovery
  pipeline required no change.

## Deferred

- Approved retention periods, legal-hold policy, terminal evidence cleanup,
  cursor pagination, server-side filtering, and alert-routing policy.
- Hosted same-release Retention proof, production schedule observation,
  provider/legal approval, and independent assurance evidence.
