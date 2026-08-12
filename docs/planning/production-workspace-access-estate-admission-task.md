# Production Workspace Access Estate Admission Task

Status: in progress
Date: 2026-08-12

## Goal

Make the final BunkFy production-admission bundle require an explicit private
record proving that every active workspace in the hosted deployment is
converged on the candidate's current Workspace Access seed contract.

## Finding

The exact-release Preview estate rehearsal now proves BunkFy's public
status/bootstrap contracts and deployment operator against all active Preview
workspaces. Its evidence correctly declares `preview-deployment-only`; it must
not be presented as hosted production proof.

The production-admission bundle currently requires private records for browser
onboarding, recovery, deployment control, and runtime operations, but it does
not require the hosted Workspace Access estate decision. A candidate could
therefore reach private approval without an explicit record that existing
workspaces have current protected profiles and no legacy compatibility grants.

## Ownership

- GMA Access Control and Organizations keep generic profile, assignment,
  membership, and authorized catalog contracts. GMA remains unchanged.
- BunkFy Workspaces owns seed version, protected definitions, drift detection,
  legacy-member migration, and tenant-scoped bootstrap semantics.
- The BunkFy root owns final release-evidence composition and requires a
  distinct bounded reference to the private estate record.
- Hosted deployment operations own exact-release Admin execution, complete
  active-workspace enumeration, approval, topology, credentials, evidence
  authenticity, and retention of the private record.

## Private Record Contract

The referenced record must bind:

- the exact candidate release and backend artifact identity;
- the authorized catalog source, bounded enumeration, total and active counts,
  and a stable catalog fingerprint;
- the expected BunkFy seed version and protected-profile count;
- before/after aggregate status for every active workspace, retaining tenant
  identity only as an approved one-way fingerprint;
- zero missing, archived, or drifted protected seeds, zero legacy members, and
  `requiresBackfill=false` for every final status;
- explicit mutation approval and outcome when any bootstrap was required;
- operator identity, timestamps, partial-failure disposition, and independent
  review or approval according to the private release process.

The public repository validates only a bounded, non-secret reference. It does
not claim to inspect or authenticate the private record.

## Delivery

1. Add a mandatory `WorkspaceAccessEstateReference` to production admission
   assembly and retain it under a dedicated private control key.
2. Require all five private references to be distinct and preserve the closed,
   sorted output contract.
3. Extend deterministic fixtures for the new control, omission, duplication,
   and minimized admission output.
4. Update the production-admission runbook and Workspace Access evidence notes.

## Verification Cadence

Use the focused production-admission fixture while editing. Run the complete
operations gate once when the slice is coherent. This slice changes no runtime,
database, broker, or container behavior, so no Docker rerun is required.

## Deferred

- The first real hosted estate execution and private approval record.
- A fleet orchestrator for multiple production deployments.
- Importing private record contents into the public admission bundle.
- Global retirement of the legacy role definition before every production
  deployment has its own accepted estate record.
