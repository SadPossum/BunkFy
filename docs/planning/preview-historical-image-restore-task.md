# Preview Historical Image Restore Task

Status: implemented and verified
Date: 2026-08-11

## Goal

Restore and rehearse a historical Preview backup with its exact product image
bytes without repointing image tags used by the live Preview deployment.

## Finding

The restore guard correctly binds backend and web bytes to image IDs recorded
in the backup. However, Compose selected only the shared
`bunkfy/backend:preview` and `bunkfy/web:preview` tags. Once those tags moved to
a newer candidate, an operator had to repoint them temporarily before an older
backup could reach its compatibility checks. That creates avoidable restart
and operator-error risk on a recovery host.

## Boundary

- Keep backup-recorded immutable image IDs authoritative.
- Let explicit local references locate the same bytes; never treat a tag as
  proof by itself.
- Apply one backend selection to API, Worker, migrations, Admin API, and CLI.
- Preserve current default tags for ordinary Preview startup.
- Keep this in product deployment composition; no module or GMA changes.

## Delivery

- [x] Add explicit backend and web image selectors to Preview Compose.
- [x] Let restore and recovery rehearsal accept historical local references.
- [x] Reject malformed references and byte mismatches before target creation.
- [x] Document no-build and historical recovery use.
- [x] Run focused operations verification.
- [x] Prove an old backup reaches compatibility checks without live-tag changes.
- [x] Run one consolidated end-of-slice gate.
- [x] Commit and push the root slice.

## Verification Evidence

- `eng/verify-operations.ps1` passed all Compose, recovery, deployment probe,
  rollback, and production-admission fixtures.
- Backup `f527957e-49a2-4579-bcca-0b6c6463e692` restored with separate
  `preview-pre-6fcbcc0` backend and web references while the live Preview tags
  retained their current image IDs. The old target reached the public-edge
  compatibility check and was correctly rejected because its web image
  predates the required release header; the disposable target was removed.
- Selecting those old bytes for the current backup failed on the backend image
  ID mismatch before Compose target inspection or creation.
- `eng/verify.ps1 -SkipRestore` passed the complete non-Docker gate: root and
  operations guards, a zero-warning build, every migration drift check, all
  GMA and BunkFy non-Docker tests, 102 architecture tests, 60 integration
  tests, and 267 web tests across 52 files plus lint, typecheck, OpenAPI
  contract drift, and the production build.

## Done When

- a historical restore never requires mutating live Preview image tags;
- all backend hosts in one restored target use one selected backend image;
- selected bytes must exactly match the backup manifest; and
- defaults, no-build startup, backup, restore, and recovery remain guarded.
