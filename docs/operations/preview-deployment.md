# Preview Deployment

This is the production-shaped single-node preview path for BunkFy. It packages the current domains without introducing another business module. Aspire remains the local development path.

The stack uses the explicit `Preview` environment so its protected
data-rights replay ledger can use one integrity-keyed local provider shared by
API, Worker and management hosts. The provider lives on its own named volume
and is never a production topology: Production still requires a separately
registered external, production-grade ledger provider.

## Prepare

Requirements: Docker with Compose v2, PowerShell 7, and recursively initialized
submodules.

```powershell
.\eng\new-preview-env.ps1
```

Review `deploy/preview/.env`, set `BUNKFY_PUBLIC_URL` to the externally visible HTTPS origin, and register this callback with each enabled OIDC provider:

```text
https://your-bunkfy-host/auth/complete
```

The generated file is ignored by Git. Keep it in the server secret store or protected deployment workspace. PostgreSQL and NATS credentials must remain URL/connection-string safe.

`preview.ps1 build` and `preview.ps1 up` refresh the backend's ignored GMA
source-root maps before invoking Docker, so a clean recursive checkout packages
the same source composition validated by CI.

## Start And Verify

```powershell
.\eng\preview.ps1 config
.\eng\preview.ps1 up
.\eng\preview.ps1 status
```

The browser app is available on loopback at `http://127.0.0.1:8080` by default. The API is reachable only through the same-origin Nginx route. PostgreSQL, Redis, NATS, and MinIO have no host ports.

The Compose host intentionally does not terminate TLS. A remote deployment must place an HTTPS reverse proxy or ingress in front of the loopback web port and preserve forwarded headers. Do not expose the API, Admin API, databases, broker, or object storage directly.

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

For a reversible, two-account proof of product notification projection, actor
exclusion, individual read state, and the durable SSE feed, use the
[deployed Operations Notifications verifier](deployed-operations-notifications-verification.md).
It creates and releases one inventory block and retains the released block plus
two notification-history records as smoke evidence.

For a provider-to-Ingestion proof through a target remote AdapterHost, use the
[deployed AdapterHost verifier](deployed-adapter-host-verification.md). Start the
read-only probe before placing one valid synthetic non-PII record in the real
provider boundary. Complete its separate restart and credential-rotation
rehearsal before promotion; repository automation cannot attest orchestrator or
secret-store behavior.

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
archives MinIO, NATS, Redis, Data Protection, the protected data-rights ledger
and adapter input volumes, writes SHA-256 hashes, and restores the previous
running service set. It refuses to create a backup if any declared state volume
is missing, if a migration or Admin CLI writer is active, or if the dump or an
archive fails structural validation.
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
image IDs before creating state. Root, backend, and web commits are retained as
provenance; compatible newer operations tooling may restore an older backup
without rebuilding or substituting its recorded images. Schema 2 backups map
to state-contract version 1, schemas 3 and 4 declare that contract explicitly,
and schema 4 also records the protected-ledger recovery policy. Restore refuses
a target that already has Compose
containers, networks, or any declared volume, restores the non-database state
first, runs `pg_restore --exit-on-error`, and then starts the full stack through
the migration gate. Make the recorded backend and web images available locally
before restoring; restore never rebuilds source.

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

## Capability Gates

Email verification remains hidden and email delivery disabled until a real `IEmailSender` adapter and sender configuration are deployed. OIDC providers remain absent from the UI until their adapters are enabled and valid credentials are mounted. This keeps optional infrastructure honest: disabled capabilities do not pretend to work.
