# Deployed Operations Notifications Verification

Status: v3 implemented and fixture verified; hosted proof remains pending
Date: 2026-08-13

Use this mutation-bearing probe to verify BunkFy's product notification path
through the public API, durable worker pipeline, Notifications history, and
server-sent-event stream.

The probe creates and releases one manual block for one available inventory
unit. Run it only with dedicated deployment-smoke data and an empty date range.
It retains the released block and two read notification-history records as
bounded audit evidence.

## Preconditions

Supply two active accounts in the same workspace:

- the actor can read the property and manage inventory blocks; and
- the observer is a distinct active Staff member assigned to the property and
  can open its Inventory destination.

Choose one active, sellable inventory unit with no block or allocation in the
requested half-open arrival/departure range. The probe rechecks availability
immediately before mutation and fails safely if the range is no longer free.

## Run

```powershell
./eng/operations/verify-deployed-operations-notifications.ps1 `
  -PublicOrigin https://candidate.example `
  -ExpectedReleaseId <promotion-record-release-id> `
  -WorkspaceId <workspace-id> `
  -PropertyId <property-id> `
  -InventoryUnitId <inventory-unit-id> `
  -Arrival 2027-02-11 `
  -Departure 2027-02-13
```

Provide the actor and observer bearer tokens through secure parameters, secure
prompts, or these process-scoped environment variables:

```text
BUNKFY_SMOKE_NOTIFICATION_ACTOR_TOKEN
BUNKFY_SMOKE_NOTIFICATION_OBSERVER_TOKEN
```

Do not put tokens on the command line. The operation requires confirmation
unless the caller deliberately supplies `-Confirm:$false` in controlled
automation.

### Self-contained preview rehearsal

The Preview onboarding rehearsal can contribute the dedicated actor, observer,
property, and room-level inventory fixture when no reusable smoke fixture
exists:

```powershell
./eng/operations/rehearse-preview-onboarding.ps1 `
  -PublicOrigin http://127.0.0.1:18080 `
  -ExpectedReleaseId <candidate-release-id> `
  -EnvironmentPath /secure/path/preview.env `
  -AllowLoopbackHttp `
  -IncludeOperationsNotifications `
  -Confirm:$false
```

This opt-in path runs the invitation proof first, uses its property-scoped
Staff member as the observer, creates one temporary whole-room inventory unit,
and delegates the notification assertions to this verifier. It then retires
the room through Inventory's coordinated topology workflow before the parent
rehearsal retires the properties, removes non-owner memberships, archives the
workspace, and revokes all synthetic sessions.

The standalone Operations Notifications child file is written beside the
onboarding umbrella as `*.operations-notifications.json`. The umbrella requires
the scrubbed child to omit workspace identity and binds it by SHA-256 without
copying tokens or notification content. A trusted-HTTPS child may be supplied
to the corresponding production-admission input; loopback Preview output is
composition evidence only and is rejected by production admission.

## Checks

The probe verifies:

- public `/api/smoke` reports the expected release before and after the workflow;
- both tokens resolve to distinct active memberships in the target workspace;
- both accounts can read the property and the observer can open the Inventory
  data behind the notification destination;
- the observer cannot use the same token to read a random workspace's history;
- a durable history SSE cursor opened before mutation receives the created and
  released events in order;
- both records preserve module, name, version, tags, property, block-group, and
  date-range navigation correlation;
- each notification is initially unread, addressable by id, and durably read
  after its individual acknowledgement;
- the initiating actor receives neither notification;
- observer history contains exactly one created and one released record; and
- the inventory block is retained in released state after cleanup.

The probe uses one SSE connection and bounded polling only after expected state
changes. It never calls a bulk read endpoint or scans more than the newest 100
history records; newly created smoke records must be in that bounded window.

## Evidence And Failure

Passing schema-v3 JSON evidence is written atomically under
`.tmp/deployment-probes` by default. It contains deployment origin and release
identity; fixed source module, notification names, version, and destination
tags; counts proving two ordered live notifications, two initially unread and
durably read observer records, exactly-once history, and zero actor deliveries;
terminal block and retained-history dispositions; ten check results; and fixed
limitations.

It excludes workspace, property, Inventory, block, notification, membership,
subject, actor, operation, and Staff identifiers; date ranges; absolute stream
sequences; bearer tokens; mutation reason; notification content and payloads;
raw response bodies; and headers. Loopback output is identified as
`loopback-http-preview`, never as fixture or trusted-HTTPS evidence.

On failure after creation, the probe releases the block best-effort before
returning the original error. A cleanup warning blocks promotion and requires
operator review; do not repair Inventory or Notifications tables directly.

This probe does not exercise browser attention styling, browser navigation, or
external delivery adapters. Those remain candidate-specific checks.

## Historical VPS Preview Evidence

On 2026-08-11, the probe passed all ten checks through the VPS Preview's
trusted HTTPS origin for release `preview-runtime-hardening-20260811`. The
then-current schema-v1 production-admission parser accepted the child record with
SHA-256
`d3ab85e1f67a4df3909fc5e2f27070d53168892500520bfeb4a8da24aa8dd683`.

The enclosing rehearsal retired the notification room, removed both joined
memberships, retired both synthetic properties, archived the workspace,
revoked all three sessions, and purged and closed the Mailpit operator window.
The evidence is retained only in the ignored VPS working state. Schema v3
also binds the observed admission evidence reference and
supersedes its scoped evidence shape, so it cannot satisfy current production
admission. It also does not admit the current candidate, prove browser attention
behavior, exercise external delivery adapters, or replace the private
notification-retention approval required for Production activation.

## Historical V2 Preview Evidence

On 2026-08-13, exact release
`preview-operations-notifications-3ea29b6` passed all ten public workflow checks.
The schema-v2 child SHA-256 is
`a2b0a8ffa1c2664078516526112dd03b667d209a2128a05b8c94f2842d0f1acc`;
the onboarding umbrella SHA-256 is
`c3c445e2dc5fa21d7a65b9d03b67fe8e36c096957e6944fe5a5c43b6b94a671b`.

All four retained files are mode `0600`. The child matches the closed admission
shape and semantics and contains no scoped identifiers, date ranges, stream
coordinates, personal content, or secret material. Parent cleanup retired the
dedicated room and both properties, removed both non-owner memberships,
archived the workspace, revoked all sessions, and purged Mailpit. The child is
`loopback-http-preview`, so production admission correctly rejects it despite
its exact release and passing semantics.

## Repository Fixture

`eng/test-deployed-operations-notifications.ps1` runs the full sequence against
a deterministic loopback fixture. It proves the valid path, release mismatch
rejection, exact schema and evidence redaction, mode `0600`, overwrite refusal,
identical-token rejection, insecure non-loopback HTTP rejection, and rejection
with terminal block release when the actor receives its own notification. It
does not contact a deployed environment.
`eng/test-preview-sellable-room-fixture.ps1` separately
proves bounded room provisioning, delayed projection convergence, whole-room
sales configuration, partial-state cleanup ownership, and coordinated room
retirement for the self-contained Preview contributor.
