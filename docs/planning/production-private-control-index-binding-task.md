# Production Private Control Index Binding Task

Status: repository slice complete; private hosted controls remain external
Date: 2026-08-23

## Goal

Prevent stale or unrelated private Production records from being attached to a
new BunkFy release solely because each record has a syntactically valid opaque
reference.

The private release system must export one minimized, closed control index for
the preallocated admission attempt. Production admission verifies and retains
that index without importing provider details, credentials, tenant data, raw
logs, or the private records themselves.

## Boundary

- This is a BunkFy deployment-evidence contract. It does not belong in GMA or a
  business module.
- The index binds private records; it does not authenticate their contents or
  replace private signatures, reviewers, or approval.
- The public repository may retain only bounded control names, opaque evidence
  references, nonzero SHA-256 values, UTC timestamps, candidate identities,
  and the admission-attempt identity.
- Hosted backup implementation, cloud topology, RPO/RTO values, addresses,
  account ids, key ids, and operator identities remain private.

## Invariants

1. One closed index contains exactly the five required private controls:
   browser onboarding, hosted recovery, deployment control, runtime operations,
   and the Workspace Access seed estate.
2. The index binds the exact candidate release, root source commit, backend and
   web digest references, and preallocated admission evidence reference.
3. Every control has one distinct opaque record reference, one distinct nonzero
   lowercase SHA-256 value, and one non-future UTC observation time.
4. Browser onboarding, deployment control, and Workspace Access evidence are
   no more than 24 hours old. Hosted recovery and runtime-operations evidence
   are no more than 30 days old.
5. The index itself is generated no more than 24 hours before admission.
6. Production admission copies the minimized index into its closed bundle and
   cross-checks every private summary against that retained source.
7. Schema-v2 admission bundles are rejected. Operators must reassemble schema
   v3 from current evidence rather than silently accepting unbound references.
8. Admission expiry is the earliest of the four-hour approval window, mutable
   deployed-proof expiry, index expiry, and private-control expiry.

## Delivery

1. [x] Add one strict private-control index parser with closed-set, identity,
   freshness, privacy, and exact-property validation.
2. [x] Replace the five loose assembler parameters with one closed index
   directory and bind it to the verified candidate promotion.
3. [x] Emit and independently verify Production admission schema v3 with the
   retained index and private record hashes.
4. [x] Add adversarial fixtures for tampering, missing or extra controls,
   duplicate references or hashes, cross-candidate and cross-attempt reuse,
   stale and future evidence, and output/source overlap.
5. [x] Update operations guards and concise operator documentation.
6. [x] Run focused policy verification while editing, then one complete
   repository gate and one exact-head GitHub evidence set at slice end.

Focused verification passed on 2026-08-23:

- `eng/test-production-admission.ps1`; and
- `eng/verify-operations.ps1`, including every deployed-domain fixture and the
  Production admission policy guard.

The complete root `eng/verify.ps1` gate also passed on 2026-08-23 with:

- synchronized root/backend solutions and current backend, web, and GMA pins;
- zero-warning root and backend builds;
- no migration drift;
- all non-Docker backend, architecture, host, and integration suites passing;
- web typecheck and lint, 73 test files with 371 tests, and the 3,032-module
  production build; and
- the complete schema-v3 Production admission fixture inside the operations
  policy suite.

The implementation is commit
`af5b9f67c7d5155da6112bc534cd2040fa2ff4a5`. Its exact-head GitHub evidence
passed on 2026-08-23:

- Validate run `32638406238`;
- Security Baseline run `32638406311`; and
- CodeQL run `32638406253`, with both C# and JavaScript/TypeScript analyses
  successful.

No hosted admission is claimed by this repository-only evidence.

## Acceptance

- the assembler cannot accept a loose private reference;
- the standalone verifier can reconstruct and validate every private summary
  from the retained index;
- no private content or deployment identifier beyond bounded opaque references
  enters the admission bundle;
- stale and cross-bound private evidence fails before output is created; and
- the final record still says `evidence-complete-awaiting-private-approval`.

## Deferred

- Authenticating or signing the private records and index.
- Inspecting private provider APIs, backups, topology, alerts, or operator
  approvals from the public repository.
- Running the real hosted admission attempt.
