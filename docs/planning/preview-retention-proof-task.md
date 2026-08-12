# Preview Retention Proof Task

Status: in progress
Date: 2026-08-12

## Goal

Retain one exact-release Preview proof that a newly projected workspace receives
the product Retention catalogue, that the whole returned catalogue is healthy,
and that the real Worker completes both explicitly asserted Ingestion schedules
without an Admin trigger or direct data-store mutation.

## Ownership

- Retention and each contributing module continue to own their schedules,
  execution, health projection, and tenant data.
- The deployed Retention verifier owns read-only contract validation and
  scrubbed evidence.
- The Preview onboarding harness owns synthetic identity/workspace setup,
  passing an observation lower bound, and cleanup.
- GMA TaskRuntime remains unchanged; this slice does not generalize product
  schedule semantics into the framework.

## Invariants

1. The standalone verifier's existing next-occurrence behavior remains the
   default for established workspaces.
2. A caller may count already completed occurrences only when it supplies an
   explicit UTC lower bound and both asserted Ingestion schedules completed
   after that bound.
3. The verifier remains read-only: no task enqueue, Admin retry, database seed,
   owner-record read, or repair path is allowed.
4. Preview captures the lower bound before workspace creation and retains the
   Retention result as a checksum-bound child of the onboarding rehearsal.
5. Tokens, headers, payloads, personal data, and owner records never enter
   evidence. Cross-workspace denial and exact-release continuity remain
   mandatory.
6. Failure still performs normal membership, property, workspace, session, and
   Mailpit cleanup; no Retention-owned table is edited for cleanup.

## Delivery

- Add an optional completed-after lower bound to the deployed verifier.
- Add `-IncludeRetention` and child-evidence binding to the Preview onboarding
  rehearsal.
- Cover first-completion success, stale-completion rejection, default behavior,
  evidence redaction, and harness composition with focused fixture tests.
- Update the deployed Retention and Preview onboarding runbooks.
- Run one exact-release Preview rehearsal, verify cleanup and private surfaces,
  then run the consolidated operations gate once.

## Deferred

- This Preview proof does not establish hosted maintenance-owner topology,
  alert delivery, legal-hold behavior, Admin retry, object deletion, or a Worker
  restart drill.
- Production admission still requires approved policy and private operational
  references in addition to this public engineering evidence.
