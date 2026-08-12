# Preview AdapterHost Rehearsal Task

Status: completed for Preview rehearsal
Date: 2026-08-12

## Goal

Prove that one connection-scoped AdapterHost can start from an exact BunkFy
backend image digest, pass Production admission, claim server-owned leases, and
deliver durable synthetic observations through the deployed Preview API.

## Finding

The backend candidate now packages `BunkFy.AdapterHost`, and the deployed
AdapterHost verifier already validates health, lease identity, receipt
provenance, checkpoint progression, and release continuity. Preview still has
no bounded way to materialize one runtime instance, protect its credential,
seed a provider boundary, or remove the instance after proof. A static Compose
singleton would be incorrect because AdapterHost identity and lifecycle belong
to one Ingestion connection.

The first deployed rehearsal also exposed a Preview composition gap: the
public API mapped the intentionally disabled adapter-ingress handlers because
`Ingestion:AdapterIngress:Enabled` was absent. Preview must enable that surface
explicitly; Production startup then requires the already composed Redis-backed
distributed quota provider. The rehearsal verifies the enabled boundary
returns `401` to a credentialless claim before creating any connection state.

## Decision

Add a transient Preview rehearsal that:

1. creates one `RemotePolling` `json.file-drop` connection and one short-lived
   ingress credential through public module contracts;
2. prepares runtime material in Docker-managed volumes without placing the
   credential in command arguments, repository files, or retained evidence;
3. starts one hardened container from an `image@sha256:<digest>` reference with
   Production admission bound to the backend source commit and public HTTPS
   origin;
4. exposes health on a random loopback host port while keeping `/status`
   disabled;
5. seeds a synthetic reservation upsert only after the read-only deployed probe
   captures its baseline, then repeats the proof with a cancellation; and
6. stops the container, disables the connection, revokes the credential,
   removes all transient volumes, and lets the parent onboarding rehearsal
   retire the inventory fixture and archive its workspace.

The launcher is deliberately not a durable scheduler. Real deployment
composition will create, replace, and supervise one instance per approved
connection using the same runtime contract.

## Ownership

- Ingestion owns connection, credential, lease, checkpoint, run, and receipt
  state.
- AdapterHost owns one process identity and adapter execution lifecycle.
- The BunkFy product deployment owns Docker materialization, network exposure,
  secret delivery, process replacement, and rehearsal cleanup.
- GMA has no responsibility here; no generic framework behavior is missing.

## Delivery

- [x] Add a connection-scoped, exact-digest Preview AdapterHost launcher.
- [x] Keep runtime material and ingress credentials out of arguments and
  retained evidence.
- [x] Add upsert and cancellation provider cycles around the existing read-only
  deployed verifier.
- [x] Integrate the proof as an optional onboarding rehearsal contributor with
  explicit inventory and workspace cleanup.
- [x] Guard script syntax, hardening, redaction, and contributor wiring.
- [x] Run focused fixtures once, then one deployed HTTPS rehearsal at the end of
  the slice.

## Verification

- The focused Preview AdapterHost fixture and Compose resolution passed.
- The public credentialless remote-lease preflight returned `401`; the same
  route had returned `503` before Preview enabled adapter ingress.
- The HTTPS onboarding rehearsal passed all ten checks against release
  `preview-runtime-hardening-20260811` using backend source commit
  `a26908500aa24043eb117cface616aa9ed5408b9` and image digest
  `sha256:372db6fd4332ddcfd69ad5c4ee0ccb81aac85ad445e290d92af9e333f261d2e9`.
- Local minimized evidence is
  `.tmp/deployment-probes/preview-onboarding-20260812T003142Z.json`, SHA-256
  `77e180aa5a32ec09c2fd3c4d3ed102ae9d6bed4ccfad9478a085132acde2cc0d`.
  It records passed upsert and cancellation children plus complete removal of
  the connection-scoped runtime and room fixture.
- This is deployed Preview evidence from a separately materialized exact image,
  not final retained-candidate admission or real-provider proof.

## Verification Boundary

Passing evidence proves the deployed Preview API, exact local image digest,
Production admission configuration, server lease, durable receipt provenance,
checkpoint advancement, and synthetic reservation cancellation for this
rehearsal. It is not final-candidate admission unless the supplied digest is the
retained scanned candidate, and it does not prove a real OTA, mailbox, or web
parser provider.

## Deferred

- durable orchestration and restart policy for configured connection fleets;
- ingress credential rotation with overlapping slots and old-token rejection;
- provider-specific network, secret-store, and rate-limit policies;
- candidate-specific replacement, rollback, and operator approval evidence;
- production monitoring and alert ownership for stopped or unhealthy adapter
  processes.
