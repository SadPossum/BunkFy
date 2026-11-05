# Deployed Ingestion Connection Lifecycle Proof Task

Status: implemented, fixture verified, operations-gate verified, and exact-release Preview verified
Date: 2026-08-13

## Goal

Add one bounded exact-release deployment proof for the operator-controlled
Ingestion lifecycle: discover a registered remote-adapter capability, create and
versionedly configure one synthetic connection, issue and use one one-time
ingress credential, complete one empty remote lease, revoke that credential,
and leave the connection disabled.

## Finding

The existing deployed AdapterHost proof deliberately starts from an enabled
`RemotePolling` connection and remains read-only. It proves the provider-to-
Ingestion data path, durable receipts, provenance, and checkpoint advancement,
but not the control-plane lifecycle that creates the connection, rotates opaque
material references, issues a credential once, rejects replay disclosure,
revokes adapter access, and places the connection in a terminal safe state.

Preview composition currently creates those resources as supporting setup for
AdapterHost. Production admission consumes only the read-only AdapterHost child,
so those management guarantees are not independently release-bound.

## Ownership

- Ingestion owns adapter capability discovery, connection configuration and
  state, optimistic versions, mutation journals, ingress credentials, remote
  leases, runs, health, and operational projections.
- Adapter abstractions own protocol, execution-mode, lease, and run contracts.
  The proof must discover a registered capability rather than hard-code one.
- Properties owns property identity. Data Governance owns country-policy
  admission. The verifier requires an already approved processing policy and
  must not activate, rebind, or reinterpret it.
- Workspaces owns tenant lifecycle. Access Control owns permission and scope
  evaluation. Auth owns subjects, sessions, and configured recent-assurance
  requirements for credential management.
- The root operations layer owns synthetic orchestration, exact-release binding,
  bounded requests, cleanup accounting, minimized evidence, Preview
  composition, and production-admission policy.
- GMA already supplies the reusable tenancy, authorization, assurance, CQRS,
  results, idempotency-supporting, and lifecycle primitives used here. No GMA
  change is planned.

## Proof Contract

The deployed verifier will:

1. Bind one active workspace operator to the expected release and prove a
   distinct authenticated nonmember cannot read the property's connections.
2. Discover a registered adapter capability supporting `RemotePolling`, while
   refusing an empty, unknown, or mismatched capability contract.
3. Create one synthetic connection using its operation id as identity, prove
   exact replay stability, reject changed reuse, and verify paged directory,
   detail, and capability-aware health visibility.
4. Update opaque configuration and secret references with optimistic
   concurrency, prove exact replay stability, reject changed reuse and stale
   writes, then explicitly clear the secret reference.
5. Disable and re-enable the connection through versioned controls, including
   exact replay, changed-reuse, and stale-write rejection.
6. Issue one short-lived ingress credential under configured recent assurance,
   prove the exact replay never rediscloses its token, reject changed operation
   reuse, and verify the bounded credential directory.
7. Use the one-time token through independent `BunkFy-Adapter` authentication to
   claim and complete one zero-observation remote lease, then verify the
   terminal successful run and connection health.
8. Revoke the credential with optimistic and idempotent semantics, reject
   changed reuse and stale writes, and prove the retired token receives `401`
   from a fresh lease claim.
9. Disable the connection, verify its final detail, health, run, and credential
   projections, and prove release identity continuity.

Business conflicts, authorization failures, capability drift, credential token
redisclosure, nonterminal runs, and stale-write acceptance fail immediately.
Only the explicit `Ingestion.CountryPolicyDenied.MissingBinding` result may be
retried with the identical connection-create request while the Ingestion-owned
policy projection catches up with an already effective Properties binding.

## Evidence Boundary

The evidence kind will be
`bunkfy-deployed-ingestion-connection-lifecycle-probe`, schema version 1. It may
retain release and transport identity, selected protocol and schema versions,
version and status relationships, terminal zero-observation run facts, cleanup
disposition, named checks, and fixed limitations.

It must not retain credentials or tokens; authorization headers; subjects;
workspace, property, connection, credential, run, lease, worker, claim, or
operation identifiers; adapter type, source system, labels, configuration or
secret references; country-policy values; timestamps beyond evidence
generation; checkpoints; response bodies; or raw headers. Files are written
atomically with private permissions and cannot overwrite an existing result
without explicit `-Force` approval.

## Preview Composition

`rehearse-preview-onboarding.ps1` will expose an opt-in Ingestion connection
lifecycle switch. The parent will activate its existing Preview-only engineering
processing policy before invoking the child and will provide its active property,
fresh owner session, and authenticated nonmember session. The child will leave
its own connection disabled, its credential revoked, and its empty synthetic run
terminal; the parent remains responsible for the surrounding property and
workspace.

An independently prepared deployment must supply an approved country policy and
an operator token satisfying the host's configured credential-management
assurance. Passing loopback Preview evidence remains composition proof, not
hosted-production approval.

## Delivery

1. Add the deployed verifier and deterministic valid plus replay-drift fixture.
2. Add opt-in Preview onboarding composition with child-authoritative connection
   and credential cleanup.
3. Add the closed evidence specification to production admission and require
   its exact-release source evidence.
4. Wire static guards, focused fixtures, documentation, and the operations gate.
5. Run one complete operations gate and one exact-release Preview rehearsal only
   after the slice is coherent.

## Verification Cadence

Use focused script fixtures while editing. Do not run Docker suites for root-only
operations changes. Run the complete operations gate once at the slice boundary;
the final exact-release Preview rehearsal is the integration proof across the
edge, API, PostgreSQL, Ingestion, access policy, assurance, country policy, and
independent adapter authentication.

## Deferred

- a real provider record, observation receipt, proposal, and checkpoint path,
  which remains owned by the deployed AdapterHost proof;
- polling schedules, continuous and push execution modes, checkpoint reset, and
  tenant/global ingress emergency controls;
- production secret-manager rotation and orchestrator restart evidence;
- high-contention connection and credential limits;
- approved production country-policy activation or transfer decisions;
- hosted-production execution and private approval; and
- generalizing BunkFy-specific Ingestion orchestration into GMA without another
  demonstrated project use case.

## Acceptance

- The focused verifier and admission fixtures pass.
- The complete operations gate passes once for the finished slice.
- One exact-candidate Preview run produces minimized passing evidence and leaves
  the synthetic credential revoked, run terminal, and connection disabled.
- Production admission requires the new exact-release evidence while refusing
  to present loopback Preview evidence as hosted-production proof.

## Completion

Implemented the 32-check deployed Ingestion connection lifecycle verifier,
deterministic valid and credential-token-redisclosure fixture, bounded
country-policy projection convergence, Preview opt-in composition, production
admission specification and semantic validation, static guards, and operator
documentation. No BunkFy module runtime or GMA source changed: source review and
the deployed proof confirmed the existing Ingestion, Adapter Abstractions,
Properties, Data Governance, Access Control, and Auth contracts already preserve
the intended ownership boundaries.

The focused verifier and admission fixtures passed. One exact Preview rehearsal
passed for `preview-workspace-access-estate-651107f`; child SHA-256 is
`3c2014beaa505e0a91a58c2d939ad184da1346a48038150ae561244b0eda2b3a`
and umbrella SHA-256 is
`a9ada03a77177d808ccfceb71700b14757ede2e68ad72f6d0a3efb82723925a3`.
All retained files use mode `0600`, the minimization scan was clean, the
production-admission parser accepted the 32-check child, and the complete
operations gate passed once in 196.3 seconds.

The exact deployment exposed two orchestration defects before the passing run:
Ingestion's local policy projection can briefly lag an effective Properties
binding, and a PowerShell `[string]` parameter coerced JSON null to an empty
string. The verifier now retries only the explicit missing-binding result with
the identical create request, preserves null for secret clearing, and covers
both behaviors deterministically. Both failed Preview umbrellas completed their
authoritative property, workspace, session, and Mailpit cleanup.
