# Preview Workspace Access Seed Estate

Use `eng/operations/rehearse-preview-workspace-access-estate.ps1` after a
Preview deployment to prove that every active workspace is using the current
BunkFy workspace-access seed definitions.

The operator composes two existing ownership boundaries:

- GMA Organizations supplies the authorized, paged workspace catalog.
- BunkFy Workspaces supplies tenant-scoped seed status and idempotent
  bootstrap commands.

The root operator does not query module storage or infer tenants. It runs the
private, transient Admin CLI service from the tracked Preview Compose file and
requires that image to match the running public API image.

## Inspect

Status-only mode makes no workspace changes. It writes failure evidence and
returns a failure when any active workspace requires bootstrap.

```powershell
./eng/operations/rehearse-preview-workspace-access-estate.ps1 `
  -PublicOrigin https://preview.example.com `
  -ExpectedReleaseId preview-release-id `
  -EnvironmentPath /private/path/bunkfy-preview.env
```

## Converge

Apply mode bootstraps only non-converged active workspaces, re-reads every
active workspace, and verifies that the authorized catalog remained stable.
It requires both the explicit switch and PowerShell confirmation semantics.

```powershell
./eng/operations/rehearse-preview-workspace-access-estate.ps1 `
  -PublicOrigin https://preview.example.com `
  -ExpectedReleaseId preview-release-id `
  -EnvironmentPath /private/path/bunkfy-preview.env `
  -Apply `
  -Confirm:$false
```

Use `-WhatIf` with `-Apply` to inspect the mutation boundary without network,
Docker, or evidence-file side effects.

## Evidence

Evidence is written atomically to a private file under
`.tmp/deployment-probes` unless `-OutputPath` is supplied. It contains:

- exact public release and matching backend image identity;
- bounded catalog counts and a stable catalog fingerprint;
- per-workspace SHA-256 fingerprints and before/after seed summaries;
- whether bootstrap was requested and performed; and
- transient Admin CLI cleanup and invocation counts.

It does not retain workspace names, slugs, tenant or organization ids, raw CLI
output, credentials, or environment contents. Existing evidence is not
overwritten without `-Force`.

This is Preview deployment evidence, not a hosted fleet scheduler or a
substitute for production change approval.
