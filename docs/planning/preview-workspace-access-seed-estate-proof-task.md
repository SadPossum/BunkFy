# Preview Workspace Access Seed Estate Proof Task

Status: completed for the Preview deployment estate
Date: 2026-08-12

## Goal

Provide a bounded, repeatable deployment operator that proves every active
Preview workspace is converged on the current BunkFy workspace-access seed
version and can explicitly repair stale seed definitions without inferring
tenants from module storage.

## Boundary

- GMA Organizations owns the authorized, paged organization catalog.
- BunkFy Workspaces owns seed definitions, drift detection, tenant-scoped
  status, and idempotent bootstrap behavior.
- The product root owns deployment enumeration, exact-release admission,
  explicit mutation consent, bounded execution, and minimized evidence.
- The operator must use the composed Admin CLI contracts. It must not query
  PostgreSQL, infer tenant identifiers from storage, or couple either module to
  the other module's implementation.
- GMA changes are limited to preserving its existing paged Organizations
  response envelope in JSON; deployment orchestration and all BunkFy seed
  semantics remain outside GMA.

## Current Finding

The live Preview catalog currently contains 81 workspaces: 3 active and 78
archived. All three active workspaces report seed version 4 with four active
seeds, but each has one drifted seed and `requiresBackfill=true`.

## Implementation

1. Add a Preview operator that verifies the public exact release before any
   tenant work and resolves the tracked Compose/Admin CLI boundary.
2. Walk the authorized organization catalog with a fixed page size and hard
   page/workspace bounds. Select only active workspaces and reject unknown or
   duplicate catalog entries.
3. Inspect every active workspace through `workspaces access status`.
   Status-only execution must make no writes and fail the proof when any
   workspace is not converged.
4. Require an explicit apply switch plus PowerShell confirmation semantics
   before invoking `workspaces access bootstrap --yes`. Bootstrap only
   non-converged active workspaces, then re-read every active workspace.
5. Require seed version 4, four expected and active seeds, zero drifted or
   archived seeds, zero legacy members, nondecreasing membership-marker
   coverage, and `requiresBackfill=false` after convergence.
6. Retain private, atomic JSON evidence containing only release identity,
   image identity, aggregate counts, stable workspace fingerprints, before and
   after status summaries, and command outcomes. Never retain names, slugs,
   tenant ids, organization ids, credentials, or raw CLI output.
7. Add focused fixture/static guards and wire them into the operations suite.

GMA Organizations and BunkFy Workspaces must emit their existing paged and
single-result contracts as typed JSON respectively. Human-readable table output
remains unchanged.

## Safety And Failure Semantics

- Use noninteractive Admin CLI containers with `--rm --no-deps -T` so paged
  input cannot be consumed and transient containers do not remain.
- A catalog truncation, duplicate scope, malformed JSON, CLI failure, release
  mismatch, partial bootstrap, or incomplete final convergence fails closed.
- Evidence records failure without serializing raw command output or tenant
  identity. Existing evidence is not overwritten unless explicitly requested.
- An empty active estate is reported distinctly and does not count as proof of
  a populated deployment.

## Verification Cadence

Use PowerShell syntax and focused fixture guards while editing. Run the full
operations suite once when the slice is coherent, then run one exact-release
Preview estate rehearsal with explicit apply consent. Re-run only the focused
rehearsal while correcting failures.

## Deferred

- A hosted scheduler or fleet-wide multi-deployment orchestrator.
- Automatic bootstrap during application startup.
- The first hosted estate execution and private approval record now required by
  production admission.
- Any product-domain work outside Workspace Access.

## Outcome

The exact-release rehearsal
`preview-workspace-access-estate-651107f` completed on 2026-08-12. The
authorized Organizations catalog contained 81 workspaces: 3 active and 78
archived. All three active workspaces started on seed version 4 with four
active profiles and one drifted profile; the operator bootstrapped each one
without migrating legacy members, then reread all three as fully converged.
The catalog fingerprint remained stable throughout the run.

The deployed API and transient Admin CLI resolved to the same backend image,
all transient containers were removed, and the public web and API retained the
expected release identity. The passing private evidence is stored locally at
`.tmp/deployment-probes/preview-workspace-access-estate-651107f-passed.json`
with mode `0600` and SHA-256
`33dea3decd98fa95708a08e74e272e75efe83c9c39f6e8fd71158bc45f115edd`.
It contains only aggregate state and one-way workspace fingerprints; an audit
found no tenant ids, names, slugs, UUID values, credentials, or raw CLI output.

The full operations gate passed once before the live rehearsal. A focused
fixture subsequently caught and closed a PowerShell process-result leak before
tenant mutation; it now proves a single closed result object and prompt child
termination on timeout. Hosted fleet orchestration and production classes
beyond Preview remain deferred rather than implied by this evidence.

The follow-up production-admission slice now requires a distinct private
hosted Workspace Access estate reference. This Preview evidence remains
deliberately ineligible to satisfy that control.
