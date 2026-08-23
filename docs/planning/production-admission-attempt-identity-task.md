# Production Admission Attempt Identity Task

Status: in progress
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
7. [ ] Publish exact backend and root commits, then refresh candidate evidence.

## Repository Verification

- `pwsh ./eng/verify.ps1 -SkipRestore` passed on 2026-08-23 after the focused
  smoke-contract correction. This covered operations fixtures, migration drift,
  all non-Docker .NET tests, web lint/typecheck/tests, and the Production build.
- Backend commit `e564a94176e8d060435897c72427b6359ca38213` is published on
  `BunkFy.Backend/dev`.
- This is repository evidence only. A replacement exact-source candidate and
  real hosted admission attempt remain pending.

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
