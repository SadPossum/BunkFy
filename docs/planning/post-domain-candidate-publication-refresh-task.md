# Post-Domain Candidate Publication Refresh Task

Status: complete
Date: 2026-08-20
Completed: 2026-08-21

## Goal

Publish one current, reviewable source and image candidate after the completed
Reservations, Retention, and Data Rights production-preparation slices. The
previous attested candidate predates those changes and its retained OCI bytes
must not be reused as evidence for the current source graph.

## Boundary

- The BunkFy root commit owns the recursive source identity and exact backend,
  web, and GMA pins.
- Backend validation must first pass for the exact published backend commit.
- Root validation owns the clean-checkout product gate for the candidate root.
- Product Image Evidence owns one build, scan, checksum closure, attestation,
  and bounded retention of the unpublished backend and web OCI archives.
- A disposable candidate runtime rehearsal may execute those exact archives;
  ordinary local Preview images are useful composition evidence but are not the
  GitHub-built candidate bytes.
- Registry promotion, hosted migration and rollout, rollback, private approval,
  legal authorization, and production data remain deployment-owned gates.

## Delivery

1. [x] Commit this ledger with the exact current recursive source graph.
2. [x] Require successful backend `validate` and `Security Baseline` runs for
   the exact backend commit.
3. [x] Dispatch root `validate` once for the exact candidate head.
4. [x] Dispatch Product Image Evidence once, retaining candidate bytes for 14
   days so the approved promotion or rehearsal boundary can consume them.
5. [x] Verify exact head SHA, workflow conclusions, artifact identities,
   closed checksums, scan policy, and GitHub attestations.
6. [x] Rehearse the exact retained OCI archives in a disposable Preview
   composition and remove its resources.
7. [x] Keep the bundle unpublished until an approved non-local registry and
   private release record exist.

## Verification Cadence

Do not rerun broad local or Docker gates for this documentation-only wrapper.
The backend slice already passed its coherent local gate and exact Preview
rollout. Observe the backend publication workflows once, then run one root
validation and one Product Image Evidence workflow for the final candidate.
Investigate failures against that same commit instead of dispatching around
them.

## Acceptance

- root, backend, web, and recursive GMA references are clean and published;
- backend and root clean-checkout validation pass for their exact commits;
- one retained image bundle is scan-clean, checksum-closed, and attested;
- the exact retained backend and web archives run together successfully in a
  disposable candidate rehearsal; and
- documentation clearly separates local/Preview proof from hosted-production
  and company authorization.

## Completion Evidence

- Exact source candidate:
  `d6679787cddf2605ab2dd5f31073045d53195343`, with backend
  `7331e7db61b9cac38390caa4a5c5069b46970596` and web
  `fe2792b099af6a39c67a1264f89ece3dfca0c8de` in a clean 13-repository
  recursive source set.
- Backend validation run
  [`32486077763`](https://github.com/SadPossum/BunkFy.Backend/actions/runs/32486077763)
  passed on Windows and Ubuntu for the exact backend commit. Security Baseline
  run
  [`32486077768`](https://github.com/SadPossum/BunkFy.Backend/actions/runs/32486077768)
  also passed for that commit.
- Root validation run
  [`32486156054`](https://github.com/SadPossum/BunkFy/actions/runs/32486156054)
  passed for the exact source candidate.
- Product Image Evidence run
  [`32487757990`](https://github.com/SadPossum/BunkFy/actions/runs/32487757990)
  passed for the same source candidate. Backend and web each reported zero
  vulnerabilities, misconfigurations, secrets, and blocking security
  findings. The recorded HIGH classifications are 361 backend and 25 web
  license findings; they remain non-blocking evidence until an approved
  license policy and allowlist exist.
- Exact OCI candidate artifact:
  `product-image-candidate-d6679787cddf2605ab2dd5f31073045d53195343`
  (`9448768552`, GitHub artifact digest
  `sha256:747e4421f472f31f7f33ea47486a63659ea1be384a2f36c83671721d3c09672b`,
  expires `2026-09-04T13:44:51Z`). Its closed checksum-set digest is
  `b3790a276153630752778a1db3b653e367f8115e0644a942d8f269bfceb87382`.
- Backend OCI archive: SHA-256
  `15816e14917c887780a888de885ff37945e77977c0ec22f220a17414c4638dd9`,
  manifest digest
  `sha256:621d1fd9ec70de7f34b2a462311a79313e8b383d43113efaad748c1675254d5d`.
- Web OCI archive: SHA-256
  `7ce5d87d3207ce72d78c1b2c515da3f25d13449eda05848417dd83e437d69837`,
  manifest digest
  `sha256:42e558f21b96bac9a39fcbc1fea324183118756dbdc3e4dd3c5c3f63edd9cffe`.
- Closed evidence artifact:
  `product-image-evidence-d6679787cddf2605ab2dd5f31073045d53195343`
  (`9448769381`, GitHub artifact digest
  `sha256:c29930d83eb2c63cba48e3e36d56632d0164fefcba3f99cae931411fdfc92e2a`,
  expires `2026-09-20T13:44:55Z`). The separately downloaded evidence and the
  copy embedded in the candidate bundle are byte-identical.
- Independent consumer verification validated the closed checksums, both OCI
  manifests, exact source commit, and all GitHub attestations without
  `-AllowUnattested`.
- The exact retained archives ran together in disposable Preview composition
  `bunkfy-candidate-d6679787cddf-424d0673`. Migrations completed; API, Worker,
  Admin API, and web reached their expected states; the public edge passed six
  checks; management isolation passed; and all generated resources, secrets,
  and imported candidate tags were removed. The private minimized evidence is
  `.tmp/candidate-runtime-rehearsals/20260821T134841Z-candidate-d6679787cddf-424d0673.json`
  with SHA-256
  `0c1afea797dbb7e7bf816340912b86011d36fdfa9af7c2e12dc6ece9d59641aa`.

This documentation closure follows the candidate source commit and is not part
of the attested OCI source identity. The bundle remains unpublished. Hosted
promotion, migration, rollout, rollback, recovery, edge and Admin verification,
private approval, and legal/company authorization remain separate gates.

## Deferred

- authenticating to or selecting the approved hosted registry;
- immutable registry promotion and deployment;
- hosted migration apply, rollback, edge, Admin, backup/restore, and key
  continuity proof;
- private release approval, legal decisions, and authorization for real guest
  data.
