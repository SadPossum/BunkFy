# Current Candidate Publication Refresh Task

Status: in progress
Date: 2026-08-14

## Goal

Publish one exact, reviewable source candidate after the current product-domain
production milestones, then retain the scanned backend and web OCI bytes needed
for a later approved registry promotion. Do not substitute old candidate
evidence or present local Preview proof as hosted deployment evidence.

## Boundary

- The BunkFy root commit owns the recursive source identity and exact backend,
  web, and GMA pins.
- GitHub validation owns the clean-checkout repository gate for that commit.
- Product Image Evidence owns one build of unpublished backend and web OCI
  archives, SBOMs, vulnerability scans, checksums, and GitHub attestations.
- Preview evidence remains runtime rehearsal evidence. It does not attest the
  GitHub-built OCI bytes.
- Hosted registry authentication, immutable-tag policy, promotion, deployment,
  rollback, private approvals, and production data remain deployment-owned.

## Delivery

1. Commit this ledger so every workflow binds the final candidate source set.
2. Dispatch `validate` once for the exact branch head.
3. Dispatch Product Image Evidence once with retained candidate bytes and
   bounded retention.
4. Verify both run conclusions, exact head SHA, artifact identities, and
   candidate attestations before recording completion.
5. Keep the bundle unpublished until an approved non-local registry and
   private release record exist.

## Corrected Candidate Attempt

- Candidate `b88a82fbd66d6dd633c0ac9346c89dcaf4e50be6` failed validation run
  `31757055359` during clean-checkout restore because NuGet audit identified
  `SSH.NET 2025.1.0` as affected by high-severity advisory
  `GHSA-q939-rpr3-3284`.
- Image evidence run `31757060136` was cancelled while building the backend
  OCI archive. It produced no closed, attested, or promotable candidate bundle.
- BunkFy, every mounted GMA repository that directly consumes Testcontainers,
  and GMA Skeleton now make the patched `SSH.NET 2026.0.0` floor an explicit
  private test dependency. NuGet audit was not suppressed or downgraded.
- The replacement workflow pair must bind the corrected root commit; neither
  failed run is acceptable evidence for that source set.

## Acceptance

- the root, backend, web, and recursive GMA source graph is clean and published;
- exact-head validation passes from a clean GitHub checkout;
- exact-head image evidence builds and scans both OCI candidates, closes and
  attests evidence, and retains the exact candidate bundle;
- failures are investigated at the same commit rather than bypassed or hidden;
  and
- completion names the remaining hosted promotion, rollback, migration,
  recovery, operational, legal, and private-approval gates without claiming
  they are done.
