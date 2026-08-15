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

## Candidate Attempt History

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
- Corrected candidate `af3a41a89f304286384f8aa67c36ed11916c82b9`
  passed clean-checkout restore and NuGet audit in validation run `31758264402`,
  then exposed an LF-only multiline guard in `eng/verify-operations.ps1` on the
  Windows runner. Runtime rehearsal behavior was not implicated.
- Image evidence run `31758272376` was cancelled after that verification
  failure and produced no promotable candidate bundle. The operations guard
  now counts the required call exactly once with either LF or CRLF input.
- Candidate `fed4820b78f48c328b826fb61589a7c7122d14fa` passed exact-head
  validation run `31758831616`, including clean checkout, bootstrap, restore,
  NuGet audit, and the Windows operations guard.
- Image evidence run `31863614352` built both OCI archives and retained closed
  scan evidence, but correctly blocked publication because the backend runtime
  contained `Microsoft.NETCore.App.Runtime.linux-x64 10.0.10`, affected by
  high-severity `CVE-2026-62901`. The retained evidence artifact is
  `product-image-evidence-fed4820b78f48c328b826fb61589a7c7122d14fa`
  (`9241444441`, GitHub artifact digest
  `sha256:2bb2a6ae32f271f7b6c8ea9ed228a745335fba2fe4ca7655bcd50db75ac8a2e0`).
- The replacement candidate pins the final ASP.NET runtime to the serviced
  `10.0.11` manifest. The failed scan and skipped attestations/bundle are not
  accepted as promotable evidence.

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
