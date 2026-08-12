# Preview State Recovery Proof Task

Status: completed for Preview recovery mechanics
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

- [x] Create a schema-5 backup from a clean, exact root/backend/web graph.
- [x] Verify the source Preview stack returns healthy after backup.
- [x] Restore the backup into a disposable isolated Compose project.
- [x] Pass public-edge and loopback Admin-boundary checks on the restored target.
- [x] Prove exact non-empty Data Protection key-tree continuity.
- [x] Remove every isolated container, network, and volume.
- [x] Retain the minimized rehearsal record and document its evidence boundary.

## Verification Evidence

- Backup `171f4eb6-0b43-47b6-bc94-25fa974b7afb` is schema 5 with state
  contract `bunkfy-preview-state` version 2. It binds root `6bb0c6e`, backend
  `a269085`, web `2583e28`, the running backend/web image IDs, and eight
  declared state artifacts.
- The protected backup is retained outside the repository at
  `/home/artem/deployments/bunkfy-backups/preview-post-domain-20260812T004145Z`.
  Its manifest SHA-256 is
  `c4d81aa04434aca10d900dbc1be0b8bb1f0f028423fe957f01c8bd3ac08ee153`.
- Isolated rehearsal `761fb510-a52b-4a8a-b26b-05f9aefb588f` passed all five
  checks in 64,926 ms. Minimized local evidence is
  `.tmp/recovery-rehearsals/preview-761fb510a52b4a8ab26b05f9aefb588f.json`,
  SHA-256
  `f3c823cd829412e0fb06536f8d1ecd0cfa77c3116da018b0cc813f4c5a33ee5f`.
- The restored Data Protection tree contained one file and 1,001 bytes and
  matched the archived tree exactly. The evidence does not retain its path or
  content hash.
- No rehearsal container, volume, or network remained. The source API, web,
  worker, PostgreSQL, Redis, NATS, MinIO, and Mailpit services returned to their
  running state; public capabilities returned HTTP `200`.
- This does not exercise authenticator decryption, an external Admin denial
  vantage, secret-store recovery, hosted storage, or hosted RPO/RTO.

## Done When

The current committed Preview state has one digest-bound backup, one passing
five-check isolated recovery record, a healthy source deployment, and no
remaining rehearsal resources. Hosted recovery remains an explicit private
deployment gate.
