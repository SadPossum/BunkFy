# Production Migration Proof Refresh Task

Status: completed for current attested candidate
Date: 2026-08-12
Current refresh: 2026-08-22

## Goal

Refresh the isolated Production migration rehearsal against the exact backend
image that packages AdapterHost and the current committed BunkFy product graph.

## Finding

The latest retained migration rehearsal predates backend commit `a269085` and
its exact image digest. No module migration changed in that commit, but the
current product candidate should still prove that its packaged migration host
can plan, apply, converge, and repeat idempotently without relying on older
image evidence.

## Boundary

- This is product deployment choreography, not domain or GMA behavior.
- Use the existing exact local image and digest-pinned PostgreSQL image. Do not
  build, pull, publish, or contact the live Preview database.
- Keep the random database password and generated Production keys in the
  script's private temporary files; retain only minimized evidence.
- Remove the disposable PostgreSQL container, internal network, and temporary
  directory on success or failure.
- Passing local mechanics do not approve a Production database migration,
  maintenance window, backup, rollback, or release.

## Delivery

- [x] Bind the rehearsal to the current committed root and exact backend image.
- [x] Prove Production Plan does not mutate an empty target.
- [x] Prove malformed and mismatched approval inputs fail before mutation.
- [x] Apply the exact planned catalogue and database-target hashes.
- [x] Re-plan to zero pending migrations and repeat Apply idempotently.
- [x] Remove all disposable resources and retain minimized evidence.

## Verification Evidence

- Rehearsal `e7e6257f4d14` binds root commit
  `27dfded7e0890a916d55521c4ab791f028079c78` to backend image and repository
  digest `sha256:372db6fd4332ddcfd69ad5c4ee0ccb81aac85ad445e290d92af9e333f261d2e9`.
  That image packages backend source commit `a269085`.
- PostgreSQL ran from the tracked `17.5-alpine` reference at digest
  `sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa`.
- Plan covered 15 modules and 223 pending migrations without changing the
  empty target schema. Malformed source identity, malformed backup reference,
  and a valid approval for a different database target all failed closed.
- Approved Apply installed all 223 migrations. The next Plan reported zero
  pending migrations, and repeating the same approved Apply retained the exact
  resulting schema fingerprint.
- The internal network exposed no ports or persistent volumes, and all
  rehearsal resources were removed. Evidence is retained locally at
  `.tmp/migration-rehearsals/20260812T005158Z-e7e6257f4d14.json`, SHA-256
  `5f178a87ff692c2ced5ffc6d14ed395f7251138d5ebd50fe2b35a5141d8f3894`.
- This is isolated executable proof. It is not a Production approval,
  maintenance-window rehearsal, target backup, compatibility sign-off, or
  post-deployment verification.

## Done When

One current evidence record binds the exact source and image identities to a
non-mutating plan, fail-closed admission checks, successful apply, zero-pending
convergence, and schema-equivalent repeat apply, with no rehearsal resources
left behind.

## Current Candidate Refresh

Candidate `b95ece148c7172628e1182ed930397b8a4f6a04b` has clean-checkout validation
and a retained, scanned, attested OCI bundle. Refresh the migration proof from
that exact bundle instead of relying on the older local-registry image:

- [x] verify the closed candidate bundle and GitHub attestations;
- [x] load only its backend OCI archive, require Docker's repository digest to
  match the attested manifest, and bind evidence to the resolved image id;
- [x] run the existing non-mutating Plan, fail-closed admission, approved Apply,
  zero-pending convergence, and idempotent rerun checks;
- [x] remove the disposable PostgreSQL resources and imported candidate image;
  and
- [x] retain minimized evidence and record its checksum without presenting the
  rehearsal as hosted migration approval.

### Current Candidate Evidence

- Candidate bundle checksum-set digest:
  `134dd452842e00e913136352c5c068e2927714f00ce390c68fabb300dc9c827f`;
  all GitHub attestations verified without an unattested bypass.
- Backend archive SHA-256:
  `12dd7ae12c506b43b13b7fbcfd5344a691c04388ae722c75b97c6e6a6dd1dafc`;
  Docker's repository digest matched manifest
  `sha256:a6166d167bf781bd3ff4de161eae8c2320da561d6b5115762a3d2f13574e4334`,
  and the migration evidence recorded the exact resolved image id used.
- Rehearsal `94119036ff85` planned 15 modules and 223 pending migrations without
  mutating the empty target. Malformed source identity, malformed backup
  reference, and wrong database-target approval all failed before mutation.
- Approved Apply installed all 223 migrations, the next Plan reported zero
  pending migrations, and the repeated approved Apply preserved the resulting
  schema fingerprint.
- Evidence is retained locally at
  `.tmp/migration-rehearsals/20260815T051327Z-candidate-b95ece148c71-789b1d23.json`,
  SHA-256
  `7fa1c362e8fbedf12f4ca4ad4dbc31e0e8029b63529689268e5fe2ef179ee600`.
  It contains no connection string, password, or generated key material.
- Independent cleanup checks found zero matching containers, internal networks,
  or imported candidate images after completion.

This closes isolated mechanics for the attested candidate only. It is not a
hosted target backup, migration approval, maintenance-window rehearsal,
compatibility sign-off, deployment, rollback, or post-deployment verification.

## Post-Domain Candidate Refresh

Candidate `d6679787cddf2605ab2dd5f31073045d53195343` has exact-head backend
and product validation plus retained, scanned, attested OCI bytes. The
Production migration proof was refreshed from that bundle after the
Reservations, Retention, Data Rights, and tenant-termination slices:

- candidate bundle checksum-set digest:
  `b3790a276153630752778a1db3b653e367f8115e0644a942d8f269bfceb87382`;
  all GitHub attestations verified without an unattested bypass;
- backend archive SHA-256:
  `15816e14917c887780a888de885ff37945e77977c0ec22f220a17414c4638dd9`;
  Docker's repository digest and executed image id both matched manifest
  `sha256:621d1fd9ec70de7f34b2a462311a79313e8b383d43113efaad748c1675254d5d`;
- PostgreSQL ran from the tracked `17.5-alpine` reference at digest
  `sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa`;
- rehearsal `559409b784f1` planned 15 modules and 230 pending migrations
  without mutating the empty target. Malformed source identity, malformed
  backup reference, and wrong database-target approval all failed before
  mutation;
- approved Apply installed all 230 migrations, the next Plan reported zero
  pending migrations, and the repeated approved Apply preserved the resulting
  schema fingerprint;
- evidence is retained locally at
  `.tmp/migration-rehearsals/20260821T135455Z-candidate-d6679787cddf-bff1a276.json`,
  SHA-256
  `dec0aa9a392886223bc8c9c1b84ff570c820501a34b25c6f2e8d42ce01baed5e`;
  it contains no connection string, password, or generated key material; and
- independent cleanup checks found no matching containers, internal network,
  persistent volume, or imported candidate image after completion.

This refresh supersedes the older candidate as current isolated migration
mechanics evidence. It remains local proof, not a hosted target backup,
migration approval, maintenance-window rehearsal, compatibility sign-off,
deployment, rollback, or post-deployment verification.

## Post-Hardening Candidate Refresh

Candidate `f31bebefd055d0f8a0260ec1f0d5c62a3c25856b` has exact-root
validation, Security Baseline, CodeQL, source evidence, and retained, scanned,
attested OCI bytes. Its Production migration proof supersedes the post-domain
candidate:

- closed bundle digest
  `58dbd757075ff3e358abd15ef77f73afb3360cfe1b47ddd30d9e64bda34016c6`
  and every GitHub attestation verified without an unattested bypass;
- backend archive SHA-256
  `9de6c1d8bb2cfb6ce23860ed38b85ae22b966cb507d0e60f014e89d24ffe8095`,
  executed image id, and repository digest matched manifest
  `sha256:02a59243ed4cc48a3b888a7a2435daa15531903fd637cb089c756df736d19dee`;
- PostgreSQL remained pinned to tracked digest
  `sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa`;
- rehearsal `bf4fafa2609c` planned 15 modules and 250 pending migrations
  without mutating the empty target. Malformed source identity, malformed
  backup reference, and wrong database-target approval failed before mutation;
- approved Apply installed all 250 migrations, the next Plan reported zero
  pending, and repeated Apply preserved schema fingerprint
  `181593cbe9bbc24c229e73185ea7fb5e54ae2163e1c804663f8884eb6ae54eb1`;
- minimized evidence
  `.tmp/migration-rehearsals/20260822T134123Z-candidate-f31bebefd055-5f8ac2d0.json`
  has SHA-256
  `de4b0e9fc171293c796b60011072e62047d2ce584b306a5af10567ca51f881fa`
  and contains no connection string, password, or generated key material; and
- independent cleanup found no matching container, network, volume, working
  directory, or imported candidate image.

This is current isolated migration-mechanics evidence. It is not a hosted
target backup, migration approval, maintenance-window rehearsal, deployment,
rollback, or post-deployment verification.
