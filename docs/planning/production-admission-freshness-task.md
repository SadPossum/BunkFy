# Production Admission Freshness And Cross-Binding Task

Status: implementation verified; publication pending
Date: 2026-08-23

## Goal

Prevent a structurally valid Production admission bundle from admitting stale
deployment observations or internally inconsistent source summaries when it is
verified independently of the assembler.

## Findings

- Promotion and migration evidence are immutable candidate proof and may be
  reused, but deployed probes and rollback rehearsal evidence describe mutable
  runtime state and currently have no maximum age.
- The closed bundle has no expiry, so private approval can occur after its
  runtime observations have become stale.
- The assembler checks repository parity, unique private references, and source
  identities, but the standalone verifier does not yet reproduce every one of
  those invariants.
- Source evidence summaries retain hashes but not their evidence references,
  leaving weaker internal cross-binding than the source records provide.

## Boundary

- This is BunkFy release and operations policy. It does not belong in GMA or a
  business module.
- Image promotion and migration rehearsal evidence remain reusable and are not
  rejected only because of age.
- Deployed probes and the rollback rehearsal must be no more than 24 hours old.
  A longer attempt starts again with a new admission identity and fresh mutable
  proof.
- A closed bundle is approvable for at most four hours and never beyond the
  24-hour lifetime of its oldest mutable source.
- Five minutes of positive clock skew remains tolerated, but the limitation that
  source clocks are not independently attested must stay explicit.
- Freshness limits are fixed by the verifier. A bundle cannot enlarge its own
  acceptance window.

## Delivery

1. [x] Centralize the fixed freshness policy and timestamp-window validation.
2. [x] Reject stale deployed probes and stale rollback rehearsals at assembly.
3. [x] Add bounded validity metadata and source evidence references to admission
   schema v2.
4. [x] Make the standalone verifier recalculate freshness, expiry, repository
   parity, source-reference/checksum bindings, and private-reference uniqueness.
5. [x] Add focused fixtures for stale and future proof, expired bundles,
   malformed ordering, repository drift, summary drift, and duplicate private
   references.
6. [x] Align operator documentation, script guards, and workspace solutions.
7. [x] Run one consolidated end-of-slice repository gate.
8. [ ] Publish the exact root commit and observe its required checks.

## Repository Verification

- `pwsh ./eng/verify-operations.ps1` passed every operations guard and deployed
  workflow fixture, including the expanded Production admission fixture.
- `pwsh ./eng/verify.ps1 -SkipRestore` passed on 2026-08-23. It covered solution
  and submodule guards, operations fixtures, a zero-warning build, migration
  drift, all non-Docker .NET tests, web lint/typecheck, 59 Vitest files with 304
  tests, and the Production web build.
- No Docker suite or remote evidence workflow was run during implementation.
  Publication checks are intentionally deferred to the exact slice commit.

## Verification Cadence

Use the focused Production admission fixture, PowerShell syntax guard, and
solution synchronization check while editing. Do not run Docker or GitHub
evidence workflows per change. Run the consolidated repository gate once after
the slice is coherent.

## Deferred

- Cryptographic signing or private release-system authentication.
- Independent attestation of probe-runner clocks.
- Hosted admission, promotion, approval, and production-traffic evidence.
