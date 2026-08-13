# Deployed Ingestion Conflict And Proposal Lifecycle Proof Task

Status: in progress
Date: 2026-08-13

## Goal

Close and prove the production-critical reservation authority rule for external
sources: adapter changes apply automatically only while the accepted adapter
baseline is still current; a later staff edit is preserved and turns an
external change into an explicit operator proposal.

## Finding

The domain and focused integration suite already prove baseline-aware automatic
application, revision-conflict proposals, accept/reject replay, and race-to-stale
handling. One promised invariant is incomplete: a newer ordered source
observation can create another pending proposal without superseding the older
one. `ChangeProposal.Supersede` and the public status contract exist, but no
application path invokes that transition and the web filter omits the status.

That leaves an operator able to act on an older source suggestion after a newer
suggestion has arrived. It is an Ingestion lifecycle defect, not a Reservations
or framework responsibility.

## Ownership

- Ingestion owns source ordering, accepted adapter baselines, dispatch outcomes,
  proposals, proposal decisions, supersession, and sensitive proposal history.
- Reservations owns current booking truth, `DetailsRevision`, staff changes,
  external-operation idempotency, final validation, and applied history.
- Inventory remains authoritative for allocation feasibility and atomic
  amendments.
- Adapter Abstractions owns transport-neutral observation envelopes. Adapters
  cannot select tenant or property authority from payload data.
- The root operations layer owns exact-release orchestration, synthetic setup
  and cleanup, evidence minimization, Preview composition, and admission policy.
- GMA already supplies the transaction, tenancy, authorization, messaging,
  assurance, and persistence primitives needed by the flow. No GMA change is
  planned.

## Runtime Invariants

1. One source graph may have at most one actionable pending proposal after a
   command transaction completes.
2. Creating a proposal for a newer admitted observation supersedes every older
   pending proposal for the same connection and reservation before publishing
   the new actionable suggestion.
3. An applying proposal is never superseded. The source link keeps its product
   operation active and defers newer observations until that operation is
   terminal.
4. Applied, rejected, stale, failed, and superseded proposals remain immutable
   audit history.
5. Supersession records a fixed system actor and reason and receives the same
   sensitive-history retention deadline as other terminal proposal outcomes.
6. Staff-owned reservation details are never changed while a proposal is merely
   pending or superseded.
7. Source ordering, receipt replay, proposal decision replay, and optimistic
   reservation revision checks remain authoritative and fail closed.

The existing source-graph transaction lock serializes observation dispatch,
reservation outcomes, and proposal decisions for one external reservation.
Supersession therefore belongs in the application orchestration around proposal
creation and needs no provider-specific partial index or schema change.

## Deployed Proof Contract

Against one exact release and one synthetic property, the deployed verifier
will:

1. bind an authorized operator and prove an authenticated nonmember cannot read
   the proposal queue;
2. create an enabled push connection and one short-lived ingress credential;
3. submit an initial reservation observation and prove durable automatic create;
4. submit an ordered adapter update and prove automatic application while the
   adapter baseline remains current;
5. perform a staff details edit, submit a newer adapter update, and prove the
   staff state is preserved while a pending proposal appears;
6. submit a still-newer update and prove the first proposal becomes superseded
   and cannot be decided while only the newest remains pending;
7. reject one newest proposal, prove exact decision replay and changed-decision
   conflict, then create and accept a later proposal;
8. prove accepted-application convergence in Reservations and Ingestion,
   including exact accept replay and stale request rejection;
9. submit duplicate and stale source input without creating extra actionable
   work; and
10. cancel the synthetic reservation, revoke the credential, disable the
    connection, and prove release identity continuity.

All polling is bounded. Unexpected authorization, lifecycle, ordering,
projection, replay, or cleanup behavior fails immediately.

## Evidence Boundary

The evidence kind will be
`bunkfy-deployed-ingestion-conflict-proposal-lifecycle-probe`, schema version 1.
It may retain release identity, transport classification, integer revision and
status relationships, counts, named checks, terminal cleanup dispositions, and
fixed limitations.

It must not retain bearer or adapter tokens; authorization headers; subjects;
workspace, property, topology, connection, credential, receipt, proposal,
reservation, operation, or source identifiers; guest data; source revisions or
payloads; adapter names; policy values; response bodies; or raw headers. Evidence
is written atomically with private permissions and cannot be overwritten without
explicit approval.

## Delivery

1. Harden pending-proposal supersession and add focused application/domain tests.
2. Expose superseded history in the web proposal filter and align task docs.
3. Add the deployed verifier and deterministic fixture.
4. Compose it as an opt-in Preview onboarding child with authoritative cleanup.
5. Add its closed evidence specification and semantics to production admission.
6. Run focused checks while editing, then one coherent backend/web/operations
   gate and one exact-release Preview rehearsal.

## Verification Cadence

Do not run Docker or GitHub Actions after individual edits. Run focused
non-Docker tests while shaping the invariant. At the coherent slice boundary,
run the relevant backend and web gate once, the complete operations gate once,
then one exact-release Preview rehearsal. Fix any failures iteratively against
that same slice before rerunning the smallest failed boundary.

## Deferred

- field-level merge policies beyond whole-observation review;
- production provider credentials and real guest data;
- high-contention load measurements beyond the existing source-graph lock and
  bounded read contracts;
- orchestrator restart and secret-manager rotation evidence;
- hosted-production approval and private legal/country-policy decisions; and
- framework extraction without another generic consumer.

## Acceptance

- A newer ordered source proposal leaves exactly one pending actionable proposal
  and retains the older proposal as superseded history.
- Existing automatic-apply, staff-protection, rejection, acceptance, replay, and
  race-to-stale tests remain green.
- The focused verifier and production-admission fixture pass.
- One exact-release Preview run produces minimized passing evidence and leaves
  the reservation terminal, credential revoked, and connection disabled.
- No BunkFy-specific reservation or adapter semantics leak into GMA.
