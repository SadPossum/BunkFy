# Post-Operator Hardening Candidate Publication Refresh Task

Status: in progress
Date: 2026-08-23

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
3. [ ] Publish one replacement root commit with a clean recursive graph.
4. [ ] Require exact-head Validate, Security Baseline, CodeQL, and source
   evidence success without dispatching duplicate development checks.
5. [ ] Build and retain one replacement Product Image Evidence bundle; verify
   scans, checksums, identities, and GitHub attestations independently.
6. [ ] Rehearse exact-image Production migration convergence and isolated
   Preview runtime composition, then prove complete cleanup.
7. [ ] Record completion in a documentation-only closure commit without
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

## Acceptance

- every recursive source reference is clean, published, and exact;
- clean-checkout validation, security, CodeQL, and source evidence pass for the
  replacement commit;
- one retained image bundle is scan-clean, checksum-closed, and attested;
- the exact archives pass migration and isolated runtime rehearsals; and
- no candidate resource, imported image, generated secret, or working
  directory remains after cleanup.
