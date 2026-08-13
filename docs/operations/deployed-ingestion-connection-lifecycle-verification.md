# Deployed Ingestion Connection Lifecycle Verification

Use `eng/operations/verify-deployed-ingestion-connection-lifecycle.ps1` to prove
the operator-controlled connection and credential lifecycle against one exact
deployed release.

The verifier creates one synthetic `RemotePolling` connection from a registered
capability, exercises optimistic and idempotent management behavior, issues one
one-time ingress credential, completes one zero-observation remote run, revokes
that credential, and leaves the connection disabled.

## Preconditions

Prepare an active smoke workspace and property with an already approved
processing policy. The operator needs Ingestion read, connection-management,
and credential-management permissions and must satisfy configured recent-sign-
in assurance. Supply a distinct authenticated account that is not a workspace
member for the fail-closed tenant assertion.

The verifier never activates or rebinds a country policy. Production policy
selection requires approved country, region, transfer, retention, and
acknowledgement evidence outside this synthetic workflow.

## Run

```powershell
./eng/operations/verify-deployed-ingestion-connection-lifecycle.ps1 `
  -PublicOrigin https://candidate.example `
  -ExpectedReleaseId <promotion-record-release-id> `
  -WorkspaceId <workspace-id> `
  -PropertyId <property-id>
```

Supply the two bearer tokens through secure parameters, secure prompts, or the
process-scoped `BUNKFY_SMOKE_INGESTION_LIFECYCLE_OPERATOR_TOKEN` and
`BUNKFY_SMOKE_INGESTION_LIFECYCLE_DENIED_TOKEN` environment variables. Never
put tokens on a command line, in shell history, or in retained evidence.

## Checks

The 32-check probe verifies:

- exact release, active tenant membership, active property, and approved
  processing-policy preflight;
- authenticated nonmember denial on the connection directory;
- dynamic discovery of a registered `RemotePolling` capability;
- connection create, update, secret-reference clear, disable, and enable
  behavior with stable replay, changed-operation rejection, and stale-version
  rejection;
- paged directory, detail, and capability-aware health projections;
- one-time credential issuance without token redisclosure on exact replay;
- independent `BunkFy-Adapter` authentication for a zero-observation lease and
  successful terminal run;
- credential authentication telemetry without optimistic-version churn;
- versioned, replay-stable credential revocation followed by `401` for the old
  token; and
- final disabled connection, revoked credential, successful empty run, health,
  and release identity continuity.

The selected adapter type is discovered, not named by the script. The proof
does not require a provider record and therefore does not duplicate the
deployed AdapterHost data-path verifier.

Only `Ingestion.CountryPolicyDenied.MissingBinding` is treated as bounded
projection convergence during initial connection creation, and the exact same
operation and payload are replayed. Any other policy or business rejection
fails immediately.

## Cleanup And Evidence

Cleanup is authoritative. A partially claimed run is completed as cancelled,
the credential is revoked, and the connection is disabled before any workflow
failure is returned. Passing evidence is impossible unless the run is terminal,
the credential revoked, and the connection disabled.

Passing JSON evidence is written atomically with private permissions. It records
release and transport identity, protocol/schema versions, terminal status and
version relationships, 32 named checks, cleanup disposition, and fixed
limitations. It excludes all workspace, property, connection, credential, run,
lease, worker, claim, and operation identifiers; tokens and headers; adapter and
source names; labels; opaque material references; policy values; checkpoints;
and response bodies.

The disabled connection, revoked credential, and empty successful run remain as
synthetic audit history. Use a dedicated smoke property and let configured
Retention own their eventual lifecycle; do not edit Ingestion projections.

## Preview Composition

Add `-IncludeIngestionConnectionLifecycle` to
`rehearse-preview-onboarding.ps1`. The parent activates its mounted Preview-only
engineering policy, supplies a freshly authenticated owner plus the unjoined
applicant, and later retires the parent property and workspace. The child leaves
only terminal Ingestion history and binds scrubbed evidence into the umbrella.

Loopback Preview evidence proves composition only. It cannot satisfy hosted
production admission or approve a country-policy decision.

## Relationship To AdapterHost

This proof owns connection and credential control behavior. The separate
[deployed AdapterHost verifier](deployed-adapter-host-verification.md) remains
read-only and owns provider record, lease worker, receipt provenance, and
checkpoint proof. Production restart and secret-manager rotation remain a
private candidate-specific operator record.

## Repository Fixture

`eng/test-deployed-ingestion-connection-lifecycle.ps1` runs the verifier against
a deterministic loopback server. It proves the valid terminal path, rejects
credential-token redisclosure on issuance replay while still cleaning up, scans
evidence for scoped and sensitive values, verifies private file mode, and
rejects insecure non-loopback HTTP. It does not contact a deployment or run an
adapter process.
