# Preview Retention Proof Task

Status: completed
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

## Outcome

- Commit `eb4580a` added schema-v2 baseline/lower-bound evidence, strict
  production-admission validation, Preview composition, and deterministic race
  and stale-completion fixtures. Commit `f0c4922` moved every PowerShell
  deployed probe onto the shared atomic operator-only evidence writer.
- Exact release `preview-retention-f0c4922` passed the umbrella Preview rehearsal:
  Retention 7/7, invitation 8/8, enrollment 9/9, and parent 10/10 checks.
- The fresh workspace projected six healthy schedules. Both asserted Ingestion
  runs completed after the pre-provisioning lower bound with zero remaining
  backlog and continuous release identity.
- Parent and child evidence is retained under
  `.tmp/deployment-probes/preview-onboarding-retention-f0c4922*.json`. All four
  files are mode `0600`, and every child SHA-256 matches the parent record.
- Cleanup removed two non-owner memberships, retired two properties, archived
  the workspace, revoked all sessions, and purged Mailpit. Final inspection
  found an empty unpublished Mailpit, a running Worker on the backend network,
  and no management network.
- `eng/verify-operations.ps1` passed after the final implementation. Backend,
  GMA Framework, and GMA Skeleton code were not changed by this slice.
