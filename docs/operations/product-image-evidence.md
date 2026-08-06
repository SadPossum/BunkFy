# Product Image Evidence

This slice adds a candidate-only image gate for BunkFy. It proves what the
current product composition builds without creating a production release
channel.

## Ownership

- BunkFy root owns the composed backend and web candidate, source-set identity,
  image evidence manifest, and workflow policy.
- Backend and Web own their Dockerfiles, digest-pinned frontend, and
  digest-pinned base images.
- GMA owns reusable source composition and release evidence only. Product image
  names, targets, registry choices, and deployment policy do not belong in GMA.
- Private operations will own any future registry, signing policy, deployment
  infrastructure, secrets, network evidence, and promotion approvals.

## Manual Candidate Gate

`Product Image Evidence` is workflow-dispatch only. One invocation:

1. checks out all 13 repositories recursively and records the clean source set;
2. generates the backend's deterministic local GMA source-root maps;
3. builds the backend and web exactly once for `linux/amd64`;
4. exports each build as a local OCI archive;
5. blocks on HIGH and CRITICAL vulnerability, secret, or configuration
   findings;
6. records HIGH and CRITICAL license classifications as non-blocking evidence
   until an approved license policy and allowlist exist;
7. emits a CycloneDX SBOM, SARIF, bounded scan summary, Buildx metadata,
   immutable OCI manifest digest, closed manifest, and SHA-256 checksums;
8. attests and retains the evidence, then normally discards the local OCI
   archives.

The backend image contains API, Worker, Admin API, Admin CLI, and migrations
outputs. Those processes therefore share one exact backend digest. The web has
its own exact digest.

Build caches may reduce repeated work, but a candidate is never rebuilt between
its scans and evidence creation. Docker integration tests are manual or weekly,
so development uses focused tests and one end-of-slice Docker gate.

## Optional Exact-Byte Bundle

An operator can enable `retain_candidate_bytes` for a manual run when the exact
scanned bytes may be promoted later. This default-off option creates a separate,
closed `product-image-candidate-<commit>` artifact containing:

- the backend and web OCI archives already built and scanned by that run;
- the complete closed evidence directory;
- a bundle manifest binding each archive SHA-256 to its recorded OCI manifest
  digest and source commit; and
- root checksums covered by a separate GitHub artifact attestation.

The packager streams archive metadata, rejects links and unsafe paths, and
requires the recorded manifest blob to match both its descriptor size and
digest. It does not rebuild either image.

The workflow independently runs the read-only verifier before attestation and
upload. After downloading and extracting a candidate artifact, a promotion
operator must run the same verifier with the reviewed root commit:

```powershell
./eng/verify-image-candidate.ps1 `
  -BundleDirectory /path/to/product-image-candidate `
  -ExpectedSourceCommit <40-character-root-commit>
```

This consumer command requires a current authenticated GitHub CLI with
attestation verification support.

The verifier closes the outer bundle and nested evidence checksums, rejects
extra files, directories, links, unsupported manifest properties, or a source
identity mismatch, and revalidates each archive's OCI descriptor, manifest
size, and digest. By default it also uses GitHub CLI to require SLSA provenance
from this repository's `image-evidence.yml` workflow, the expected source and
signer commit, and a GitHub-hosted runner for the bundle manifest, nested
evidence checksums, and both archives. The producer workflow uses the explicit
`-AllowUnattested` switch only for its structural preflight before creating
that attestation. A promotion operator must not use that switch. The verifier
does not publish, load, or deploy an image.

Candidate bytes are short-lived because the uncompressed archives consume
substantially more artifact storage than evidence alone. The dispatch form
allows 1, 3, 7, 14, or 30 days and defaults to 7 days for an opt-in run. The
artifact upload uses `compression-level: 0` because OCI tar archives
are binary build output; the ordinary evidence artifact remains retained for
30 days.

This bundle is a promotion input, not a release. It has no registry reference,
deployable reference, environment, or approval, and expiry does not alter the
longer-lived evidence record.

## Deliberate Limits

- No registry login, registry write permission, or image push exists.
- No registry reference is written to the evidence manifest.
- No deployment or environment promotion occurs.
- No hosted-production declaration is generated.
- No OCI archive is uploaded unless an operator explicitly enables the
  short-lived exact-byte bundle for that manual run.
- No legal conclusion is inferred from Trivy license risk classes; license
  enforcement requires an approved project policy and allowlist.
- No image-security exception path exists yet; blocking findings must be fixed
  before this gate can pass.

An approved release channel must later publish the already-gated bytes,
associate the registry digest and attestations with that immutable artifact,
and prove private infrastructure and rollout controls. Until then, a successful
candidate gate is build and scan evidence, not launch approval.
