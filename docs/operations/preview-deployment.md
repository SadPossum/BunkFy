# Preview Deployment

This is the production-shaped single-node preview path for BunkFy. It packages the current domains without introducing another business module. Aspire remains the local development path.

## Prepare

Requirements: Docker with Compose v2 and PowerShell 7.

```powershell
.\eng\new-preview-env.ps1
```

Review `deploy/preview/.env`, set `BUNKFY_PUBLIC_URL` to the externally visible HTTPS origin, and register this callback with each enabled OIDC provider:

```text
https://your-bunkfy-host/auth/complete
```

The generated file is ignored by Git. Keep it in the server secret store or protected deployment workspace. PostgreSQL and NATS credentials must remain URL/connection-string safe.

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

## First Owner

The bootstrap identity is an explicit administration actor, not a hidden default user. Run bootstrap once, create the first Auth member, then grant that member the tenant owner role. The CLI profile is transient and does not publish a port.

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

Start the Admin API only for an operations window. It binds to loopback and still requires an owner/admin bearer token.

```powershell
.\eng\preview.ps1 up -Operations
$env:BUNKFY_ADMIN_TOKEN = '<short-lived-access-token>'

.\eng\operations\provision-staff-access.ps1 `
  -TenantId default `
  -Username staff@example.com `
  -DisplayName 'Front desk' `
  -RoleName operator
```

The provisioning journal under `.tmp/operations` contains identifiers and completed steps, never credentials. Re-running the same command resumes safely. Use that journal for offboarding:

```powershell
.\eng\operations\offboard-staff-access.ps1 `
  -StatePath .tmp\operations\provision-staff_example.com.json `
  -Reason 'Employment ended' `
  -Confirm:$false
```

Offboarding removes journaled roles, revokes sessions, disables Auth, ends current property assignments, and marks Staff departed. AccessControl protects the last owner from accidental removal.

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

Ingestion retention tasks are tenant-scoped and must be scheduled for every active tenant. Until recurring TaskRuntime schedules are provisioned, enqueue both operations from a trusted scheduler or maintenance window:

```powershell
docker @compose run --rm admin-cli -t default -a bootstrap-owner `
  ingestion retention purge-raw-payloads
docker @compose run --rm admin-cli -t default -a bootstrap-owner `
  ingestion retention redact-reservation-history
```

Legal holds remain authoritative and exclude protected evidence from deletion/redaction.

## Backup And Restore

Create a consistent backup during a brief write outage:

```powershell
.\eng\operations\backup-preview.ps1 -Confirm:$false
```

The script stops the application writers, takes a PostgreSQL custom dump, archives MinIO, NATS, Redis, Data Protection, and adapter input volumes, writes SHA-256 hashes, and restores the previous default stack. Copy the resulting `.tmp/backups/preview-*` directory to independent encrypted storage.

Restore only into an empty, stopped preview deployment:

1. Verify every artifact against `manifest.json` and check out the recorded root/backend/web commits.
2. Run `docker compose ... down --volumes` only after confirming the target is the intended preview project.
3. Recreate each named volume and extract its matching archive with a disposable container.
4. Start PostgreSQL alone, copy `postgres.dump` into it, and run `pg_restore --clean --if-exists --no-owner -U bunkfy -d bunkfy`.
5. Start the full stack and verify migrations, `/healthz`, `/api/smoke`, sign-in, one file read, and one background task.

Restore PostgreSQL and the Data Protection key ring from the same backup. Losing or mismatching the key ring invalidates protected browser state and can make protected payloads unreadable.

## Capability Gates

Email verification remains hidden and email delivery disabled until a real `IEmailSender` adapter and sender configuration are deployed. OIDC providers remain absent from the UI until their adapters are enabled and valid credentials are mounted. This keeps optional infrastructure honest: disabled capabilities do not pretend to work.
