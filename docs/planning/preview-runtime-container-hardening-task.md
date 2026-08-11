# Preview Runtime Container Hardening Task

Status: completed
Date: 2026-08-11

## Goal

Reduce the persistence and host-impact available after compromise of a
first-party Preview process, and keep container logs bounded by the tracked
deployment contract instead of an unrecorded Docker daemon default.

## Finding

The backend and web images already declare non-root runtime users, and Preview
publishes only the web edge plus the opt-in loopback Admin surface. The
resolved Compose model nevertheless gives every first-party process a writable
root filesystem, the default Linux capability set, no explicit privilege-
escalation guard, and no PID ceiling. Log rotation currently happens only
because this VPS happens to use a bounded daemon-wide `local` logging driver;
the repository does not require that behavior.

The first isolated runtime proof also exposed an existing hidden write: without
an explicit Preview adapter setting, each process placed the Data Rights
tenant-termination replay journal under its own content-root `.data` directory.
That fallback was neither shared between API and Worker nor covered by Preview
backup/restore.

## Ownership

- The BunkFy root repository owns the composed Preview runtime restrictions,
  explicit logging policy, runbook, and executable operations guards.
- Backend and web repositories own their image users and writable application
  paths. Their current images already use `app` and `nginx` respectively, so
  no submodule change is required for this slice.
- GMA owns no container topology or BunkFy deployment policy and is unchanged.
- Production orchestration, managed-service identities, seccomp/AppArmor
  profiles, resource sizing, and host policy remain private deployment inputs.

## Boundary

- First-party API, Worker, migration, Admin API, Admin CLI, and web containers
  use read-only root filesystems, drop every Linux capability, deny privilege
  escalation, run under an init process, and have a bounded PID count.
- A one-shot replay-volume initializer is the narrow exception to the non-root,
  zero-capability runtime rule: it has no network or application environment,
  mounts only that volume, and retains only `CAP_CHOWN` before exiting.
- Only explicit state volumes and bounded temporary filesystems remain
  writable. The web entrypoint receives private writable mounts for generated
  Nginx configuration, cache, run state, and temporary files.
- The tenant-termination replay journal uses a shared dedicated state volume
  instead of a process-local writable image layer or the integrity-closed
  ledger-delta root.
- Backup schema 5/state contract 2 captures the replay volume while restore
  remains compatible with schema 2/3/4 backups that never captured it.
- Every Preview service declares bounded local Docker logs.
- Graceful-stop windows are explicit for first-party long-running processes so
  backup quiescence does not inherit a daemon or Compose default silently.
- Executable verification checks the resolved Compose model, not only YAML
  source text.

## Deliberate Deferrals

- Do not force numeric users onto PostgreSQL, Redis, NATS, MinIO, or Mailpit in
  this slice. Several upstream images initialize or drop privileges through
  their entrypoints, and changing ownership of existing state volumes requires
  a separately rehearsed migration.
- Do not invent CPU or memory ceilings without a measured workload baseline.
- Do not present Preview restrictions as a Kubernetes pod-security policy,
  managed-service control, host hardening, or production isolation proof.

## Delivery

- [x] Audit the resolved Compose model and running process identities.
- [x] Record the ownership and compatibility boundary.
- [x] Add reusable first-party runtime and bounded-logging declarations.
- [x] Add the required writable temporary filesystems.
- [x] Extend operations verification over the resolved Compose model.
- [x] Update the Preview runbook.
- [x] Give the tenant-termination replay journal an integrity-safe shared volume
  and a backward-compatible backup contract.
- [x] Make replay-volume ownership deterministic for current and historical
  backend images through a least-privilege one-shot initializer.
- [x] Prove fresh schema-4 and schema-5 isolated restores can start under the
  restrictions.
- [x] Apply the exact configuration to the live Preview and verify health.
- [x] Run one consolidated end-of-slice repository gate.
- [x] Commit and push the root slice.

## Local Proof

- Historical schema-4/state-contract-1 rehearsal
  `1019545b-2d19-4196-842d-2d04fc8b9895` passed all five checks while creating
  the newly introduced replay volume empty.
- Backup `1325a92a-4050-4f27-80f3-fc4fc2e649d8` emitted schema 5/state contract
  2 with `tenant-termination-replay.tar.gz`; rehearsal
  `506704a3-7561-4cc2-b5bc-c0f5a36d96d5` passed all five checks.
- Live release `preview-runtime-hardening-20260811` passed the six-check public
  edge probe. Runtime inspection confirmed the declared users, read-only roots,
  capability sets, PID limits, and bounded `local` logs; the initializer exited
  successfully before consumers started.
- `eng/verify.ps1 -SkipRestore` passed the operations fixtures, zero-warning
  builds, migration drift, all selected .NET tests, 102 architecture tests, 60
  integration tests, and 52 web files / 267 tests plus lint, typecheck, OpenAPI,
  and production build.

## Done When

- every first-party runtime resolves to the complete least-privilege policy;
- the replay-volume initializer is the only explicit root/capability exception
  and exits before any replay-store consumer starts;
- every service resolves to the bounded log policy;
- API, Worker, web, migration, Admin, backup, and restore paths retain only the
  writable locations they actually need;
- isolated recovery and live public health pass under the hardened model; and
- documentation clearly separates Preview proof from hosted production proof.
