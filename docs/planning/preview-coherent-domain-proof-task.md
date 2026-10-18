# Preview Coherent Domain Proof Task

Status: completed
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

## Outcome

- The first diagnostic run exposed a stale synthetic room-retirement request;
  cleanup now supplies explicit confirmation and the fixture rejects an invalid
  confirmation body (`a24165b`).
- The next diagnostic run exposed duplicate Properties processing activation
  when Reservations/Inventory and AdapterHost were selected together. The
  umbrella now owns one shared activation and guards against duplicate calls
  (`fe565f2`).
- The trusted-HTTPS rehearsal passed 14 checks against release
  `preview-coherent-fe565f2`. Retention passed 7 checks, invitation 8, QR
  enrollment 9, Operations Notifications 10, Reservations/Inventory 11, and
  both AdapterHost upsert and cancellation records passed 8 checks.
- AdapterHost used backend source commit
  `c8d8b35e0b990e530f744b6016742a659e8ce704` and exact local image digest
  `sha256:385009586303fa71cd79e11f1a9a2027de25214c5adb9914322d64b3057bf1cf`.
- The retained umbrella is
  `.tmp/deployment-probes/preview-coherent-fe565f2.json`, SHA-256
  `8da92ce378d39daebf3d8fdb7c894ed08468bb500979bff8c136e6391a72e949`.
  Its seven child hashes match, all eight records are operator-only, and no
  secret-like keys or email addresses were retained.
- Final cleanup removed both non-owner memberships, retired all three room
  fixtures and both properties, archived the workspace, revoked every session,
  removed the AdapterHost container and volumes, and left Mailpit unpublished
  and empty. The Worker remains on the backend network only.
- The first failed diagnostic archived its synthetic workspace and revoked its
  sessions, but could not retire one room-backed property after the stale
  request failed. That quarantined record is not admission evidence and remains
  subject to the normal archived-tenant lifecycle; no direct data-store repair
  was used.

## Deferred

- Hosted image promotion and deployed rollback rehearsal for a retained
  candidate/rollback pair.
- Production migration approval, hosted recovery, alert ownership, traffic
  handling, runtime supervision, credential rotation, and private sign-off.
- Real OTA, mailbox, or web-parser provider evidence.
