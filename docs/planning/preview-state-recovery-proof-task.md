# Preview State Recovery Proof Task

Status: planned
Date: 2026-08-12

## Goal

Refresh Preview recovery evidence after the deployed onboarding, Operations
Notifications, Reservations/Inventory, and connection-scoped AdapterHost
rehearsals. Prove that the current committed topology can back up its complete
declared state and restore it into an isolated target without disturbing the
running Preview deployment.

## Finding

The existing schema-5 backup and isolated recovery evidence passed before the
latest root deployment changes and domain rehearsals. Those records remain
valid for the bytes they observed, but they do not prove recovery from the
current committed root or its newer retained audit state.

## Boundary

- This is product deployment and recovery evidence, not a business-domain or
  GMA change.
- Use the tracked backup and isolated-recovery commands without bypassing
  manifest, image, permission, or state-contract checks.
- Keep the live Preview deployment available again after the brief backup
  quiescence, and remove the isolated target and all of its volumes.
- Record minimized evidence and exact digests. Do not commit backup contents,
  key material, identities, secrets, or raw state.
- Passing Preview evidence does not prove hosted storage durability, KMS,
  provider-native restore, RPO/RTO, or independent recovery access.

## Delivery

- [ ] Create a schema-5 backup from a clean, exact root/backend/web graph.
- [ ] Verify the source Preview stack returns healthy after backup.
- [ ] Restore the backup into a disposable isolated Compose project.
- [ ] Pass public-edge and loopback Admin-boundary checks on the restored target.
- [ ] Prove exact non-empty Data Protection key-tree continuity.
- [ ] Remove every isolated container, network, and volume.
- [ ] Retain the minimized rehearsal record and document its evidence boundary.

## Done When

The current committed Preview state has one digest-bound backup, one passing
five-check isolated recovery record, a healthy source deployment, and no
remaining rehearsal resources. Hosted recovery remains an explicit private
deployment gate.
