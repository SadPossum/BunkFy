# Post-Operator Hardening Candidate Publication Refresh Task

Status: repository candidate evidence complete; deployment-owned gates remain
Date: 2026-08-23
Completed: 2026-08-23

## Goal

Publish one exact source and retained image candidate after the operator-facing
source-authority campaign and authentication-entry hardening. Do not reuse an
older bundle whose root or web identity predates those slices.

## Boundary

- The BunkFy root commit owns the recursive source identity and exact backend,
  web, and GMA pins.
- Backend and root clean-checkout validation, security, source evidence, and
  CodeQL must bind their exact published commits.
- Product Image Evidence builds, scans, closes, attests, and temporarily
  retains unpublished backend and web OCI archives. It does not publish them.
- Disposable migration and runtime rehearsals may consume only the verified,
  attested archives and must remove imported tags, containers, networks,
  volumes, generated secrets, and working state.
- Registry promotion, hosted deployment, rollback, backup/restore, key
  continuity, private approval, legal authorization, and production data
  remain deployment- or company-owned gates.

## Candidate Attempt History

- Source candidate `0029209a64f59b9b80cec0daafeac496d2a52ae2`
  passed the complete local repository gate, root Validate, Security Baseline,
  C# and JavaScript/TypeScript CodeQL, backend and root source evidence, Product
  Image Evidence, independent attestation verification, and exact-image
  migration rehearsal.
- Its exact runtime rehearsal correctly failed because BunkFy's deployment
  verifier still required `strict-origin-when-cross-origin` after the web edge
  and GMA API had converged on the stricter `no-referrer` policy. The rehearsal
  removed all disposable resources and imported image tags.
- That bundle is retained only as failed-attempt evidence. It is not a
  promotable candidate and must not be reused for the replacement rehearsal.

## Delivery

1. [x] Align the BunkFy public-edge and rollback verification fixtures with the
   current `no-referrer` contract.
2. [x] Run focused edge and rollback policy verification, then the complete
   repository gate once for the coherent replacement source.
3. [x] Publish one replacement root commit with a clean recursive graph.
4. [x] Require exact-head Validate, Security Baseline, CodeQL, and source
   evidence success without dispatching duplicate development checks.
5. [x] Build and retain one replacement Product Image Evidence bundle; verify
   scans, checksums, identities, and GitHub attestations independently.
6. [x] Rehearse exact-image Production migration convergence and isolated
   Preview runtime composition, then prove complete cleanup.
7. [x] Record completion in a documentation-only closure commit without
   presenting local Preview evidence as hosted-production proof.

## Verification Cadence

Use focused public-edge and rollback fixtures while correcting the stale
contract. Run the complete root gate once after the replacement candidate is
coherent. GitHub Actions and image evidence run only for the published exact
candidate, not after each edit.

## Replacement Source Verification

- Focused deployed public-edge and release-rollback fixtures pass with the
  `no-referrer` contract.
- The complete root verification gate passes after the correction, including
  recursive graph and pin checks, operations fixtures, zero-warning root and
  backend builds, migration drift, all non-Docker backend and GMA suites, 65
  host integration tests, and 113 architecture tests.
- Web type checking, linting, all 73 test files and 371 tests, and the
  production build of 3,032 transformed modules pass.
- Docker-backed provider suites remain covered by the preceding backend source
  candidate because this replacement changes only root deployment verification
  fixtures and documentation; the backend, web, and GMA pins are unchanged.

## Completion Evidence

- Exact candidate source:
  `42820c0e84de91a3c0d1ab34823a1701c0babd70`. The documentation-only
  closure commit that records these results is not a replacement candidate.
- Exact-root GitHub evidence passed: Validate run `32634018690`, Security
  Baseline run `32634018680`, CodeQL run `32634018676`, and Release Evidence
  run `32635719464`. Retained source artifact `9492247692` has digest
  `sha256:c585d01113535a7ad5d459dc737b0457e4956544a9053750974af154bcb47e8c`.
- The unchanged backend source remains
  `67f11b52bcbe31a2e5b24b67e7fde777ef5f4341`, covered by Validate run
  `32616874958`, Security Baseline run `32616874910`, and Release Evidence run
  `32631645785`. Retained artifact `9491206239` has digest
  `sha256:4c848b24e88097b966f05378bb4c4c10c658c66f95206eb39ce23e5e293cdc3d`.
- Product Image Evidence run `32635767133` retained exact candidate artifact
  `9492274872`, digest
  `sha256:fad7945b0cc6a2135428e1f59ca56d65e4f8eb95c35f8fc19eae7d4a249e6248`,
  and evidence artifact `9492275187`, digest
  `sha256:b34f86f92f91b0446ea1f44c1fe4b0aaf7fc98a2d482d532adc246f58a7ef152`.
- Independent verification required GitHub attestations and closed bundle
  checksum digest
  `333ee18fa561c5125f7f6b8fb33fefaf76d70371064629a9a4a11e26ec6ce36a`.
  Backend archive SHA-256
  `b87facc127e6a91cbd7d484b05fcd9a9ad82bbd065a2f74ed0019f5aeff58c79`
  binds to manifest
  `sha256:1e02ada5635a5352c7cb79af55de6593f4df6e1c9b32a56644cd9b61155ee553`;
  web archive SHA-256
  `298bbf2730395ab4ed5ac9ed522007f1248d801ba00f8b297134b5b771572e5d`
  binds to manifest
  `sha256:bc6d1a11e744f880557eff6555450ea289c71dbcdc7014b9747e2828f509e317`.
- Both image scans passed with zero vulnerabilities, misconfigurations,
  secrets, or blocking findings. The 361 backend and 25 web HIGH entries are
  license inventory, not security findings.
- Exact-image migration run `50f602c7ad3e` applied all 250 migrations across
  15 modules from an empty schema, rejected malformed source, backup, and
  database targets, and passed an idempotent rerun. Evidence is retained at
  `.tmp/migration-rehearsals/20260823T111350Z-candidate-42820c0e84de-7f1a2438.json`
  with SHA-256
  `3ffc744543981fed1369ee4a924334944dfe5c1254631905a903404935fcf3ac`.
- Exact-image Preview rehearsal release
  `candidate-42820c0e84de91a3c0d1ab34823a1701c0babd70` started replay and
  migrations, API, Worker, Admin API, and web from the attested identities;
  all required services became healthy, six public-edge checks passed, and
  management isolation passed. Private mode-`0600` evidence is retained at
  `.tmp/candidate-runtime-rehearsals/20260823T111534Z-candidate-42820c0e84de-90cf1460.json`
  with SHA-256
  `eb080cb4ffbf8303d7caee4758b6174d3d4c877e27416c33710e23277fb98bce`.
- Independent cleanup found no candidate image tag, container, network,
  volume, generated environment, or working directory after either rehearsal.

## Post-Candidate Promotion Preflight

Deployment-handoff hardening commit
`064aed3ddc84f9fe23ecb1f3f80867cf3baa193e` documents the promoter's
non-destructive `-WhatIf` path and proves that dry-run creates neither registry
nor promotion-evidence output. It is operations tooling only and is not a
replacement runtime or image candidate.

On 2026-08-23, this VPS downloaded retained artifact `9492274872` from Product
Image Evidence run `32635767133` and independently verified its closed bundle,
both OCI archives, and all four GitHub attestations against exact candidate
source `42820c0e84de91a3c0d1ab34823a1701c0babd70`. A hosted-shape promotion
`-WhatIf` preflight then accepted the candidate and destination contract while
creating no registry or evidence output. The downloaded 243 MB candidate was
removed after verification.

The complete root gate passed after the hardening, including every operations
fixture, synchronized solutions and source pins, zero-warning builds, migration
drift, all non-Docker backend and GMA suites, 113 architecture tests, 65 host
integration tests, web typecheck and lint, 73 test files with 371 tests, and the
3,032-module production build. Exact-head GitHub evidence also passed:

- Validate run `32641078282`;
- Security Baseline run `32641078277`; and
- CodeQL run `32641078249`, with both C# and JavaScript/TypeScript analyses
  successful.

No approved registry destination, production infrastructure, private release
record, or hosted admission was supplied or inferred by this preflight.

This closes repository-owned exact-source and exact-image candidate evidence.
It does not close registry promotion, hosted TLS deployment, authenticated
hosted workflows, rollback, backup/restore, key continuity, private approval,
legal authorization, or Production data admission.

## Acceptance

- every recursive source reference is clean, published, and exact;
- clean-checkout validation, security, CodeQL, and source evidence pass for the
  replacement commit;
- one retained image bundle is scan-clean, checksum-closed, and attested;
- the exact archives pass migration and isolated runtime rehearsals; and
- no candidate resource, imported image, generated secret, or working
  directory remains after cleanup.
