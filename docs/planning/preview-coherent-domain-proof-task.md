# Preview Coherent Domain Proof Task

Status: in progress
Date: 2026-08-12

## Goal

Retain one trusted-HTTPS Preview rehearsal in which workspace invitation, QR
enrollment, Operations Notifications, Reservations and Inventory, Retention,
and AdapterHost all prove the same exact release and synthetic workspace.

## Finding

Each deployed domain proof has passed independently, but the retained records
span several release ids. The new Retention record also used explicit loopback
fixture transport. Production admission correctly refuses to combine those
records as one candidate evidence set.

## Boundary

- This is deployment evidence composition, not a business-domain or GMA change.
- Use the existing public contracts and optional onboarding contributors; do
  not seed a database, invoke Admin repair, or bypass module ownership.
- Use the trusted public HTTPS origin and the current exact local backend image
  digest for the transient AdapterHost.
- This remains Preview engineering evidence. It does not prove hosted registry
  promotion, a compatible rollback image, private approvals, real-provider
  traffic, or final Production admission.

## Invariants

1. Every child reports the same release id and public HTTPS origin.
2. Room-backed contributors use separate fixtures and clean them through their
   public lifecycle contracts.
3. Retention binds first occurrences to a timestamp captured before workspace
   creation and remains read-only.
4. AdapterHost starts from an exact digest, exposes health only on loopback,
   keeps status disabled, and removes its container, volumes, credential, and
   connection state after upsert and cancellation proofs.
5. Parent and child evidence is scrubbed, checksum-bound, and operator-only.
6. Every synthetic membership, property, workspace, and session cleanup result
   must pass; Mailpit must finish unpublished and empty.

## Delivery

- Stamp Preview with the task checkpoint release id without rebuilding
  unchanged runtime images.
- Run one umbrella rehearsal with all four optional contributors over trusted
  HTTPS.
- Verify child transports, release/workspace binding, checksums, private file
  modes, cleanup, Mailpit state, and residual Docker topology.
- Retain the evidence boundary and record concrete outcomes before closure.

## Deferred

- Hosted image promotion and deployed rollback rehearsal for a retained
  candidate/rollback pair.
- Production migration approval, hosted recovery, alert ownership, traffic
  handling, runtime supervision, credential rotation, and private sign-off.
- Real OTA, mailbox, or web-parser provider evidence.
