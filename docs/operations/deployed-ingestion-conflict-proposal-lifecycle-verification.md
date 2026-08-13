# Deployed Ingestion Conflict And Proposal Lifecycle Verification

Use
`eng/operations/verify-deployed-ingestion-conflict-proposal-lifecycle.ps1`
to prove reservation authority and operator proposal behavior against one exact
deployed release.

The verifier creates a synthetic push connection and reservation. Adapter
changes apply automatically while the accepted adapter baseline is current. A
staff edit then takes authority, so later adapter observations become proposals
instead of overwriting staff state. A still-newer observation must supersede the
older pending proposal and leave only the newest suggestion actionable.

## Preconditions

Prepare an active smoke workspace, an active property with approved processing,
and one sellable Inventory unit for an unused future date range. The operator
needs Ingestion proposal and connection management plus Reservation mutation
permissions. Supply a distinct authenticated account that is not a workspace
member for the tenant-denial assertion.

The verifier discovers a registered push-capable adapter type. It does not
activate or rebind a country policy, name a provider, or require production
provider credentials.

## Run

```powershell
./eng/operations/verify-deployed-ingestion-conflict-proposal-lifecycle.ps1 `
  -PublicOrigin https://candidate.example `
  -ExpectedReleaseId <promotion-record-release-id> `
  -WorkspaceId <workspace-id> `
  -PropertyId <property-id> `
  -InventoryUnitId <inventory-unit-id> `
  -Arrival 2027-10-20 `
  -Departure 2027-10-22
```

Supply bearer tokens through secure parameters, secure prompts, or the
process-scoped `BUNKFY_SMOKE_INGESTION_PROPOSAL_OPERATOR_TOKEN` and
`BUNKFY_SMOKE_INGESTION_PROPOSAL_DENIED_TOKEN` environment variables. Never put
tokens on a command line, in shell history, or in retained evidence.

## Checks

The 26-check proof covers:

- exact release, active tenant/property processing, and nonmember denial;
- push capability discovery, one-time credential issuance, and independent
  adapter authentication;
- automatic adapter create and update while the adapter baseline is current;
- staff authority followed by a non-destructive pending proposal;
- terminal supersession of an older proposal by newer ordered source input;
- rejection and acceptance with exact replay and changed-request conflicts;
- Reservation convergence and four-step Adapter, Adapter, Staff, Adapter
  details-history provenance;
- duplicate and stale source input without extra actionable work; and
- adapter cancellation, credential revocation, connection disablement, and
  release identity continuity.

All polling is bounded. Only the documented country-policy projection miss is
retried during connection creation; any other authorization, ordering,
business, or cleanup failure is returned.

## Cleanup And Evidence

Cleanup is authoritative. Pending proposals are rejected, the synthetic
reservation is cancelled, the credential is revoked, and the connection is
disabled before a workflow error is rethrown. Passing evidence requires exactly
one superseded, one rejected, one applied, and zero pending proposals.

Evidence kind
`bunkfy-deployed-ingestion-conflict-proposal-lifecycle-probe`, schema version 1,
is written atomically with private permissions. It retains only release and
transport identity, adapter contract versions, the integer authority-revision
chain, terminal proposal counts, named checks, cleanup dispositions, and fixed
limitations. It excludes all tenant and domain identifiers, tokens, headers,
guest data, source records, adapter names, policy values, and response bodies.

## Preview Composition

Add `-IncludeIngestionConflictProposalLifecycle` to
`rehearse-preview-onboarding.ps1`. The parent enables its mounted Preview-only
engineering policy, provisions and later retires a dedicated sellable room, and
binds the scrubbed child evidence into the umbrella. The child owns its
reservation, proposal, credential, and connection cleanup.

Loopback Preview evidence proves composition only. It cannot satisfy hosted
production admission or approve a country-policy or provider-credential
decision.

## Related Proofs

The [connection lifecycle verifier](deployed-ingestion-connection-lifecycle-verification.md)
owns control-plane and credential lifecycle. The
[AdapterHost verifier](deployed-adapter-host-verification.md) owns a real adapter
process, lease, receipt provenance, and checkpoint behavior. This verifier owns
the reservation authority and proposal-decision path.

## Repository Fixture

`eng/test-deployed-ingestion-conflict-proposal-lifecycle.ps1` runs the verifier
against a deterministic loopback server. It proves the valid path, rejects a
fixture that leaves the older proposal pending while still requiring terminal
cleanup, scans evidence for scoped and sensitive values, verifies private file
mode, and rejects insecure non-loopback HTTP.
