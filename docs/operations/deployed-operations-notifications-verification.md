# Deployed Operations Notifications Verification

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
onboarding umbrella as `*.operations-notifications.json` and is suitable for
the corresponding production-admission evidence input. The umbrella binds the
child by SHA-256 without copying tokens or notification content.

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

Passing JSON evidence is written atomically under `.tmp/deployment-probes` by
default. It contains deployment origin and release identity, workspace/property/
unit/block ids, date range, notification ids and stream sequences, ten check
results, and explicit limitations. It excludes bearer tokens, Auth subjects,
mutation reason, notification bodies, raw response bodies, and headers.

On failure after creation, the probe releases the block best-effort before
returning the original error. A cleanup warning blocks promotion and requires
operator review; do not repair Inventory or Notifications tables directly.

This probe does not exercise browser attention styling, browser navigation, or
external delivery adapters. Those remain candidate-specific checks.

## Repository Fixture

`eng/test-deployed-operations-notifications.ps1` runs the full sequence against
a deterministic loopback fixture. It proves the valid path, release mismatch
rejection, evidence redaction, identical-token rejection, and rejection when
the actor receives its own notification. It does not contact a deployed
environment. `eng/test-preview-operations-notifications-fixture.ps1` separately
proves bounded room provisioning, delayed projection convergence, whole-room
sales configuration, partial-state cleanup ownership, and coordinated room
retirement for the self-contained Preview contributor.
