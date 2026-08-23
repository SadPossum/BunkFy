# Post-Hardening Candidate Publication Refresh Task

Status: repository candidate evidence complete; deployment-owned gates remain
Date: 2026-08-22

## Goal

Publish one exact source and image candidate after the current domain-by-domain
production hardening campaign. The retained candidate at `d667978` predates the
authoritative-state, tenant-integrity, retry-proof, Operations Notifications,
and Data Rights cancellation slices and must not be reused as evidence for the
current graph.

## Boundary

- The BunkFy root commit owns the recursive source identity and exact backend,
  web, and GMA pins.
- Backend validation, security, Docker integration, and source evidence must
  bind the exact published backend commit. Docker runs once because this
  candidate contains new migrations and provider-sensitive transaction work.
- Root validation, security, CodeQL, source evidence, and Product Image
  Evidence must bind one exact root commit.
- Product Image Evidence builds and scans unpublished OCI archives and retains
  their exact bytes for bounded rehearsal. It does not publish an image.
- The existing disposable migration and runtime rehearsals may consume only
  the verified, attested archives from this candidate.
- Registry promotion, hosted migration and rollout, rollback, backup/restore,
  key continuity, private approval, legal authorization, and production data
  remain deployment-owned gates.

## Current Source Floor

- backend: `9f9d44abcd16c0ec0f7b7b4f0137437c9200c835`;
- web: `fe2792b099af6a39c67a1264f89ece3dfca0c8de`;
- GMA Framework: `bdc508208f84a4b85bb7ab39850c6065086c56c4`;
- GMA Organizations: `69b18cdecb1814a230516eaeed6ab4e6eb55efdf`;
- backend validation: GitHub Actions run `32572915802` passed on Ubuntu and
  Windows for the exact backend commit;
- backend Security Baseline: GitHub Actions run `32572915803` passed for the
  exact backend commit;
- backend local verification: the exact source tree passed the consolidated
  non-Docker repository gate, including 397/397 Workspaces, 285/285 Staff,
  119/119 extension Workspaces, 116/116 Operations Notifications, 112/112
  Architecture, and 65/65 non-Docker integration tests; focused PostgreSQL
  serialization and authoritative-membership scenarios also passed;
- backend provider verification: GitHub Actions Docker Tests run `32573683901`
  passed 160/160 Docker integration tests in 13 minutes 46 seconds for the
  exact backend commit;
- backend source evidence: GitHub Actions Release Evidence run `32573697962`
  passed release-policy, source-set, security, SBOM, provenance, attestation,
  and retention checks for the exact backend commit. Artifact
  `release-evidence-9f9d44abcd16c0ec0f7b7b4f0137437c9200c835` is retained for
  90 days.

The exact candidate root is the commit that first records this ledger and the
source pointers above. Evidence is added in a later documentation-only closure
commit and is never presented as part of the attested source identity.

## Delivery

1. [x] Commit and publish this ledger as the exact candidate root.
2. [x] Require exact-head backend validation and Security Baseline success.
3. [x] Run one exact-head backend Docker workflow and source-evidence workflow.
4. [x] Run root validation, Security Baseline, CodeQL, and source evidence once
   for the exact candidate root.
5. [x] Run Product Image Evidence once with candidate bytes retained for 14
   days; verify the closed checksums, scan policy, artifacts, and attestations.
6. [x] Rehearse Production migration plan/apply convergence from the exact
   backend archive, then run the exact backend and web archives together in an
   isolated Preview composition.
7. [x] Remove disposable resources and record minimized evidence in a
   documentation-only closure commit.

## Candidate Closure Evidence

- Candidate source `f31bebefd055d0f8a0260ec1f0d5c62a3c25856b` supersedes the
  first ledger commit after the root solution guard found and the canonical
  generator added three missing backend task documents. Draft PR
  [#15](https://github.com/SadPossum/BunkFy/pull/15) retains the review surface.
- Exact-root Validate run
  [`32575040510`](https://github.com/SadPossum/BunkFy/actions/runs/32575040510),
  Security Baseline run
  [`32575040444`](https://github.com/SadPossum/BunkFy/actions/runs/32575040444),
  and CodeQL run
  [`32575040421`](https://github.com/SadPossum/BunkFy/actions/runs/32575040421)
  passed. CodeQL covered C# and JavaScript/TypeScript.
- Release Evidence run
  [`32575059676`](https://github.com/SadPossum/BunkFy/actions/runs/32575059676)
  passed and retained artifact
  `release-evidence-f31bebefd055d0f8a0260ec1f0d5c62a3c25856b` for 90 days.
- Product Image Evidence run
  [`32575060975`](https://github.com/SadPossum/BunkFy/actions/runs/32575060975)
  passed both builds, scans, closed evidence, attestations, exact-byte bundle
  verification, and retention. The scans reported zero vulnerabilities,
  misconfigurations, secrets, or blocking findings. The 361 backend and 25 web
  HIGH classifications are license inventory, not security findings.
- Exact candidate artifact
  `product-image-candidate-f31bebefd055d0f8a0260ec1f0d5c62a3c25856b`
  (`9476408474`, digest
  `sha256:694e2a2fc329e2f8e68e8ddf10141735cf6ec288a97e5b83cedcabfc1de3e0a7`)
  expires `2026-09-05T13:19:00Z`. Closed checksum-set digest
  `58dbd757075ff3e358abd15ef77f73afb3360cfe1b47ddd30d9e64bda34016c6`
  and all GitHub attestations verified independently.
- Backend archive SHA-256 is
  `9de6c1d8bb2cfb6ce23860ed38b85ae22b966cb507d0e60f014e89d24ffe8095`
  at manifest
  `sha256:02a59243ed4cc48a3b888a7a2435daa15531903fd637cb089c756df736d19dee`.
  Web archive SHA-256 is
  `b0c9fea9e53648dbb61ccd11cac5f6db135f86e61ddf757feb37bd6576a67f99`
  at manifest
  `sha256:3712ce5271e70b016b0946a3619bdc32853d5e2b3d2e4654d1f1a179e14a150d`.
- Migration rehearsal `bf4fafa2609c` planned 15 modules and 250 migrations
  without mutation, rejected malformed and wrong-target approvals, applied all
  250, converged to zero pending, and repeated idempotently. Evidence
  `.tmp/migration-rehearsals/20260822T134123Z-candidate-f31bebefd055-5f8ac2d0.json`
  has SHA-256
  `de4b0e9fc171293c796b60011072e62047d2ce584b306a5af10567ca51f881fa`.
- Runtime release
  `candidate-f31bebefd055d0f8a0260ec1f0d5c62a3c25856b` passed exact image
  binding, expected service states, six public-edge checks, and management
  isolation. Evidence
  `.tmp/candidate-runtime-rehearsals/20260822T134257Z-candidate-f31bebefd055-f736caff.json`
  has SHA-256
  `cfd42320a681af4e1cb30b1e926d069947b4d24c8eb59c0297167655d737d568`.
- Independent cleanup found no candidate container, network, volume, imported
  tag, generated environment, or working directory. The bundle remains
  unpublished.

## Verification Cadence

Do not rerun broad local or Docker gates while observing the candidate. Fix a
failure against the same source commit when possible; create a replacement
candidate only when source changes are required. GitHub Actions is the final
clean-checkout and artifact boundary, not an edit-by-edit development loop.

## Acceptance

- every recursive source reference is clean, published, and exact;
- backend and root clean-checkout gates pass for their recorded commits;
- provider-backed tests pass once for the exact backend candidate;
- source and OCI evidence is scan-clean, checksum-closed, and attested;
- exact retained archives pass isolated migration and runtime rehearsal; and
- the closure names every remaining hosted, operational, legal, and private
  approval gate without claiming that repository evidence completed them.
