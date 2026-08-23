# Deployed Staff Employment Lifecycle Proof Task

Status: complete
Date: 2026-08-13

## Goal

Add one bounded exact-release deployment proof for the Staff-owned employment
lifecycle: create an unlinked staff profile, update it versionedly, assign it to
one property, suspend and resume it, then record departure and prove that the
current property assignment closes atomically.

## Finding

The repository has focused Staff domain, application, API, PostgreSQL, messaging,
and worker coverage. The deployed invitation and enrollment proofs already cover
workspace membership, account registration, access grants, and linked Staff
onboarding. Production admission does not yet require evidence for the separate
manual employment-profile and assignment lifecycle against one deployed release.

## Ownership

- BunkFy Staff owns employment profiles, optimistic versions, property
  assignments, lifecycle state, mutation idempotency, and immutable receipts.
- Workspaces and Organizations own workspace identity and membership. Access
  Control owns roles, grants, and effective authorization. Auth owns subjects,
  credentials, and sessions.
- Properties owns the property existence projection consumed by Staff; Staff
  does not write Properties data or retain a cross-schema foreign key.
- The root operations layer owns exact-release orchestration, minimized
  evidence, Preview composition, cleanup accounting, and production-admission
  policy.
- GMA already provides the generic tenant, authorization, result, task,
  messaging, outbox/inbox, and time boundaries. No GMA change is planned.

## Proof Contract

The deployed verifier will:

1. Bind an active operator and one active property to the expected release.
2. Prove an authenticated nonmember cannot read the workspace Staff directory.
3. Create one synthetic, unlinked Staff profile with no legal name, email,
   phone, employee number, or other real personal data.
4. Prove exact create replay is stable and conflicting operation reuse is
   rejected.
5. Prove active directory, directory-safe detail, and sensitive-profile detail
   agree on identity, status, version, and the absence of an auth-subject link.
6. Update the synthetic display label with an expected version, prove exact
   replay is stable, and prove conflicting operation reuse and a stale write fail
   closed.
7. Assign the Staff member to the selected property on the current UTC date,
   prove exact replay is stable, and prove conflicting operation reuse is
   rejected.
8. Prove the canonical detail and property directory expose exactly one current,
   primary assignment.
9. Suspend the Staff member and prove the assignment remains current; resume the
   member and prove activity returns. Each transition must have stable exact
   replay.
10. Record immediate departure, prove stable exact replay, and prove the Staff
    member is terminal while every current assignment is closed and the property
    current directory no longer includes it.
11. Prove active and departed status filters distinguish the terminal record,
    then recheck release identity.

## Evidence Boundary

The evidence kind will be `bunkfy-deployed-staff-employment-probe`, schema
version 1. It may retain release and transport identity, aggregate status and
version relationships, assignment counts, cleanup disposition, named checks,
and fixed limitations.

It must not retain credentials, subject IDs, workspace, property, Staff, or
operation IDs, display labels, legal names, email addresses, phone numbers,
employee numbers, free-form reasons, effective dates, or response bodies. Files
are written atomically with private permissions and cannot overwrite an existing
result without explicit `-Force` approval.

## Preview Composition

`rehearse-preview-onboarding.ps1` will expose an opt-in Staff employment switch.
The parent will pass one active property plus owner and invitation-applicant
tokens to the child before invitation acceptance, so the applicant remains an
authenticated nonmember for the denial check. The child is authoritative for
departing its synthetic Staff record; the parent remains authoritative for
retiring the property and surrounding workspace.

The assignment call may observe the bounded interval before the Staff-owned
Properties projection converges. The verifier may retry only the exact operation
after `Staff.PropertyUnavailable`; any other response fails closed.

## Delivery

1. Add the deployed verifier and deterministic fixture test.
2. Add opt-in Preview onboarding composition and cleanup accounting.
3. Add the closed evidence specification to production admission and require its
   exact-release source evidence.
4. Wire static guards, focused fixtures, documentation, and the operations gate.
5. Run one complete operations gate and one exact-release Preview rehearsal only
   after the slice is coherent.

## Verification Cadence

Use focused script fixtures while editing. Do not run Docker suites for root-only
operations changes. Run the complete operations gate once at the slice boundary;
the final exact-release Preview rehearsal is the integration proof across the
edge, API, Worker, PostgreSQL, NATS, and module-owned databases.

## Deferred

- Auth-subject linking, role grants, session revocation, and membership
  offboarding, which remain covered by invitation/enrollment/access workflows.
- Browser Staff management and actor-specific UX.
- Employment governance, processing restriction, data holds, anonymisation, and
  retention, which have separate policy and Data Rights boundaries.
- Concurrent Staff lifecycle writers and large-directory performance rehearsal.
- The first hosted-production execution and private approval decision.
- Generalizing BunkFy-specific employment orchestration into GMA without another
  demonstrated project use case.

## Acceptance

- The focused verifier and admission fixtures pass.
- The complete operations gate passes once for the finished slice.
- An exact candidate Preview run produces passing minimized evidence and leaves
  its synthetic Staff record departed with no current assignment.
- Production admission requires the new exact-release evidence while refusing to
  present loopback Preview evidence as hosted-production proof.

## Outcome

Implemented the 21-check deployed Staff verifier, its deterministic valid and
replay-drift fixture, opt-in Preview composition, terminal cleanup accounting,
and the closed production-admission evidence specification. Focused Staff and
admission fixtures passed, followed by the complete root operations gate.

Exact-release Preview verification passed on 2026-08-13 for
`preview-workspace-access-estate-651107f`. The Staff child finished departed
with one closed historical assignment and zero current assignments; its
minimized SHA-256 is
`1ddecd9a9e699855c554b7d72813dd4a8208aa0ee0dacfe3762f08954485c54a`.
The enclosing 10-check onboarding rehearsal completed cleanup with SHA-256
`fd776514b5d593b37609ccb33dc88f23471406aac8f7ee21b26f2ea29bb44a11`.
This remains loopback Preview evidence, not hosted-production approval.
