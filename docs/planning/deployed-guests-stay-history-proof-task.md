# Deployed Guests Stay History Proof Task

Status: implemented, repository verified, and exact-release Preview verified
Date: 2026-08-13

## Goal

Add one bounded exact-release deployment proof for the smallest complete durable
Guest workflow: create and manage a canonical Guest, link it to a Reservation,
observe the Guests-owned stay-history projection through check-in and check-out,
and archive the Guest after the stay reaches a terminal state.

## Finding

The repository has focused module tests and a real PostgreSQL, NATS, API, and
Worker saga test for Guest management, Reservation participant links, and
monotonic stay-history projection. Production admission does not yet require
evidence that those public contracts work together in a deployed candidate.

The existing deployed Reservations and Inventory proof deliberately uses only a
booking snapshot and records `durable-guest-record-not-created` as a limitation.
This proof closes that separate boundary without folding Guest ownership into
Reservations or duplicating module data.

## Ownership

- BunkFy Guests owns the canonical profile, management idempotency, archive
  state, and its rebuildable stay-history projection.
- BunkFy Reservations owns the booking participant link, Reservation lifecycle,
  and integration events consumed by Guests.
- BunkFy Inventory owns allocation and release of the synthetic sellable unit.
- The root operations layer owns exact-release orchestration, minimized
  evidence, Preview fixture composition, and production-admission policy.
- GMA already supplies the generic tenancy, access policy, messaging,
  outbox/inbox, task, and API-result boundaries. No GMA change is planned.

## Proof Contract

The deployed verifier will:

1. Bind an active operator, one property, and one available Inventory unit to
   the expected release.
2. Prove a nonmember cannot read the property's Guest directory.
3. Create one synthetic Guest with no email, phone, legal name, date of birth,
   nationality, notes, or other real personal data.
4. Prove exact create replay is stable and conflicting reuse of the creation
   operation ID is rejected.
5. Prove the active directory and detail surface expose the exact created Guest.
6. Update the display label with an expected version, prove exact replay is
   stable, and prove conflicting operation reuse and stale writes fail closed.
7. Create and allocate one synthetic Reservation, link the Guest as its primary
   participant through the Reservations public contract, and prove exact link
   replay is stable.
8. Poll boundedly until the Guests-owned stay projection observes Confirmed,
   CheckedIn, and CheckedOut states with matching dates and monotonic Reservation
   versions.
9. Prove the terminal Reservation still references the Guest and its Inventory
   allocation is released.
10. Archive the Guest, prove exact archive replay is stable, and prove the Guest
    leaves the active directory while remaining explicitly queryable as an
    archived operational record with its stay history.
11. Recheck release identity and emit only bounded, non-identifying evidence.

## Evidence Boundary

The evidence kind will be `bunkfy-deployed-guests-stay-history-probe`, schema
version 1. It may retain release, origin, transport, aggregate workflow states,
counts, version relationships, cleanup disposition, checks, and fixed
limitations.

It must not retain credentials, refresh tokens, names, email addresses, phone
numbers, free-form notes, dates of birth, nationality, workspace, property,
Inventory, Guest, or Reservation identifiers, or the synthetic stay dates.
Files are written atomically with private permissions and cannot overwrite an
existing result without explicit `-Force` approval.

## Preview Composition

`rehearse-preview-onboarding.ps1` will expose an opt-in Guests stay-history
switch. Before invitation acceptance, the parent will activate the synthetic
property policy once, create a dedicated sellable-room fixture, and pass the
owner and invitation-applicant tokens to the child as `SecureString` values.
The invitation applicant remains a nonmember for the denial check. The child is
authoritative for archiving its Guest and completing its Reservation; the parent
is authoritative for retiring the room and the surrounding workspace.

## Delivery

1. Add the deployed verifier and deterministic fixture test.
2. Add the opt-in Preview onboarding composition and cleanup accounting.
3. Add the closed evidence specification to production admission and require its
   exact-release source evidence.
4. Wire static guards, focused fixtures, documentation, and the operations gate.
5. Run one exact-release Preview rehearsal after the implementation is coherent
   and record that result separately from hosted-production evidence.

## Verification Cadence

Use the new verifier fixture and production-admission fixture while editing. Run
the complete operations gate once at the end of the coherent slice. Do not run
Docker suites for root-script iterations; the final exact-release Preview
rehearsal is the integration proof across API, Worker, PostgreSQL, NATS, and the
module-owned databases.

## Deferred

- Browser Guest creation and stay-history UX.
- Guest deduplication, merging, consent, document, and communication workflows.
- Concurrent participant replacement and concurrent overbooking contention.
- Immediate deletion of operational Guest and Reservation history; archive and
  retention policies remain the supported lifecycle.
- The first hosted-production execution and private approval decision.
- Generalizing BunkFy-specific workflow orchestration into GMA without another
  demonstrated project use case.

## Acceptance

- The focused verifier and admission fixtures pass.
- The complete operations gate passes once for the finished slice.
- An exact candidate Preview run produces passing minimized evidence.
- Production admission requires the new exact-release evidence but does not
  present Preview evidence as hosted-production proof.

## Outcome

- The complete root Operations gate passed, including the 19-check Guests
  fixture, Preview composition policy, and production-admission assembly.
- The repository-security gate passed without changing GMA source or pointers.
- The first live run exposed a pre-projection Inventory `404`. The shared
  sellable-room fixture now treats it as bounded convergence and waits for the
  same convergence during partial cleanup; its focused fixture passes.
- The failed synthetic estate was reconciled through the authorized Admin CLI
  and verified with an archived workspace and zero active properties or room
  topology.
- The replacement exact-release Preview run passed all 19 child checks and all
  11 parent checks for `preview-workspace-access-estate-651107f`. The child
  SHA-256 is
  `ddea07066941a2e54bc032028142dea2bb79baeb886cb073f1193504d142e18c`;
  the parent SHA-256 is
  `172a26c2ca37a0f374cdba8058c91ad286c75d3ea09ae9f3c1a523812a8ef0b9`.
- All retained files are private, the admission parser accepts the child only
  under its loopback fixture allowance, and hosted-production execution remains
  deferred.
