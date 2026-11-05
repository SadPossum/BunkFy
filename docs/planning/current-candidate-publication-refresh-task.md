# Current Candidate Publication Refresh Task

Status: complete
Date: 2026-08-14
Completed: 2026-08-15

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
- Ordinary Preview evidence remains runtime rehearsal evidence and does not
  identify the GitHub-built OCI bytes. The dedicated candidate rehearsal may
  verify and execute those exact attested archives locally, but still does not
  become hosted deployment evidence.
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

## Completion Evidence

- Exact source candidate:
  `b95ece148c7172628e1182ed930397b8a4f6a04b`, with backend
  `ac33fa3b10baa00d80020fa6cc22a127909c3d3d` and web
  `38655aa13b5f1772bd3199c2dc2517708c1dd35c` in a clean recursive source set.
- Clean-checkout validation: run
  [`31864477931`](https://github.com/SadPossum/BunkFy/actions/runs/31864477931)
  completed successfully for the exact source candidate.
- Product Image Evidence: run
  [`31865308259`](https://github.com/SadPossum/BunkFy/actions/runs/31865308259)
  completed successfully for the same source candidate. Backend and web each
  reported zero vulnerabilities, misconfigurations, and secrets, and zero
  blocking security findings.
- Exact OCI candidate artifact:
  `product-image-candidate-b95ece148c7172628e1182ed930397b8a4f6a04b`
  (`9241898578`, GitHub artifact digest
  `sha256:f3d9f41e81a4c9bdd82e872de3bd1927c51550fde3d176610eff3111da47bcc6`,
  expires `2026-08-22T04:54:39Z`). Its closed checksum-set digest is
  `134dd452842e00e913136352c5c068e2927714f00ce390c68fabb300dc9c827f`.
- Backend OCI archive: SHA-256
  `12dd7ae12c506b43b13b7fbcfd5344a691c04388ae722c75b97c6e6a6dd1dafc`,
  manifest digest
  `sha256:a6166d167bf781bd3ff4de161eae8c2320da561d6b5115762a3d2f13574e4334`.
- Web OCI archive: SHA-256
  `f63580f37f3899aa1bc937b17171cb02805c3f12cb990d446dcd98bc1b74302f`,
  manifest digest
  `sha256:03a10de4e27cfeab1be079cc1b6785bf14ae16925ea4152d4c96f8403ab2a86d`.
- Closed evidence artifact:
  `product-image-evidence-b95ece148c7172628e1182ed930397b8a4f6a04b`
  (`9241898810`, GitHub artifact digest
  `sha256:fc8fb615806354879b4a02d6e3dcaa0c2d2f6350f1acdbb695eafc0aff4e3521`,
  expires `2026-09-14T04:54:43Z`). The separately downloaded evidence and the
  copy embedded in the candidate bundle are byte-identical.
- Local independent verification of the downloaded bundle validated the closed
  checksums, both OCI manifests, exact source commit, and all four GitHub
  attestations without `-AllowUnattested`.
- The dedicated candidate runtime rehearsal subsequently executed those exact
  backend and web archive identities together, proved matching release identity
  plus public/management isolation, and removed its disposable resources. Its
  private local evidence is recorded by
  `current-candidate-runtime-rehearsal-task.md`; it is not a hosted release.

The documentation closure commit follows the candidate source commit and is
not part of the attested OCI source identity. Hosted registry authentication,
immutable promotion, hosted migration and deployment, deployed rollback,
edge and Admin isolation, backup/restore and key continuity, private release
approval, and legal/company authorization remain external gates. Preview is
not production evidence.

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
