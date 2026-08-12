# Preview Deployment

This is the production-shaped single-node preview path for BunkFy. It packages the current domains without introducing another business module. Aspire remains the local development path.

The stack uses the explicit `Preview` environment so its protected
data-rights replay ledger can use one integrity-keyed local provider shared by
API, Worker and management hosts. The provider lives on its own named volume
and is never a production topology: Production still requires a separately
registered external, production-grade ledger provider.

Preview also mounts the tracked `development-hostel-example` v2 country-policy
pack read-only into API and Worker and pins its digest in Compose. That policy is
synthetic engineering data with `example` approval metadata. It exists so
Preview can exercise the real fail-closed processing workflow; it is not a
country launch decision, legal review, or production policy approval.

The Preview API explicitly enables adapter ingress so connection-scoped
AdapterHost rehearsals use the real independently authenticated endpoints.
Enabling the surface also activates the Redis-backed distributed quota
provider required by Production admission; no adapter ingress port is exposed
outside the existing same-origin API route.

## Prepare

Requirements: Docker with Compose v2, PowerShell 7, and recursively initialized
submodules.

```powershell
.\eng\new-preview-env.ps1
```

Review `deploy/preview/.env`, set `BUNKFY_PUBLIC_URL` to the externally visible
HTTPS origin, and set `BUNKFY_ALLOWED_HOSTS` to an explicit semicolon-separated
list containing that origin's host plus any loopback host used by local health
or management probes. Wildcards are rejected. Register this callback with each
enabled OIDC provider:

```text
https://your-bunkfy-host/auth/complete
```

Set `BUNKFY_RELEASE_ID` to a new non-secret identifier for each deployed
candidate. The API and Worker receive the same value, and deployed edge evidence
must match it. `preview-local` is only the local default.

The generated file is ignored by Git and is written atomically with private
local permissions. On Unix it is mode `0600`; on Windows it has a protected ACL
for the current operator, Local System, and built-in Administrators. Preview,
backup, restore, isolation, and rehearsal commands reject a broader file or a
path behind a symbolic link. Keep it in the server secret store or protected
deployment workspace. PostgreSQL and NATS credentials must remain
URL/connection-string safe.

Tighten a file created before this guard with:

```powershell
.\eng\operations\protect-preview-local-state.ps1
```

Pass `-EnvironmentPath` when the protected file lives outside the checkout.
The command changes local permissions, not secret values.

`preview.ps1 build` and the default `preview.ps1 up` refresh the backend's
ignored GMA source-root maps before invoking Docker, so a clean recursive
checkout packages the same source composition validated by CI. A deployment
that has already loaded reviewed image bytes can use `-NoBuild` with `up`; that
mode never bootstraps or rebuilds source.

## Start And Verify

```powershell
.\eng\preview.ps1 config
.\eng\preview.ps1 up
.\eng\preview.ps1 status
```

Keep the tracked `deploy/preview/compose.yaml` as the only service-topology
contract. A protected environment file may live outside the checkout:

```powershell
.\eng\preview.ps1 up `
  -EnvironmentPath /protected/bunkfy-preview/.env `
  -NoBuild
```

Pass the same environment path to backup, restore, recovery-rehearsal, and
isolation commands. Do not maintain a private Compose fork; otherwise a recovery
or backup restart can apply different runtime settings from the original stack.

The browser app is available on loopback at `http://127.0.0.1:8080` by default. The API is reachable only through the same-origin Nginx route. PostgreSQL, Redis, NATS, MinIO, and Mailpit have no host ports in the default topology.

The Compose host intentionally does not terminate TLS. A remote deployment must place an HTTPS reverse proxy or ingress in front of the loopback web port and preserve forwarded headers. Do not expose the API, Admin API, databases, broker, or object storage directly.

## Runtime Restrictions

Backend and web images run as their declared non-root `app` and `nginx` users.
Compose gives every first-party process a read-only root filesystem, drops all
Linux capabilities, denies privilege escalation, uses an init process, limits
the process count, and allows 30 seconds for graceful shutdown. Writable state
is limited to the named application volumes and bounded tmpfs mounts. Nginx's
generated configuration, run directory, cache, and temporary directory use
separate tmpfs mounts owned by its runtime user.

Preview explicitly places the Data Rights tenant-termination replay journal in
its own shared `tenant-termination-replay` state volume. API, Worker, Admin API,
and Admin CLI therefore observe one journal, and backup/restore captures it
without placing foreign files beneath the integrity-closed ledger-delta root.
Before those processes start, a one-shot initializer gives the backend `app`
identity ownership of that volume root. The initializer receives no application
environment, has no network, mounts no other state, uses a read-only root
filesystem, and retains only `CAP_CHOWN`; it exists so current and historical
backend images initialize the new volume identically.

Every service uses the Docker `local` log driver with 10 MiB files and at most
three files. This is a host-disk bound, not centralized observability or an
approved log-retention policy. Export important operational signals before
rotation in any long-lived deployment.

The stateful third-party images retain their reviewed upstream entrypoint user
behavior. Do not add an arbitrary numeric user to an existing PostgreSQL,
Redis, NATS, MinIO, or Mailpit volume: rehearse ownership migration and restore
with the exact upgraded image first. Hosted Production should prefer managed
services or separately reviewed runtime identities and must still provide host,
seccomp/AppArmor, resource-sizing, and orchestration evidence.

## Runtime Image Pins

The tracked Compose contract pins PostgreSQL, Redis, NATS, MinIO, and Mailpit
to reviewed multi-platform manifest digests. Preview backup, restore, and
recovery commands also use one centrally declared digest-pinned Alpine utility
image. The Production migration rehearsal defaults to the same pinned
PostgreSQL image. This prevents a registry tag from silently changing the
runtime or recovery tooling between an operation and its replay.

Treat image upgrades as a reviewed deployment slice. Resolve the intended tag
from its registry, record its current manifest-list digest, update the tag and
digest together everywhere it is used, review upstream release and security
notes, run `./eng/verify-operations.ps1`, and finish with one Preview recovery
rehearsal before promoting the new dependency set. Never refresh only the
digest behind an unchanged review record.

## Preview Email Capture

New Preview environment files enable the BunkFy SMTP adapter and GMA's durable
notification email sink against the private Mailpit service. The browser reads
`/api/product-capabilities` at startup, so email-verification controls describe
the running composition rather than the web image's build arguments.

Mailpit is preview evidence only. It does not prove delivery by a real provider,
sender-domain authentication, suppression handling, or inbox placement. Its
mailbox is capped at 500 messages and stored on a 64 MiB tmpfs; container
recreation clears it and backups intentionally exclude it.

The UI has no host port by default. Open a short-lived loopback-only operator
window when visual inspection is required:

```powershell
$compose = @(
  'compose', '--env-file', 'deploy/preview/.env',
  '-f', 'deploy/preview/compose.yaml'
)

docker @($compose + @(
  '-f', 'deploy/preview/compose.mailpit-operator.yaml',
  'up', '--detach', '--no-build', '--force-recreate', 'mailpit'
))
# Browse http://127.0.0.1:8025, or the configured loopback port.

docker @($compose + @(
  'up', '--detach', '--no-build', '--force-recreate', '--wait', 'mailpit'
))
```

The operator overlay adds one temporary non-internal bridge because Docker does
not publish ports from the private `internal` backend network. The closing
command removes that bridge and port while purging captured message content.
Never add Mailpit to Nginx or bind its UI to a non-loopback address.

After deploying one exact candidate, use the
[Preview onboarding rehearsal](preview-onboarding-rehearsal.md) to create three
fresh verified identities through captured delivery, prove both invitation and
QR enrollment with the existing child verifiers, retain minimized evidence,
and perform explicit workspace, membership, session, and mailbox cleanup.

`migrations` is a one-shot gate. It applies every module's PostgreSQL migrations before API or Worker startup and can be rerun safely:

```powershell
.\eng\preview.ps1 migrate
```

Schema rollback is restore-based, not an automatic down-migration. Take and verify a backup before deploying a migration that cannot tolerate application rollback.

Before promoting a production candidate, run the isolated
[Production migration rehearsal](production-migration-rehearsal.md). It uses the
same Production `Plan` and approved `Apply` admission path against a disposable,
internal PostgreSQL target and retains non-secret evidence without changing the
preview deployment.

Publish retained exact candidate bytes through the
[image candidate promotion](image-candidate-promotion.md) boundary. Production
hosts require the resulting release id and promotion evidence reference, plus a
separately approved rollback or recovery evidence reference. Before those hosts
start, preallocate one unique admission-attempt identity as described by the
[Production admission evidence boundary](production-admission-evidence.md) and
configure the same identity on Public API, Admin API, and Worker.

Before admission, run the
[deployed release rollback rehearsal](deployed-release-rollback-rehearsal.md)
against the candidate environment with a previously promoted compatible
release. Retain its closed evidence with the migration rehearsal and relevant
authenticated domain probes; the public smoke alone does not prove complete
schema or domain compatibility.

After every release-bound probe and private rehearsal is complete, use the
[Production admission evidence boundary](production-admission-evidence.md) to
validate and hash-bind the exact candidate evidence set. Its output is an input
to private release approval, not an approval or deployment command.

## First Owner

Password and enabled external-provider registration are available through the browser. A new account has no PMS access until it creates a workspace or accepts an active invitation or enrollment link. Creating a workspace grants its creator the first tenant-scoped owner membership and provisions the linked Staff profile.

The bootstrap identity remains an explicit administration actor, not a hidden default user. Use the CLI path below for recovery, automated provisioning, or deployments that intentionally override the self-registration settings. The CLI profile is transient and does not publish a port.

```powershell
$compose = @(
  'compose', '--env-file', 'deploy/preview/.env',
  '-f', 'deploy/preview/compose.yaml', '--profile', 'tools'
)

docker @compose run --rm admin-cli `
  -t default -a bootstrap-owner admin bootstrap --yes

docker @compose run --rm admin-cli `
  -t default -a bootstrap-owner -o json auth members create `
  --username owner@example.com --username-type email --generate-password

docker @compose run --rm admin-cli `
  -t default -a bootstrap-owner admin roles assign `
  --target-kind admin-actor --target-id <member-id> --role owner --scope global

docker @compose run --rm admin-cli `
  -t default -a bootstrap-owner admin roles assign `
  --target-kind user --target-id <member-id> --role owner --scope tenant:default
```

Store the generated password immediately and sign in through the browser. The `admin-actor` grant authorizes the separate management surface; the `user` grant authorizes product policies. Both deliberately use the Auth member id, but remain distinct AccessControl subjects. Bootstrap is guarded by AccessControl and cannot create a second first owner.

## Staff Access Operations

Start the Admin API only for an operations window. It binds to loopback, stays
off the public edge network, does not restart automatically, and still requires
an owner/admin bearer token. The public Nginx container is edge-only and cannot
reach the Admin API or stateful backend services directly.

```powershell
.\eng\preview.ps1 open-operations
.\eng\operations\verify-preview-isolation.ps1
$env:BUNKFY_ADMIN_TOKEN = '<short-lived-access-token>'

.\eng\operations\provision-staff-access.ps1 `
  -TenantId default `
  -Username staff@example.com `
  -DisplayName 'Front desk' `
  -RoleName operator
```

Close the management window as soon as the operation is complete. This stops
and removes only the Admin API container and its dedicated empty network; the
product stack keeps running.
Operational scripts accept plain HTTP only for a loopback Admin API origin;
any remote management endpoint must use HTTPS.

For a deployed candidate, run the paired
[Admin API boundary verifier](deployed-admin-boundary-verification.md) from one
approved management host and one external host. Use the same evidence-set id
for both runs. The pair proves that the Admin API is absent from the public
edge, reachable and auth-gated inside the management boundary, and denied or
unreachable outside it without using an Admin credential.

```powershell
.\eng\preview.ps1 close-operations
Remove-Item Env:BUNKFY_ADMIN_TOKEN
```

The provisioning journal under `.tmp/operations` contains identifiers and completed steps, never credentials. Re-running the same command resumes safely. Use that journal for offboarding:

```powershell
.\eng\operations\offboard-staff-access.ps1 `
  -StatePath .tmp\operations\provision-staff_example.com.json `
  -Reason 'Employment ended' `
  -Confirm:$false
```

Offboarding removes journaled roles, revokes sessions, disables Auth, ends current property assignments, and marks Staff departed. AccessControl protects the last owner from accidental removal.

For an externally observed two-account invitation and property-scope proof,
use the [deployed workspace invitation verifier](deployed-workspace-invitation-verification.md).
It intentionally creates a real membership and Staff profile, so run it with a
dedicated smoke identity and offboard that identity explicitly after retaining
the result. The companion [workspace enrollment verifier](deployed-workspace-enrollment-verification.md)
proves owner rejection and approval for reusable QR enrollment. Complete the
[deployed browser rehearsal](deployed-workspace-browser-rehearsal.md) against
the same candidate to verify registration adapters, mail or identity-provider
delivery, redirect continuity, QR rendering, and Worker restart recovery.
Repository API probes deliberately do not claim those deployment facts.
For the self-contained Preview composition, run
`eng/operations/rehearse-preview-browser-onboarding.ps1` with the exact release
id and protected environment path. Its default path includes the guarded Worker
restart; `-SkipWorkerRestart` is diagnostic only.

For a reversible, two-account proof of product notification projection, actor
exclusion, individual read state, and the durable SSE feed, use the
[deployed Operations Notifications verifier](deployed-operations-notifications-verification.md).
It creates and releases one inventory block and retains the released block plus
two notification-history records as smoke evidence.
For a self-contained Preview run, add `-IncludeOperationsNotifications` to the
Preview onboarding rehearsal. That opt-in contributor reuses the synthetic
owner and property-scoped Staff applicant, provisions one temporary room-level
unit, writes a separate admission-compatible notification child proof, and
retires the room before the onboarding cleanup continues.

Use the mutation-bearing
[deployed Reservations and Inventory verifier](deployed-reservations-inventory-verification.md)
to prove direct reservation creation, exact retry stability, asynchronous
allocation, check-in, checkout, and inventory release against one candidate.
Use a future range and a dedicated available unit. A passing run retains one
checked-out synthetic reservation but no active allocation or durable Guest
Record.
For a self-contained Preview run, add `-IncludeReservationsInventory` to the
Preview onboarding rehearsal. It discovers and activates the one mounted
engineering/example policy through the public Properties API, provisions and
retires a temporary sellable room, and binds the scrubbed child proof into the
onboarding evidence.

For a provider-to-Ingestion proof through a target remote AdapterHost, use the
[deployed AdapterHost verifier](deployed-adapter-host-verification.md). Start the
read-only probe before placing one valid synthetic non-PII record in the real
provider boundary. Complete its separate restart and credential-rotation
rehearsal before promotion; repository automation cannot attest orchestrator or
secret-store behavior.
For a self-contained Preview composition proof, add `-IncludeAdapterHost` plus
the exact backend image digest and backend source commit to the onboarding
rehearsal. It launches a transient connection-scoped container rather than a
static Compose singleton, proves an upsert and cancellation, and removes its
credential, connection runtime, volumes, reservation, and room before parent
cleanup.

## Retention

The Worker owns bounded cleanup. Current preview windows are:

| Data | Window |
| --- | --- |
| Processed outbox / inbox | 7 / 14 days |
| Auth exchange / session history | 1 / 365 days |
| Read / unread notifications | 90 / 365 days |
| Task success / failure history | 30 / 90 days |
| Ingestion raw evidence / sensitive history | 30 / 90 days |
| File-drop processed / failed artifacts | 7 / 30 days |

The Retention module now reconciles tenant-scoped schedules automatically for
every active workspace and property-scoped schedules for each
processing-enabled property. TaskRuntime owns occurrences, leases, retries,
and worker recovery; no recurring Admin CLI enqueue is required.

Use the [deployed Retention verifier](deployed-retention-verification.md) to
observe a fresh hourly occurrence through the tenant-scoped public contract and
require the full returned catalogue to be current and healthy. The probe is
read-only; maintenance-owner topology, owner-local deletion, restart recovery,
and alert delivery remain deployment-owned evidence.

```powershell
docker @compose run --rm admin-cli -t default -a bootstrap-owner retention list
```

Use that recovery-oriented view, or Workspace settings in the browser, to
inspect due, overdue, held, or repeatedly failing schedules. Legal holds remain
authoritative and exclude protected evidence from deletion or redaction.

## Backup And Restore

Create a consistent backup during a brief write outage:

```powershell
.\eng\operations\backup-preview.ps1 -Confirm:$false
```

The script stops the application writers, takes a PostgreSQL custom dump,
archives MinIO, NATS, Redis, Data Protection, the protected Data Rights ledger
and tenant-termination replay journal, and adapter input volumes, writes
SHA-256 hashes, and restores the previous
running service set. It refuses to create a backup if any declared state volume
is missing, if a migration or Admin CLI writer is active, or if the dump or an
archive fails structural validation. The destination is private before the
first state byte is written. Docker volume archives are copied out of a
disposable utility container as the invoking operator, and the completed tree
uses `0700` directories and `0600` files on Unix or the equivalent protected
Windows ACL.

Repair one or more older local backup trees before restore or rehearsal:

```powershell
.\eng\operations\protect-preview-local-state.ps1 `
  -BackupPath .tmp\backups\preview-<timestamp>
```

The repair rejects links, tightens ownership and permissions, then rereads the
tree through the same policy used by restore. It does not alter file content;
the existing manifest digests remain authoritative.
Copy the resulting `.tmp/backups/preview-*` directory to independent encrypted
storage. Keep the `manifest.sha256` value separately from the backup location;
the colocated sidecar detects corruption but is not a signature against an
attacker who can replace both files.

The protected Data Rights ledger is monotonic recovery state, not ordinary
point-in-time application state. Replicate its archive independently and retain
the latest trusted SHA-256 after each backup. A database restore must use the
newest available ledger snapshot so post-backup anonymisation tombstones are
replayed before readiness.

Restore only into an empty, stopped preview deployment:

```powershell
.\eng\operations\restore-preview.ps1 `
  -BackupPath .tmp\backups\preview-<timestamp> `
  -ExpectedManifestSha256 <out-of-band-manifest-sha256> `
  -ProtectedLedgerSnapshotPath <latest-ledger-snapshot.tar.gz> `
  -ProtectedLedgerSnapshotSha256 <trusted-ledger-sha256> `
  -Confirm:$false
```

The restore command verifies the versioned state contract, closed artifact set,
manifest sidecar and optional out-of-band digest, lengths, SHA-256 hashes,
archive structure, a clean operations checkout, and immutable local backend/web
image IDs before creating state. It also requires a private backup tree and a
private separately supplied protected-ledger snapshot before reading either.
Root, backend, and web commits are retained as
provenance; compatible newer operations tooling may restore an older backup
without rebuilding or substituting its recorded images. Schema 2 backups map
to state-contract version 1, schemas 3 and 4 declare that contract explicitly,
and schema 4 also records the protected-ledger recovery policy. Schema 5 uses
state-contract version 2 and adds the tenant-termination replay archive. When
restoring an older contract, the tooling creates the new replay volume empty
because those backups never captured that process-local state. Restore refuses
a target that already has Compose
containers, networks, or any declared volume, restores the non-database state
first, runs `pg_restore --exit-on-error`, and then starts the full stack through
the migration gate. Make the recorded backend and web images available locally
before restoring; restore never rebuilds source.

If the ordinary Preview tags now point to a newer candidate, keep them intact.
Give the historical bytes separate local references and select them explicitly:

```powershell
.\eng\operations\restore-preview.ps1 `
  -BackupPath .tmp\backups\preview-<timestamp> `
  -ExpectedManifestSha256 <out-of-band-manifest-sha256> `
  -ProtectedLedgerSnapshotPath <latest-ledger-snapshot.tar.gz> `
  -ProtectedLedgerSnapshotSha256 <trusted-ledger-sha256> `
  -BackendImage bunkfy/backend:recovery-<release> `
  -WebImage bunkfy/web:recovery-<release> `
  -Confirm:$false
```

The selected references are only locators. Restore inspects their immutable
local image IDs and rejects either reference unless its bytes exactly match the
corresponding backup record. The same `BUNKFY_BACKEND_IMAGE` and
`BUNKFY_WEB_IMAGE` selectors may be placed in a protected Preview environment
for an intentional `preview.ps1 up -NoBuild`; ordinary builds and starts retain
the tracked default tags.

For a rehearsal on the same host, copy the ignored environment file, choose a
different loopback port, and set unique values for
`BUNKFY_COMPOSE_PROJECT_NAME` and `BUNKFY_VOLUME_PREFIX`. The production target
uses the ordinary environment only after its old containers and named volumes
have been deliberately removed.

The [preview recovery rehearsal](preview-recovery-rehearsal.md) automates that
isolated target, validates Data Protection file continuity, reruns the public
edge and loopback Admin checks, records bounded evidence, and removes the clone.

For a disposable isolated rehearsal of one backup, where no later deletion can
exist by definition, use `-AllowBackupPointProtectedLedger`. Never use that
switch to recover a workspace that could have accepted writes after the backup.
`-RemoveFailedTarget` may be used for a uniquely named rehearsal target; omit it
for incident recovery when the partial state must remain available for analysis.

After restore, verify migrations, `/healthz`, `/api/smoke`, sign-in, one file
read, and one background task.

Restore PostgreSQL and the Data Protection key ring from the same backup. Losing or mismatching the key ring invalidates protected browser state and can make protected payloads unreadable.
The backup deliberately excludes `.env` and all secrets. Retain the matching
secret-store versions independently and restore the same JWT, refresh-token,
data-rights, object-store, broker, and database credentials with the state.
Private local modes and ACLs reduce accidental host-user exposure; they do not
encrypt the backup, protect a compromised operator account, establish immutable
retention, or replace approved hosted backup access and recovery controls.

## Capability Gates

Email verification is shown only when the running API has both the BunkFy SMTP
adapter and GMA notification email sink enabled. Preview may satisfy that gate
with private Mailpit capture; Production still requires an approved real
provider and deployment evidence. OIDC providers remain absent from the UI
until their adapters are enabled and valid credentials are mounted. Disabled
capabilities do not pretend to work.
