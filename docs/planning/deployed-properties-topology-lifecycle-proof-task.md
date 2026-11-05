# Deployed Properties Topology Lifecycle Proof Task

Status: implemented, fixture verified, operations-gate verified, and exact-release Preview verified
Date: 2026-08-13

## Goal

Add one bounded exact-release deployment proof for the Properties-owned physical
topology lifecycle: create and versionedly update one synthetic property and
room, atomically add and update beds, retire topology through Inventory's safety
coordinator, and retire the empty property.

## Finding

Properties has focused domain, application, API, PostgreSQL, messaging, worker,
and projection coverage. Existing Preview rehearsals create and retire
properties and rooms as supporting fixtures, but production admission has no
standalone evidence for Properties mutation idempotency, optimistic concurrency,
topology visibility, the Inventory retirement boundary, or terminal property
state against one exact deployed release.

## Ownership

- Properties owns property, room, and bed identity, facility details, topology
  status, optimistic versions, mutation journals, and immutable receipts.
- Inventory owns sellability, allocations, manual blocks, and the safe drain and
  finalization workflow for room and bed retirement. Properties must continue to
  reject direct retirement commands outside that coordinator.
- Workspaces owns workspace lifecycle and mutation admission. Access Control owns
  permissions and scope evaluation. Auth owns subjects, credentials, sessions,
  and configured assurance.
- The root operations layer owns synthetic orchestration, exact-release binding,
  bounded convergence, cleanup accounting, minimized evidence, Preview
  composition, and production-admission policy.
- GMA already supplies the reusable tenancy, authorization, CQRS/result,
  messaging, outbox/inbox, task, idempotency-supporting, and time boundaries. No
  GMA change is planned.

## Proof Contract

The deployed verifier will:

1. Bind one active workspace operator to the expected release and prove a
   distinct authenticated nonmember cannot read the property directory.
2. Create one synthetic property using its operation id as identity, prove exact
   replay stability, and reject conflicting operation reuse.
3. Prove property detail and paged directory visibility, then update details
   with optimistic concurrency, stable replay, conflicting reuse rejection, and
   stale-version rejection.
4. Create one room, prove stable replay and conflicting reuse rejection, then
   update it with the same optimistic and idempotent guarantees.
5. Add exactly two beds in one atomic batch, prove stable replay and conflicting
   reuse rejection, and verify the room-owned bed directory.
6. Update one bed with optimistic concurrency, stable replay, conflicting reuse
   rejection, and stale-version rejection.
7. Prove the active room blocks property retirement and that direct room and bed
   retirement routes fail closed with the explicit Inventory-coordination
   requirement.
8. Request one bed retirement through Inventory, prove exact request replay is
   stable, wait for completion, and verify the Properties bed is retired.
9. Request room retirement through Inventory, prove exact request replay is
   stable, wait for completion, and verify the room plus both beds are retired.
10. Retire the empty property with optimistic and idempotent lifecycle semantics,
    reject conflicting operation reuse, and prove its processing state is
    effectively suspended after retirement.
11. Recheck the retired topology through detail and paged directories and prove
    release identity continuity.

Only projection absence or an in-progress retirement state may be treated as
bounded convergence. Business conflicts, rejected retirement, changed replay,
and stale versions fail immediately.

## Evidence Boundary

The evidence kind will be `bunkfy-deployed-properties-topology-probe`, schema
version 1. It may retain release and transport identity, aggregate version and
status relationships, bounded topology counts, retirement completion facts,
cleanup disposition, named checks, and fixed limitations.

It must not retain credentials, subject, workspace, property, room, bed,
topology-change, or operation identifiers; property names or codes; room,
building, floor, or bed labels; reasons; time-zone or country-policy values;
timestamps beyond evidence generation; or response bodies. Files are written
atomically with private permissions and cannot overwrite an existing result
without explicit `-Force` approval.

## Preview Composition

`rehearse-preview-onboarding.ps1` will expose an opt-in Properties topology
switch. The child will run before invitation acceptance so the applicant remains
an authenticated nonmember. It will create and fully retire its own property and
topology; the parent remains responsible only for its two onboarding properties
and surrounding workspace.

The owner session is freshly authenticated because Inventory topology retirement
and property retirement may require recent-sign-in assurance. An independently
prepared deployment must supply an operator token satisfying the host's
configured assurance.

## Governance Boundary

This proof will not activate or rebind a country policy. Production policy
selection requires approved country, region, transfer, retention, and
acknowledgement evidence outside a synthetic topology test. Existing Preview
engineering/example policy activation remains composition evidence for the
contributors that need processing, not production approval.

## Delivery

1. Add the deployed verifier and deterministic valid plus replay-drift fixture.
2. Add opt-in Preview onboarding composition with child-authoritative topology
   cleanup.
3. Add the closed evidence specification to production admission and require
   its exact-release source evidence.
4. Wire static guards, focused fixtures, documentation, and the operations gate.
5. Run one complete operations gate and one exact-release Preview rehearsal only
   after the slice is coherent.

## Verification Cadence

Use focused script fixtures while editing. Do not run Docker suites for root-only
operations changes. Run the complete operations gate once at the slice boundary;
the final exact-release Preview rehearsal is the integration proof across the
edge, API, Worker, PostgreSQL, NATS, Properties, and Inventory-owned databases.

## Deferred

- browser Properties management and actor-specific recovery UX;
- approved production country-policy activation, suspension, and rebinding;
- occupied or manually blocked topology drain and affected-reservation review;
- high-contention mutation and large-directory performance rehearsal;
- tenant termination export/destruction, which has a separate owner protocol;
- hosted-production execution and private approval; and
- generalizing BunkFy-specific topology orchestration into GMA without another
  demonstrated project use case.

## Acceptance

- The focused verifier and admission fixtures pass.
- The complete operations gate passes once for the finished slice.
- An exact candidate Preview run produces passing minimized evidence and leaves
  the synthetic property, room, and both beds retired with no active topology.
- Production admission requires the new exact-release evidence while refusing to
  present loopback Preview evidence as hosted-production proof.

## Completion

Implemented the 31-check deployed Properties verifier, deterministic valid and
room-retirement replay-drift fixture, Preview opt-in composition, production
admission specification and semantic validation, static guards, and operator
documentation. No BunkFy module or GMA runtime source changed: source review and
the deployed proof confirmed that the existing Properties and Inventory public
contracts already preserve the intended ownership boundary.

The focused verifier and admission fixtures passed. One exact Preview rehearsal
passed for `preview-workspace-access-estate-651107f`; child SHA-256 is
`d83da9843778138fdef851a52e99583455b230f7971190cf95e30c8ba7241b45`
and umbrella SHA-256 is
`38b16660bfa54c03caee7dca1dd2b20cab04332a98fba954ce6ecadcf734dceb`.
All retained files use mode `0600`, the minimization scan was clean, the
production-admission parser accepted the child, and the full operations gate
passed once in 189.3 seconds.
