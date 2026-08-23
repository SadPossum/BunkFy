# Image Candidate Promotion

Use this manual, registry-neutral boundary after a passing Product Image
Evidence run retained the exact OCI candidate bundle. It publishes those
already scanned bytes; it never rebuilds an image.

## Prerequisites

- download and extract `product-image-candidate-<commit>`;
- install Skopeo and authenticate it to the approved registry through its
  normal auth store;
- configure immutable tags or an equivalent write-once policy in the registry;
- choose one non-secret release id that is safe as an OCI tag; and
- retain an approved rollback or recovery proof for Production admission.

Hosted promotion rejects `localhost`, loopback addresses, and the reserved
`registry.fixture.invalid` authority. Those destinations belong only to the
explicit fixture path and cannot produce hosted promotion evidence, even when
the source candidate itself has valid attestations.

Do not place registry credentials in command arguments, destination references,
or evidence paths. The script has no username, password, token, insecure TLS,
or certificate-bypass parameter.

## Dry-Run Preflight

Before publication, run the intended release id, destination references, and
evidence path through the same command with `-WhatIf`:

```powershell
./eng/operations/promote-image-candidate.ps1 `
  -BundleDirectory /path/to/product-image-candidate `
  -ExpectedSourceCommit <40-character-root-commit> `
  -ReleaseId release-20260806-01 `
  -BackendDestination registry.example/bunkfy/backend:release-20260806-01 `
  -WebDestination registry.example/bunkfy/web:release-20260806-01 `
  -OutputDirectory /evidence/promotions/release-20260806-01 `
  -WhatIf
```

The dry-run verifies the closed candidate, OCI manifests, GitHub attestations,
destination shape, release-tag equality, disjoint paths, and Skopeo
availability. It stops before registry inspection or publication and creates no
registry or evidence output. It therefore does not prove registry login,
write-once policy, existing-tag state, registry reachability, deployment, or
approval. Run the real command only through the approved private release
process after those controls are ready.

## Publish

Both destination tags must exactly equal the release id and use distinct
repositories:

```powershell
./eng/operations/promote-image-candidate.ps1 `
  -BundleDirectory /path/to/product-image-candidate `
  -ExpectedSourceCommit <40-character-root-commit> `
  -ReleaseId release-20260806-01 `
  -BackendDestination registry.example/bunkfy/backend:release-20260806-01 `
  -WebDestination registry.example/bunkfy/web:release-20260806-01 `
  -Confirm:$false
```

The command independently verifies the candidate's GitHub attestations and
closed checksums. Skopeo copies each OCI archive with digest preservation and
then reads the registry digest back. An existing tag is accepted only when it
already resolves to the exact candidate digest, making an interrupted run safe
to resume. A tag pointing anywhere else fails closed. The candidate bundle,
fixture registry, and promotion evidence output must be disjoint paths so the
promotion cannot mutate the admitted input.

The resulting ignored directory contains `promotion.json` and
`checksums.sha256`. The record binds one release id and source commit to both
candidate archive hashes, manifest digests, tagged registry references, and
digest-qualified deployable references. Deploy only the digest-qualified
references.

Verify retained evidence before every later admission or rollback use:

```powershell
./eng/verify-image-promotion.ps1 `
  -PromotionDirectory /path/to/promotion-evidence `
  -ExpectedReleaseId release-20260806-01 `
  -ExpectedSourceCommit <40-character-root-commit>
```

Set the public API, Admin API, and Worker
`BunkFy:Deployment:ReleaseId` to the record's `releaseId`. Set
`PromotionEvidenceReference` to its generated promotion reference and
`RollbackEvidenceReference` to the separately approved rollback or recovery
record. Before startup, also preallocate the attempt-specific
`AdmissionEvidenceReference` described by the
[Production admission runbook](production-admission-evidence.md). The deployed
public-edge and mutable workflow probes must observe that same release and
admission identity.

Before Production admission, use a previously promoted compatible release and
the [deployed release rollback rehearsal](deployed-release-rollback-rehearsal.md)
to prove candidate-to-rollback-to-candidate convergence. The rehearsal consumes
promotion records and digest references; it never rebuilds an image.

## Evidence Boundary

The record is non-secret and closed by a checksum, but the local checksum is
not a signature. Store or sign it through the approved private release system.
The script verifies the bytes visible through the registry API at publication
time; it cannot observe registry tag-policy enforcement, deployment rollout,
private approvals, or rollback execution. Those facts remain separate evidence.

`-AllowUnattested` and `-FixtureRegistryDirectory` exist only together for the
deterministic local test under `registry.fixture.invalid`. They cannot enable an
unattested real registry promotion, and fixture promotion records are rejected
by non-fixture rollback and Production admission verification.
