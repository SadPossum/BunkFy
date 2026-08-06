# Deployed AdapterHost Verification

Use this read-only probe to verify that a target deployed AdapterHost can claim
a server lease, ingest one deliberately seeded synthetic provider record, and
advance the Ingestion module's durable checkpoint.

The verifier never impersonates an adapter, submits an observation, reads a raw
payload, or changes connection state. The operator remains responsible for
placing one valid non-PII record in the real provider boundary after the probe
has captured its baseline.

## Preconditions

Prepare an enabled `RemotePolling` connection whose adapter capability is
available. Use a dedicated smoke property and an operator account that can read
the connection, health, run, and receipt views. Record the exact AdapterHost
worker id from the candidate's protected runtime configuration.

Choose a unique synthetic external id and compute its lowercase SHA-256 without
placing either value in retained evidence:

```powershell
$externalId = Read-Host 'Synthetic external id'
$externalIdSha256 = [Convert]::ToHexString(
  [Security.Cryptography.SHA256]::HashData(
    [Text.UTF8Encoding]::new($false).GetBytes($externalId))).ToLowerInvariant()
```

The source record must be valid for the configured adapter and safe to retain
under the deployment's smoke-data policy. Do not use guest, staff, credential,
or production booking data.

## Run

Run the verifier first. When it prints that it is waiting for the deployed
AdapterHost, place the synthetic record in the actual provider boundary. A run
already in progress at baseline is eligible; a run that finished before the
baseline is deliberately not accepted as current deployment proof.

```powershell
./eng/operations/verify-deployed-adapter-host.ps1 `
  -PublicOrigin https://candidate.example `
  -ExpectedReleaseId <promotion-record-release-id> `
  -AdapterHostOrigin http://127.0.0.1:8091 `
  -WorkspaceId <workspace-id> `
  -PropertyId <property-id> `
  -ConnectionId <connection-id> `
  -ExpectedAdapterType <adapter-type> `
  -ExpectedWorkerId <worker-id> `
  -ExpectedExternalIdSha256 $externalIdSha256 `
  -ExpectedSourceRecordType <source-record-type> `
  -StatusEndpointExposure LoopbackOnly
```

Supply the bearer token through a secure parameter, secure prompt, or the
process-scoped `BUNKFY_SMOKE_INGESTION_OPERATOR_TOKEN` environment variable.
Do not put it on the command line.

For `LoopbackOnly`, run on the AdapterHost machine and use a loopback
`AdapterHostOrigin`. For `Disabled`, `/status` must return `404`; health may be
reached through loopback HTTP or an internal HTTPS origin. Never expose the
AdapterHost or its status endpoint through BunkFy's public edge.

## Checks

The probe verifies:

- public `/api/smoke` reports the expected release before and after the cycle;
- liveness, readiness, and the admitted status-exposure mode;
- an enabled, available `RemotePolling` connection with known protocol and
  configuration-schema versions;
- a new or baseline-running terminal run that accepted the expected synthetic
  source identity;
- remote lease, claim, epoch, worker, timing, and observation-count proof;
- a processed receipt with durable operation, raw-evidence, credential,
  adapter-version, content-hash, and source-type provenance;
- advancement of the server-owned connection checkpoint; and
- converged connection and AdapterHost health after the cycle.

Polling is bounded and only the newest 100 runs plus at most 100 pages of the
target run's receipts are inspected. The external id is compared in memory by
SHA-256 and is not written to evidence.

## Evidence And Failure

Passing JSON evidence is written atomically under `.tmp/deployment-probes` by
default. It records deployment and runtime identifiers, bounded run and receipt
metadata, eight check results, and explicit limitations. It excludes bearer
tokens, external ids and hashes, checkpoints, runtime material references, raw
payload content, response bodies, and headers.

The probe is observational. On timeout or mismatch it writes no passing
evidence and performs no repair. Inspect the AdapterHost admission log,
connection health, lease state, and provider-side synthetic record before
retrying; do not edit Ingestion projections directly.

## Restart And Credential Rotation Rehearsal

Repository automation cannot truthfully prove orchestrator admission, secret
rotation, or process replacement. For the exact candidate, retain a private
operator record of this sequence:

1. Run the probe successfully with synthetic record A and retain its evidence.
2. Rotate the adapter ingress credential through the approved API or Admin
   workflow and update the candidate's secret source atomically.
3. Stop the old AdapterHost gracefully. Confirm its lease completes or expires,
   then start the replacement from the exact promoted candidate.
4. Confirm the replacement's Production admission log, readiness, expected
   worker identity, and absence of concurrent old-worker execution.
5. Run the probe again with unique synthetic record B. Privately compare the
   replacement run, receipt, worker, and checkpoint progression.
6. Revoke the old credential and confirm the retired process cannot claim a
   lease or advance the checkpoint.

Keep credentials, source identities, checkpoints, payloads, and raw logs out of
repository evidence. Promotion requires both probe results and the private
candidate-specific restart record.

## Repository Fixture

`eng/test-deployed-adapter-host.ps1` exercises loopback-only and disabled status
modes against a deterministic server. It also proves evidence redaction,
wrong-worker and rejected-receipt rejection, enforcement of loopback-only
status, and rejection of insecure non-loopback HTTP. It does not start
AdapterHost, contact a provider, or contact a deployed environment.
