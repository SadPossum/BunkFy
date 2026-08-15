# Current Candidate Runtime Rehearsal Task

Status: completed
Date: 2026-08-15
Completed: 2026-08-15

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

## Done When

One current evidence record binds the candidate source, bundle checksum set,
attested backend and web manifest identities, composed release identity,
first-party service image bindings, public-edge checks, management isolation,
and complete cleanup. No generated secret, candidate container, network,
volume, or imported candidate tag remains.
