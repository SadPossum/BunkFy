# Preview Recovery Rehearsal

Use this destructive-but-isolated rehearsal to prove that a schema-4 preview
backup can restore into a fresh Compose project without replacing the existing
preview deployment. It exercises the repository restore automation, public
edge, loopback Admin surface, startup readiness, and exact Data Protection file
continuity.

This is local recovery-mechanics evidence. It is not hosted database,
object-store, secret-store, immutable-ledger, RPO, or RTO evidence.

## Prepare A Recovery Canary

Before taking the backup, use a dedicated smoke account to configure and verify
TOTP through the ordinary Account page. This causes a real authenticator secret
to be protected by the persisted Data Protection key ring. Keep the smoke
account password and TOTP seed in the approved secret store, never in the
backup or repository.

Start the source preview and create a fresh backup:

```powershell
.\eng\operations\backup-preview.ps1 -Confirm:$false
$backup = '.tmp\backups\preview-<timestamp>'
$manifestSha256 = (Get-Content `
  (Join-Path $backup 'manifest.sha256') -Raw).Trim()
```

Copy the backup and manifest digest to their approved independent locations
before treating this as recovery evidence.

Restore and rehearsal reject group/world-readable Unix state, inherited or
broad Windows ACLs, and linked paths before creating a target. For a backup
created before that policy, tighten the local copy first without changing its
bytes:

```powershell
.\eng\operations\protect-preview-local-state.ps1 -BackupPath $backup
```

## Run

```powershell
.\eng\operations\rehearse-preview-recovery.ps1 `
  -BackupPath $backup `
  -ExpectedManifestSha256 $manifestSha256 `
  -Confirm:$false
```

When the backup's original local tags now point to newer bytes, supply
`-BackendImage` and `-WebImage` with separate local historical references. The
ordinary restore guard still requires those images to match the immutable IDs
recorded by the backup. The rehearsal carries the same selections into the
isolated public and Admin checks without changing the live Preview tags.

The runner generates a unique Compose project, volume prefix, and loopback
ports. It invokes the ordinary restore command with the backup-point protected
ledger switch because the target is a disposable clone of that exact backup;
it never uses that exception for incident recovery. The clone is removed with
all of its volumes after checks pass or fail.

Passing evidence is written under `.tmp/recovery-rehearsals`. It records the
backup id and manifest digest, state-contract version, bounded timing, five
check results, and explicit limitations. It does not retain key-tree hashes,
file names, credentials, cookies, tokens, response bodies, or headers.

The private local permission check is a host hygiene control only. The hosted
recovery record must still prove encrypted storage, approved identities,
retention policy, and independent restore access.

## Checks

The rehearsal requires:

- a schema-4 manifest matching the separately supplied digest;
- verified artifact hashes and structurally readable archives and PostgreSQL
  dump before target creation;
- an empty isolated target restored through the migration/readiness gate;
- the full public edge probe after recovery;
- loopback Admin health plus anonymous authorization denial; and
- a non-empty restored Data Protection tree that exactly matches the backup by
  canonical file count, length, path, and content hashing.

The comparison proves storage continuity but does not ask the application to
decrypt an existing authenticator. For that final application-level check, run
with `-KeepRestoredTarget`, sign in through the printed public origin with the
dedicated smoke account and a current TOTP code, read one known file, and
observe one background task. Record those facts privately, then remove the
isolated project and volumes using the project, volume prefix, and ports in the
rehearsal evidence.

Do not use a personal account or recovery code as the canary. Do not retain the
restored target after the check.

## Production Boundary

A hosted launch still needs a provider-native restore into an isolated account
or namespace, the newest independently durable Data Rights ledger checkpoint,
the matching secret-store versions, replacement-replica TOTP or OIDC
decryption, object reads, worker recovery, allowed and denied Admin-network
proof, alert delivery, and measured RPO/RTO. The preview runner intentionally
does not accept provider credentials or claim those facts.
