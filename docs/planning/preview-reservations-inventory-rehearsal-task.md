# Preview Reservations And Inventory Rehearsal Task

Status: complete
Date: 2026-08-11

## Goal

Add a self-contained Preview contribution that proves the deployed direct
Reservation lifecycle and Inventory allocation contract against one exact
release. The contribution must reuse the Preview onboarding workspace and
owner, create only synthetic topology and stay data, and clean the temporary
room through BunkFy's public coordinated-retirement workflow.

## Ownership

- Reservations owns reservation lifecycle state and idempotent mutation
  receipts.
- Inventory owns sellable units, allocation, availability, and coordinated
  topology retirement.
- Properties owns the physical room topology.
- The root deployment tooling may compose public contracts into a reversible
  smoke fixture and retain scrubbed evidence.
- Preview deployment owns mounting and digest-pinning its explicitly synthetic
  engineering policy pack. Properties remains the only owner of activation and
  binding state.
- GMA remains unchanged. This is BunkFy deployment orchestration, not reusable
  framework behavior.

The rehearsal must not read module databases, outbox or inbox tables, NATS,
Redis, or internal services. It must not introduce a second Reservation or
Inventory implementation.

## Slice

- Generalize the existing temporary sellable-room Preview fixture so more than
  one deployed product probe can use it without notification-specific naming.
- Add `-IncludeReservationsInventory` to the Preview onboarding rehearsal.
- Mount one v2 engineering/example policy read-only into Preview API and Worker,
  and pin the exact allowlist digest in Compose.
- Discover and activate that policy through the public Properties endpoints,
  then verify the effective binding before reservation work begins.
- Provision one private-room sellable unit through Properties and Inventory
  public APIs.
- Run the existing deployed Reservations and Inventory verifier with the
  synthetic owner and a bounded future range.
- Bind the child evidence file into the onboarding umbrella by SHA-256.
- Retire the temporary room even when the child proof fails, and make partial
  cleanup fail the umbrella.
- Preserve the existing Operations Notifications contribution and evidence
  shape.

## Evidence Boundary

The child proof may retain check names, release identity, result, transport,
and documented limitations. It must not retain workspace, property, room,
inventory, reservation, allocation, membership, subject, token, guest-label,
or stay-date values.

The passing Preview proof is API-level loopback evidence. It does not claim a
browser workflow, real guest data, hosted production, concurrent overbooking
contention, external delivery, legal review, or production country approval.

## Verification

- Focused sellable-room fixture tests pass.
- Focused property-processing fixture tests reject ambiguous or non-engineering
  policies and verify the exact activation binding.
- The deployed Reservations and Inventory fixture still passes 11 checks and
  rejects replay drift.
- Static operations guards cover the opt-in switch, child proof, evidence
  binding, and coordinated cleanup.
- One exact Preview onboarding rehearsal passes invitation, enrollment, and
  Reservations/Inventory child checks with complete cleanup.
- The consolidated operations, security, submodule, and diff gates pass once
  at the end of the slice.

## Completion Evidence

Local Preview evidence from 2026-08-11:

- exact release: `preview-0701bc3`;
- umbrella evidence:
  `.tmp/deployment-probes/preview-onboarding-20260811T020643Z.json`;
- Reservations/Inventory child evidence:
  `.tmp/deployment-probes/preview-onboarding-20260811T020643Z.reservations-inventory.json`;
- all 11 umbrella checks and all 11 child checks passed;
- the umbrella-recorded child digest matched the evidence file;
- the child retained no scoped identifiers or stay values;
- cleanup retired the temporary room and both properties, removed both
  non-owner memberships, archived the workspace, revoked all synthetic
  sessions, and purged the private mail capture;
- runtime review found only deliberate negative-path HTTP warnings and no
  unhandled, rate-limit, inbox, outbox, or messaging failure.

This is local loopback Preview evidence for the exact deployed candidate. It
is not hosted-production, legal approval, production country-policy, browser,
external-email-delivery, or concurrent-overbooking evidence.
