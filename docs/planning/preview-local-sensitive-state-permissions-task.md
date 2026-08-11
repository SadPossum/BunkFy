# Preview Local Sensitive State Permissions Task

Status: implemented and verified
Date: 2026-08-11

## Goal

Keep the secret-bearing Preview environment and recoverable local backup bytes
private to the operator account from creation through restore and rehearsal.

## Finding

The generated `deploy/preview/.env` inherited host defaults and was mode
`0664`. A fresh Preview backup inherited a `0775` directory, `0644` state
artifacts, and root ownership for archives written by the Docker utility
container. Git ignored those paths, but ignore rules do not provide local
access control. The backup can contain database records, objects, protected
key material, adapter inputs, and the Data Rights ledger.

## Boundary

- On Unix, generated sensitive files use `0600` and sensitive directories use
  `0700`; consumers reject group or other access.
- On Windows, disable inherited access and retain only the current operator,
  Local System, and built-in Administrators.
- Reject reparse points and symbolic links at sensitive input boundaries.
- Make Docker-created backup archives operator-owned before exposing the
  completed backup.
- Provide an explicit repair command for existing local Preview artifacts.
- Keep this in BunkFy operations. It is not a GMA framework concern.
- Do not present local permissions as hosted backup encryption, KMS, immutable
  retention, access review, or provider recovery evidence.

## Delivery

- [x] Add cross-platform private file and directory helpers with focused tests.
- [x] Generate the Preview environment atomically with private permissions.
- [x] Require private environment permissions before Preview operations.
- [x] Create backup directories and artifacts with private permissions and
  operator ownership.
- [x] Require a private backup tree before restore or recovery rehearsal.
- [x] Add a deliberate repair command for existing local environment and
  backup paths.
- [x] Update the Preview and recovery runbooks.
- [x] Run focused operations verification and one real local permission proof.
- [x] Run one consolidated end-of-slice gate.
- [x] Commit and push the root slice.

## Verification Evidence

- `eng/verify-operations.ps1` passed the private-path behavior tests and every
  existing operations fixture.
- Repair changed the live ignored environment from `0664` to operator-owned
  `0600`. It changed backup manifest
  `37caad3b86884c6140b7f0b69dad0c79b30f87a3b325f33df359c1ef580c03a2`
  to an operator-owned `0700`/`0600` tree without changing that digest.
- Fresh schema-4 backup `2f814b3b-56cb-4a1e-bdbe-d720be3e48ba`
  recorded root commit `adb7cfffbc35af66086e71b6a67875d08da2e382`,
  used manifest digest
  `8ff777bedca77ef34cca84bda1d8ccb0a301b035421a104b8003bd7bf76d20d1`,
  and created every directory/file as operator-owned `0700`/`0600` with no
  leftover archive container.
- Isolated recovery evidence
  `.tmp/recovery-rehearsals/preview-743bfb3a959f46bf96609cb472fe9e75.json`
  passed all five restore, public-edge, Admin-boundary, and Data Protection
  continuity checks. The clone was removed and the live Preview returned
  healthy at release `preview-ec423ec`.
- Consolidated `eng/verify.ps1 -SkipRestore` passed repository and operations
  guards, zero-warning root/backend builds, migration-drift checks, every
  non-Docker framework and backend test, Architecture `102/102`, Integration
  `60/60`, current OpenAPI contracts, TypeScript and ESLint checks, web
  `267/267` across 52 files, and the production frontend build.

## Done When

- newly generated environment and backup paths are private by construction;
- unsafe existing inputs fail before Compose or restore work begins;
- the repair command tightens permissions without changing file bytes;
- backup integrity and historical-image restore behavior remain intact; and
- documentation states what local permissions do and do not prove.
