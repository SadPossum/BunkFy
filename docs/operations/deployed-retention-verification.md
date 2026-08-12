# Deployed Retention Verification

Use this read-only probe to verify that the deployed Retention control plane is
projecting the expected BunkFy catalogue and that the real scheduler completes
a fresh owner-backed occurrence.

The verifier does not enqueue a task, invoke an Admin retry, seed expired data,
read owner records, or inspect a database. It observes only the tenant-scoped
public Retention contract.

## Preconditions

Use a dedicated active smoke workspace with the current Retention catalogue,
no legal holds, and no intentionally retained backlog. The workspace should
have existed for at least eight hours so both current Ingestion schedules have
completed at least once. The reader account needs `retention.read` in that
workspace and no access to an unrelated workspace.

The deployed Worker must compose Retention, Ingestion, and TaskRuntime with
scheduling and execution enabled. Production maintenance-owner admission,
replica count, alert routing, and policy approval remain private deployment
inputs; this public probe cannot infer them from a healthy response.

## Run

```powershell
./eng/operations/verify-deployed-retention.ps1 `
  -PublicOrigin https://candidate.example `
  -ExpectedReleaseId <promotion-record-release-id> `
  -WorkspaceId <workspace-id>
```

Provide the reader bearer token through a secure parameter, secure prompt, or
the process-scoped `BUNKFY_SMOKE_RETENTION_READER_TOKEN` environment variable.
Do not place it on the command line.

The probe baselines `raw-source-evidence`, sleeps until its server-reported due
window, and then polls at a bounded 30-second interval. Its default 75-minute
cycle timeout covers the current hourly schedule without continuous requests.
Increase the timeout only when the reviewed deployment policy justifies it.

For a harness that captures a trusted timestamp before creating a fresh smoke
workspace, `-CompletionNotBeforeUtc` switches the observation to first-run
mode. The verifier waits for the catalogue and requires every expected schedule
to complete after that lower bound. It does not accept a prior completion or
silently fall back to the next-cycle claim. Ordinary standalone use should omit
the parameter and retain the baseline-to-next-occurrence behavior above.

## Checks

The probe verifies:

- public `/api/smoke` reports the expected release before and after the observation;
- the versioned `ingestion/raw-source-evidence` and
  `ingestion/sensitive-reservation-history` tenant schedules are unique;
- the same credential receives `403` for a random workspace scope;
- a new hourly occurrence, or one already running at baseline, completes after
  the baseline;
- every returned schedule is terminal, non-overdue, failure-free, and has
  bounded PII-minimized coordinates, counts, outcome code, and timestamps;
- both current Ingestion owners complete with zero remaining backlog and within
  their expected two-hour and eight-hour freshness windows; and
- the full catalogue summary exactly reports every schedule as healthy.

The catalogue read is capped at 100 pages of 100 schedules. A summary change
while paging fails closed rather than combining inconsistent snapshots.

## Evidence And Failure

Passing JSON evidence is written atomically under `.tmp/deployment-probes` by
default. It includes the public origin, release identity, workspace id, observed
data class, catalogue count, the two expected schedule coordinates, run ids,
timestamps, bounded counts, outcome codes, seven checks, explicit limitations,
and a schema-v2 observation record. The observation identifies whether the
proof advanced beyond a baseline or satisfied a supplied lower bound, including
the baseline run identity and bounded clock-skew allowance.

It excludes the bearer token, request headers, owner records, property
coordinates from future schedules, payloads, legal-hold details, and response
bodies. On timeout, backlog, stale state, or isolation failure it writes no
passing evidence and performs no repair. Never edit Retention, TaskRuntime, or
owner-module projections to make the probe pass.

## Deployment-Owned Evidence

Before real tenant data, retain the reviewed Retention and durable-runtime
policies, the exact release/image identity, the single maintenance-owner
topology, cleanup and oldest-backlog metrics, alert ownership, and one Worker
failure/recovery drill. Separately prove owner-local deletion or redaction with
approved synthetic expired data and object-store evidence where applicable.

This verifier does not prove generic TaskRuntime leases or restart recovery,
which remain GMA's runtime responsibility, and it does not exercise legal
holds, Admin retry, object deletion, backup/restore, or alert delivery.

## Repository Fixture

`eng/test-deployed-retention.ps1` uses a deterministic loopback server. It
proves default next-occurrence and first-completion modes, stale-completion and
missing-catalogue rejection, evidence redaction, cross-workspace denial,
backlog rejection, and rejection of insecure non-loopback HTTP. It does not
start a Worker or contact a deployment.
