# Deployed Operations Notifications Evidence Minimization Proof Task

Status: in progress
Date: 2026-08-13

## Goal

Bring the existing deployed Operations Notifications proof up to the current
production-evidence standard without changing product runtime behavior: retain
only release-safe workflow facts, distinguish real loopback Preview from a
deterministic fixture, and capture fresh exact-release evidence.

## Finding

The Operations Notifications runtime already filters bounded Staff and owner
candidates through authoritative active organization access and destination
permission checks, excludes the initiating user, resolves one active Staff
correlation per recipient, and projects stable idempotent notification ids.
Focused tests cover failures, stale membership, missing Staff correlation,
permission filtering, minimized product content, and data-rights ownership.

The deployed verifier predates the stricter evidence boundary used by newer
domain proofs. Its schema retains workspace, property, inventory, block, and
notification identifiers plus exact dates and stream sequences even though
production admission does not need those values. It also labels every
loopback run as a fixture, including a real Preview deployment. The last
trusted-HTTPS proof belongs to an older release and explicitly does not admit
the current candidate.

## Ownership

- Operations Notifications continues to own BunkFy recipient policy, product
  notification content, navigation references, personal-data catalogue, data
  rights, and production retention admission.
- GMA Notifications continues to own generic history, read state, SSE, delivery,
  preferences, retention mechanics, and reusable projection idempotency.
- Inventory continues to own the synthetic block and release lifecycle used as
  the public mutation source.
- The root operations layer owns deployed orchestration, scrubbed evidence,
  deterministic fixtures, Preview composition, and production-admission shape.
- No BunkFy-specific behavior belongs in GMA, and no framework change is
  planned.

## Evidence Contract V2

The evidence kind remains
`bunkfy-deployed-operations-notifications-probe`; schema version advances to 2.
The record may retain only:

- generated time, public origin, exact release, transport, and result;
- fixed source module, notification names, web/domain tag expectations, and
  counts proving ordered live delivery, initial unread state, durable read
  acknowledgement, exact-once observer history, and zero actor deliveries;
- terminal block disposition and retained read-history disposition;
- the ten named checks and fixed limitations.

It must not retain workspace, property, inventory, block, notification,
membership, subject, actor, operation, or Staff identifiers; date ranges;
absolute stream sequences; credentials; content; payloads; response bodies; or
headers. Evidence remains atomic, private, and non-overwriting by default.

Trusted HTTPS is the only production-admission transport. A real loopback run
is `loopback-http-preview`; the deterministic admission fixture remains
`loopback-http-fixture`. Preview composition must require that the child has no
workspace binding and bind it only by SHA-256.

## Delivery

1. Replace scoped evidence fields with closed workflow, delivery, and cleanup
   summaries and advance the schema version.
2. Update Preview child validation and production-admission semantic checks.
3. Strengthen the deterministic fixture for sensitive-value absence, exact
   property shape, private mode, overwrite refusal, actor-leak rejection, and
   best-effort block release on failure.
4. Align the verifier and admission documentation.
5. Run focused fixtures while editing, then one complete operations gate and
   one exact-release Preview rehearsal at the coherent boundary.

## Deferred

- browser attention rendering and navigation, which remain web workflow checks;
- external email, SMS, or push adapters until delivery-time reauthorization is
  designed;
- approved production retention periods, legacy-history disposition, alert
  routing, backup expiry, and actual owner topology;
- high-fanout load measurements beyond bounded candidate and permission batches;
- hosted trusted-HTTPS execution and private approval; and
- framework extraction without another generic consumer requirement.

## Acceptance

- The v2 child contains no scoped identifiers, personal content, or secret
  material and uses mode `0600` on Unix.
- Deterministic valid and actor-leak paths prove terminal block release and do
  not write false passing evidence.
- Production admission accepts only the exact closed v2 trusted-HTTPS contract;
  loopback Preview remains non-admissible.
- Preview binds the scrubbed child by hash and completes room, workspace,
  membership, session, and mail cleanup.
- No backend, database, web, or GMA runtime change is introduced unless the
  deployed proof reveals a concrete defect.
