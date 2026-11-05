# Current Candidate Runtime Rehearsal Task

Status: completed
Date: 2026-08-15
Completed: 2026-08-15
Current refresh: 2026-08-22

## Goal

Run the exact attested backend and web OCI archives for candidate
`b95ece148c7172628e1182ed930397b8a4f6a04b` as one disposable Preview release,
then retain minimized evidence that the composed product starts with the
expected release identity and isolation.

## Finding

The candidate has clean-checkout validation, closed OCI/SBOM/scan/attestation
evidence, and an exact-image Production migration rehearsal. The packaged
migration host has therefore executed, but the attested API, worker, web, and
Admin API bytes have not yet run together as the product release. The current
long-lived Preview stack predates this candidate and must not be presented as
proof for it.

## Boundary

- This is product deployment choreography. It does not change GMA or a domain
  module.
- Verify the retained candidate bundle and attestations before importing either
  image. Do not build, pull, push, or accept pre-existing candidate tags.
- Generate fresh private Preview secrets and use unique Compose project, volume,
  release, and loopback-port identities. Do not read or mutate the long-lived
  Preview environment or its data.
- Start only from already reviewed first-party and dependency images, require
  every first-party service container to bind to the attested image identity,
  and reuse the existing public-edge and management-isolation verifiers.
- Remove the disposable stack, volumes, networks, generated environment, probe
  evidence, and imported candidate tags on success or failure.
- Passing this rehearsal is local executable Preview evidence. It is not a
  registry promotion, hosted deployment, trusted-TLS probe, authenticated
  workflow rehearsal, rollback rehearsal, or Production approval.

## Delivery

- [x] Allow the existing Preview tooling to generate a private environment at
  an explicit path and to start reviewed images with both build and pull
  disabled.
- [x] Verify and import the exact backend and web archives without replacing a
  local candidate tag.
- [x] Preflight every resolved Compose image locally, start an isolated release,
  and prove service-container image binding.
- [x] Prove matching web/API release identity, browser-edge policy, Admin API
  absence from the public edge, and management-network isolation.
- [x] Remove all disposable resources and retain only minimized, private
  rehearsal evidence.

## Completion Evidence

- Bundle checksum-set digest
  `134dd452842e00e913136352c5c068e2927714f00ce390c68fabb300dc9c827f`
  and all GitHub attestations verified before import.
- Backend archive SHA-256
  `12dd7ae12c506b43b13b7fbcfd5344a691c04388ae722c75b97c6e6a6dd1dafc`
  ran at manifest identity
  `sha256:a6166d167bf781bd3ff4de161eae8c2320da561d6b5115762a3d2f13574e4334`.
  Web archive SHA-256
  `f63580f37f3899aa1bc937b17171cb02805c3f12cb990d446dcd98bc1b74302f`
  ran at manifest identity
  `sha256:03a10de4e27cfeab1be079cc1b6785bf14ae16925ea4152d4c96f8403ab2a86d`.
- Seven resolved images were available locally. The replay initializer,
  migration host, API, Worker, and Admin API bound to the backend identity; web
  bound to the web identity. Both one-shot services exited successfully, and
  API, Admin API, and web were healthy.
- Release `candidate-b95ece148c7172628e1182ed930397b8a4f6a04b` passed six
  public-edge checks, including matching web/API identity, security headers,
  Admin API absence, and untrusted-Host rejection. The existing management
  isolation verifier also passed.
- Evidence is retained locally at
  `.tmp/candidate-runtime-rehearsals/20260815T063700Z-candidate-b95ece148c71-674ad446.json`,
  SHA-256
  `2b78d66cbd558018f266c9956a7fd6334a660360d46b9c5cc62c04aa4821f5a3`,
  with Unix mode `0600` and no generated secret or connection string.
- Independent cleanup found no matching candidate container, network, volume,
  working directory, backend tag, or web tag. The long-lived Preview remained
  healthy at its existing `preview-projection-bootstrap-5c33c63` release.
- The explicit-path environment/config smoke passed, Operations Notifications
  remained green at 104 focused tests, the complete operations fixture gate
  passed, the generated backend/root solutions were synchronized, repository
  release evidence remained valid, and `git diff --check` passed.

This closes local exact-byte composition mechanics for the current candidate.
It does not close any hosted promotion, deployment, TLS, authenticated workflow,
rollback, private approval, or Production gate.

## Post-Hardening Candidate Refresh

The same rehearsal executed candidate
`f31bebefd055d0f8a0260ec1f0d5c62a3c25856b` after exact-root Validate,
Security Baseline, CodeQL, Release Evidence, and Product Image Evidence passed:

- bundle digest
  `58dbd757075ff3e358abd15ef77f73afb3360cfe1b47ddd30d9e64bda34016c6`
  and all GitHub attestations verified before import;
- backend archive SHA-256
  `9de6c1d8bb2cfb6ce23860ed38b85ae22b966cb507d0e60f014e89d24ffe8095`
  ran at manifest
  `sha256:02a59243ed4cc48a3b888a7a2435daa15531903fd637cb089c756df736d19dee`;
  web archive SHA-256
  `b0c9fea9e53648dbb61ccd11cac5f6db135f86e61ddf757feb37bd6576a67f99`
  ran at manifest
  `sha256:3712ce5271e70b016b0946a3619bdc32853d5e2b3d2e4654d1f1a179e14a150d`;
- replay initialization and migrations exited successfully; API, Worker,
  Admin API, and web reached their expected running and healthy states;
- release `candidate-f31bebefd055d0f8a0260ec1f0d5c62a3c25856b` passed web/API
  release identity, browser policy, edge health, public API smoke, Admin API
  absence, untrusted-Host rejection, and management isolation;
- private evidence
  `.tmp/candidate-runtime-rehearsals/20260822T134257Z-candidate-f31bebefd055-f736caff.json`
  has SHA-256
  `cfd42320a681af4e1cb30b1e926d069947b4d24c8eb59c0297167655d737d568`
  and Unix mode `0600`; and
- no candidate container, network, volume, imported tag, generated environment,
  or working directory remained after cleanup.

This supersedes the older candidate as current local exact-byte composition
proof. Registry promotion, hosted TLS, authenticated workflows, rollback,
backup/restore, private approval, and Production authorization remain open.

## Done When

One current evidence record binds the candidate source, bundle checksum set,
attested backend and web manifest identities, composed release identity,
first-party service image bindings, public-edge checks, management isolation,
and complete cleanup. No generated secret, candidate container, network,
volume, or imported candidate tag remains.
