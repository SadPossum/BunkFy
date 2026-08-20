# Post-Domain Candidate Publication Refresh Task

Status: in progress
Date: 2026-08-20

## Goal

Publish one current, reviewable source and image candidate after the completed
Reservations, Retention, and Data Rights production-preparation slices. The
previous attested candidate predates those changes and its retained OCI bytes
must not be reused as evidence for the current source graph.

## Boundary

- The BunkFy root commit owns the recursive source identity and exact backend,
  web, and GMA pins.
- Backend validation must first pass for the exact published backend commit.
- Root validation owns the clean-checkout product gate for the candidate root.
- Product Image Evidence owns one build, scan, checksum closure, attestation,
  and bounded retention of the unpublished backend and web OCI archives.
- A disposable candidate runtime rehearsal may execute those exact archives;
  ordinary local Preview images are useful composition evidence but are not the
  GitHub-built candidate bytes.
- Registry promotion, hosted migration and rollout, rollback, private approval,
  legal authorization, and production data remain deployment-owned gates.

## Delivery

1. [x] Commit this ledger with the exact current recursive source graph.
2. [ ] Require successful backend `validate` and `Security Baseline` runs for
   the exact backend commit.
3. [ ] Dispatch root `validate` once for the exact candidate head.
4. [ ] Dispatch Product Image Evidence once, retaining candidate bytes for 14
   days so the approved promotion or rehearsal boundary can consume them.
5. [ ] Verify exact head SHA, workflow conclusions, artifact identities,
   closed checksums, scan policy, and GitHub attestations.
6. [ ] Rehearse the exact retained OCI archives in a disposable Preview
   composition and remove its resources.
7. [ ] Keep the bundle unpublished until an approved non-local registry and
   private release record exist.

## Verification Cadence

Do not rerun broad local or Docker gates for this documentation-only wrapper.
The backend slice already passed its coherent local gate and exact Preview
rollout. Observe the backend publication workflows once, then run one root
validation and one Product Image Evidence workflow for the final candidate.
Investigate failures against that same commit instead of dispatching around
them.

## Acceptance

- root, backend, web, and recursive GMA references are clean and published;
- backend and root clean-checkout validation pass for their exact commits;
- one retained image bundle is scan-clean, checksum-closed, and attested;
- the exact retained backend and web archives run together successfully in a
  disposable candidate rehearsal; and
- documentation clearly separates local/Preview proof from hosted-production
  and company authorization.

## Deferred

- authenticating to or selecting the approved hosted registry;
- immutable registry promotion and deployment;
- hosted migration apply, rollback, edge, Admin, backup/restore, and key
  continuity proof;
- private release approval, legal decisions, and authorization for real guest
  data.
