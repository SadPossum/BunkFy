# Deployed Reservations And Inventory Evidence Proof Task

Status: in progress
Date: 2026-08-13

## Goal

Bring the deployed direct Reservation and Inventory lifecycle proof up to the
current production-evidence standard without changing product runtime
behavior. The proof must cover tenant isolation, allocation convergence,
stable mutation replay, terminal release, and cleanup through public contracts
while retaining only release-safe facts.

## Finding

Reservations and Inventory already serialize aggregate and allocation
mutations, keep operation journals, coordinate allocation and release through
module contracts, and recover retirement cancellation without leaking product
policy into GMA. The deployed verifier exercises the core direct-stay happy
path, but its schema has no machine-checkable workflow or cleanup summary, does
not prove a cross-workspace denial, and labels real loopback Preview as a
fixture. Its last trusted-HTTPS evidence also belongs to an older release.

## Ownership

- Reservations owns booking state, direct-staff mutation replay, occupancy
  transitions, history, and the terminal Reservation record.
- Inventory owns availability, allocation, release, topology safety, and the
  authoritative selected-unit view.
- Properties owns physical topology; the Preview parent owns creation and
  retirement of its synthetic room fixture.
- The root operations layer owns deployed orchestration, scrubbed evidence,
  deterministic fixtures, Preview composition, and production-admission shape.
- GMA remains unchanged. Its generic CQRS, transaction, messaging, tenant,
  authorization, and idempotency primitives are already sufficient.

## Evidence Contract V2

The evidence kind remains
`bunkfy-deployed-reservations-inventory-probe`; schema version advances to 2.
The record may retain only:

- generated time, public origin, exact release, transport, and result;
- fixed direct-booking, allocation, occupancy, replay, and Guest Record facts;
- terminal Reservation and selected Inventory cleanup disposition;
- the twelve named checks and fixed limitations.

It must not retain workspace, property, room, inventory, allocation,
reservation, membership, subject, actor, operation, or Guest identifiers;
stay dates; credentials; labels; payloads; response bodies; or headers.
Evidence remains atomic, private, and non-overwriting by default.

Trusted HTTPS is the only production-admission transport. A real loopback run
is `loopback-http-preview`; the deterministic admission fixture remains
`loopback-http-fixture`. Preview composition must require an identifier-free
child and bind it only by SHA-256.

## Delivery

1. Add a cross-workspace Inventory-read denial before any mutation.
2. Emit closed workflow and cleanup summaries and advance the schema version.
3. Require the exact v2 shape and semantics in production admission.
4. Strengthen the deterministic fixture for exact shape, sensitive-value
   absence, private mode, overwrite refusal, release mismatch, replay drift,
   and insecure-origin rejection.
5. Align operations documentation and static guards.
6. Run focused fixtures while editing, then one complete Operations gate and
   one exact-release Preview rehearsal at the coherent boundary.

## Deferred

- browser Reservation workflow rendering;
- durable Guest Record creation, which has its own deployed lifecycle proof;
- concurrent overbooking load and contention measurement beyond existing
  PostgreSQL concurrency scenarios;
- direct staff date changes beyond the current explicit product policy;
- hosted trusted-HTTPS execution and private production approval; and
- framework extraction without another generic consumer requirement.

## Acceptance

- The v2 child contains no scoped identifiers, personal content, dates, or
  secret material and uses mode `0600` on Unix.
- The public path rejects an authenticated caller under an unrelated workspace
  scope before Reservation creation.
- Stable create, check-in, and checkout replay and terminal Inventory release
  remain proven against one exact release.
- Production admission accepts only the exact closed v2 trusted-HTTPS contract.
- Preview binds the scrubbed child by hash and completes room, workspace,
  membership, session, and mail cleanup.
- No backend, database, web, or GMA runtime change is introduced unless the
  deployed proof reveals a concrete defect.
