# Production Admission Attempt Identity Task

Status: repository candidate evidence complete; hosted admission remains
Date: 2026-08-22

## Goal

Prevent deployed proof from separate admission attempts from being combined
solely because it reports the same release id and public origin.

## Finding

At discovery, Production hosts already required a preallocated
`BunkFy:Deployment:AdmissionEvidenceReference`, and the final admission bundle
retained that identity, but the public smoke surface and deployed evidence
records did not expose or bind it. A later attempt for the same release and
origin could therefore reuse otherwise valid proof produced under an earlier
attempt.

## Boundary

- BunkFy owns this deployment and evidence contract. It does not belong in a
  business module or GMA.
- The Public API may expose the admission reference because the existing
  contract defines it as a non-secret correlation identity, never as authority.
- Every mutable deployed proof, including the rollback rehearsal, must observe
  one stable admission reference before and after its workflow.
- Ordinary local or Preview smoke may report no admission reference, but such
  evidence must be rejected by Production admission.
- Image promotion and isolated migration evidence remain reusable immutable
  candidate proof and do not bind an individual deployment attempt.
- Worker and Admin API configuration equality remains part of the private
  runtime-topology record; this public proof binds the candidate deployment
  observed through the Public API.

## Delivery

1. [x] Add the configured admission reference to the closed `/api/smoke`
   deployment identity.
2. [x] Make shared public-edge parsing validate release and admission identities
   without weakening existing Preview behavior.
3. [x] Revise every deployed evidence schema and rollback rehearsal to retain
   the observed admission reference and reject identity changes in flight.
4. [x] Require the final assembler to match every mutable proof and the
   standalone verifier to match the closed bundle to the preallocated admission
   reference.
5. [x] Add focused fixture coverage for missing, malformed, changed, and
   cross-attempt identities, then align operator documentation and guards.
6. [x] Run one consolidated end-of-slice repository gate.
7. [x] Publish exact backend and root commits, then refresh candidate evidence.

## Repository Verification

- `pwsh ./eng/verify.ps1 -SkipRestore` passed on 2026-08-23 after the focused
  smoke-contract correction. This covered operations fixtures, migration drift,
  all non-Docker .NET tests, web lint/typecheck/tests, and the Production build.
- Backend commit `e564a94176e8d060435897c72427b6359ca38213` is published on
  `BunkFy.Backend/dev`.
- This is repository candidate evidence only. A real hosted admission attempt
  remains pending.

## Candidate Closure Evidence

- Exact backend `e564a94176e8d060435897c72427b6359ca38213` passed Validate
  `32611716738`, Security Baseline `32611716690`, Docker Tests `32611804113`
  (160/160 in 13 minutes 56 seconds), and Release Evidence `32611804097`.
  Release artifact `9485735495` is retained through 2026-11-21.
- Exact product source `b1370f41ba77dd2cac5c7b990dba342ca129cd4a`
  passed Validate `32611776402`, Security Baseline `32611776353`, CodeQL
  `32611776355` for C# and JavaScript/TypeScript, Release Evidence
  `32611803893`, and Product Image Evidence `32611803898`. Release artifact
  `9485737414` and product-image evidence artifact `9485805838` are retained
  through 2026-11-21 and 2026-09-22 respectively.
- Exact candidate artifact `9485805557` has artifact digest
  `sha256:dd62d616448553c8d9de356ac7fffa4f79149aa9e58a9b66da59b1b304a29719`
  and is retained through 2026-09-06. Its closed checksum-set digest is
  `4195d5a6f08657740326c1581e920258ecfeb4693849fffcc82b6114350fff2e`.
- Independent verification accepted the closed bundle, OCI descriptors and
  GitHub attestations. The backend archive is
  `b5d3fff0c59e4d214d5304a12e72c5e560e1771e402ca34bc05c83490ac12fd7`
  at manifest `sha256:1c672ed62748dbc917d42d36f20cd86d6298ffde165d831400a2cacd135fdf0c`;
  the web archive is
  `a3c3cf3482f0dde887819c82d3d7d29972bf99b0eb5fbf933ac220c42f3a9502`
  at manifest `sha256:da3688abfb3650ead8706ada2c92593c904121c3df597c650707e0b33eb84b18`.
  Both scans reported zero vulnerability, misconfiguration, secret, or
  blocking findings; HIGH classifications were license inventory only.
- Migration rehearsal `a402171ec721` planned 15 modules and 250 migrations
  without mutation, rejected malformed and wrong-target approvals, applied all
  250, converged to zero pending, and repeated idempotently. Evidence
  `.tmp/migration-rehearsals/20260823T021132Z-candidate-b1370f41ba77-071037f1.json`
  has SHA-256
  `fbebfff47c052117be849827748804c2c8ac3b3d4c1abd80c0da21f26f9fa833`.
- Runtime release
  `candidate-b1370f41ba77dd2cac5c7b990dba342ca129cd4a` passed exact image
  binding, expected service states, six public-edge checks, and management
  isolation. Evidence
  `.tmp/candidate-runtime-rehearsals/20260823T021253Z-candidate-b1370f41ba77-b32bedf4.json`
  has SHA-256
  `a0c1405e4a02f80b24babcfdfd43dc14a1c1ad76fc2b5f4efd0a53e635c05bb5`.
- Independent cleanup found no candidate container, network, volume, imported
  tag, generated environment, working directory, or dirty repository state.
  The candidate remains unpublished.

## Verification Cadence

Use the focused public-edge, deployed-verifier, Production-admission, Service
Defaults, and Architecture tests while editing. Do not run Docker or broad
GitHub evidence workflows per change. Run one consolidated local gate at the
end of the slice, then decide the exact replacement-candidate evidence required
by the changed Public API bytes.

## Deferred

- A real hosted admission attempt and its private approval records.
- Independent inspection of Worker and Admin API runtime configuration.
- Temporal freshness and standalone summary cross-binding hardening, which is
  the next admission-boundary slice after attempt identity is closed.
