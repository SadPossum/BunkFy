# Post-Hardening Candidate Publication Refresh Task

Status: source prepared; hosted evidence incomplete
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
4. [ ] Run root validation, Security Baseline, CodeQL, and source evidence once
   for the exact candidate root.
5. [ ] Run Product Image Evidence once with candidate bytes retained for 14
   days; verify the closed checksums, scan policy, artifacts, and attestations.
6. [ ] Rehearse Production migration plan/apply convergence from the exact
   backend archive, then run the exact backend and web archives together in an
   isolated Preview composition.
7. [ ] Remove disposable resources and record minimized evidence in a
   documentation-only closure commit.

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
