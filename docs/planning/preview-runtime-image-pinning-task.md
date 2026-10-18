# Preview Runtime Image Pinning Task

Status: implemented and verified
Date: 2026-08-11

## Goal

Make Preview startup, backup, restore, recovery rehearsal, and Production
migration rehearsal deterministic with respect to repository-owned container
image selection.

## Finding

BunkFy product images and Dockerfile base images are digest-bound, and Mailpit
is digest-pinned, but PostgreSQL, Redis, NATS, MinIO, and the Alpine recovery
helper still resolved mutable tags. Evidence recorded the bytes that ran, yet a
later operation could select different bytes without a repository change.

## Boundary

- This is product deployment composition, not a business module or GMA concern.
- Keep readable version tags while binding each runtime image to one reviewed
  multi-platform manifest digest.
- Centralize the archive utility image used by backup, restore, and recovery.
- Guard every pin and document an explicit dependency-upgrade procedure.
- Do not claim registry policy, hosted recovery, or production deployment proof.

## Delivery

- [x] Pin Preview PostgreSQL, Redis, NATS, and MinIO images.
- [x] Centralize and pin the backup/restore Alpine utility image.
- [x] Pin the default PostgreSQL migration-rehearsal image.
- [x] Add repository guards and upgrade guidance.
- [x] Run focused operations verification.
- [x] Run one consolidated end-of-slice verification gate.
- [x] Run a fresh backup and isolated recovery rehearsal with the pinned bytes.
- [x] Commit and push the final evidence note.

## Verification Evidence

- `eng/verify-operations.ps1` passed every syntax, Compose, recovery,
  deployment-probe, rollback, and production-admission fixture.
- Each pinned reference resolved to the already retained local image bytes.
- `eng/verify.ps1 -SkipRestore` passed solution and submodule guards, a
  zero-warning build, every migration drift check, all non-Docker backend and
  GMA tests, 60 integration tests, 267 web tests, lint, typecheck, and the
  production web build.
- Docker integration and hosted CI were intentionally not used as iterative
  verification.
- A schema-4 backup created at
  `/home/artem/deployments/bunkfy-backups/preview-runtime-pins-20260811T173845Z`
  brought the live Preview composition back healthy with the pinned runtime
  references. Its manifest SHA-256 is
  `37caad3b86884c6140b7f0b69dad0c79b30f87a3b325f33df359c1ef580c03a2`.
- The isolated recovery rehearsal passed all five restore, public-edge, Admin
  boundary, state-tree, and Data Protection key-continuity checks. Minimized
  evidence is retained under ignored `.tmp/recovery-rehearsals`.
- The earlier pre-candidate backup was correctly rejected by the current edge
  probe because its web image predates the required release header. It was not
  counted as passing evidence, and its disposable target was removed.

## Done When

- every third-party image selected by the tracked Preview topology is
  tag-and-digest pinned;
- recovery helpers cannot drift independently between backup and restore;
- the migration rehearsal default matches Preview PostgreSQL bytes; and
- an intentional upgrade requires a reviewed source change and recovery proof.
