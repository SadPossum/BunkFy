# Production Image Promotion Boundary Task

Status: implemented and verified
Date: 2026-08-11

## Goal

Keep local image-promotion rehearsal evidence structurally distinct from a
hosted registry promotion so it cannot satisfy rollback or Production admission
by accident.

## Finding

Candidate packaging and attestation were closed correctly, but the shared
promotion parser accepted `localhost`, loopback IP addresses, and
`registry.fixture.invalid` when the record claimed attested candidate bytes.
That allowed a locally reachable registry reference to cross the non-fixture
admission boundary.

## Boundary

- This belongs to BunkFy's deployment evidence tooling, not a business module
  or GMA.
- Keep the deterministic fixture registry available only under the existing
  explicit fixture switches.
- Reject local and reserved fixture registries before Skopeo is invoked and
  whenever promotion evidence is consumed without fixture authorization.
- Preserve support for private hosted registries and registry-neutral release
  references.
- Do not claim that a passing fixture proves hosted registry policy, promotion,
  deployment, or rollback.

## Delivery

- [x] Reject fixture and loopback destinations in hosted promotion.
- [x] Reject fixture and loopback promotion records in hosted verification.
- [x] Cover attested fixture records, loopback records, and Production admission.
- [x] Document the hosted/fixture registry boundary.
- [x] Run focused promotion and Production admission verification.
- [x] Rehearse the current exact candidate through the fixture promotion path.
- [x] Run one consolidated end-of-slice verification gate.
- [x] Commit, push, and retain exact hosted CI evidence.

## Verification Evidence

- The OCI candidate and Production admission fixture suites pass the hosted
  destination and consumer-side rejection cases.
- `eng/check-product-image-evidence.ps1` passes the closed candidate,
  attestation, promotion, and publication-disabled policy guards.
- Candidate `c9b49a4d286f42443d1edc66a2650a98b10accea` was independently verified from
  retained workflow run `31539264726` and rehearsed through the explicit
  `registry.fixture.invalid` path. Both OCI archive hashes and manifest digests
  were preserved.
- Rehearsal promotion `promotion:103790e6674f4436b51dd81a600735a5` is ignored
  local fixture evidence. It reports unattested fixture processing,
  `deployment-not-observed`, and `rollback-not-executed`; it is not Production
  evidence.
- `eng/verify.ps1 -SkipRestore` passed synchronized solutions, all operations
  fixtures, a zero-warning build, every migration drift check, all selected GMA
  and BunkFy tests, 60 integration tests, 267 web tests, lint, typecheck, and the
  production web build. Docker-only tests were intentionally not repeated for
  this PowerShell evidence-boundary slice.

## Done When

- source attestations cannot turn a fixture registry reference into hosted
  promotion evidence;
- non-fixture rollback and admission consumers fail closed on local references;
- the explicit fixture workflow remains deterministic and idempotent; and
- the repository gate proves the boundary without claiming hosted deployment.
