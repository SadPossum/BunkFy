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
8. attests and retains the evidence, then discards the local OCI archives.

The backend image contains API, Worker, Admin API, Admin CLI, and migrations
outputs. Those processes therefore share one exact backend digest. The web has
its own exact digest.

Build caches may reduce repeated work, but a candidate is never rebuilt between
its scans and evidence creation. Docker integration tests are manual or weekly,
so development uses focused tests and one end-of-slice Docker gate.

## Deliberate Limits

- No registry login, registry write permission, or image push exists.
- No registry reference is written to the evidence manifest.
- No deployment or environment promotion occurs.
- No hosted-production declaration is generated.
- No OCI archive is uploaded as a large workflow artifact.
- No legal conclusion is inferred from Trivy license risk classes; license
  enforcement requires an approved project policy and allowlist.
- No image-security exception path exists yet; blocking findings must be fixed
  before this gate can pass.

An approved release channel must later publish the already-gated bytes,
associate the registry digest and attestations with that immutable artifact,
and prove private infrastructure and rollout controls. Until then, a successful
candidate gate is build and scan evidence, not launch approval.
