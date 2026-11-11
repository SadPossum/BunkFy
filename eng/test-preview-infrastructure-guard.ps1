Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'operations\preview-storage.common.ps1')
. (Join-Path $PSScriptRoot 'operations\preview-state.common.ps1')
. (Join-Path $PSScriptRoot 'operations\local-sensitive-state.common.ps1')
$root = Get-BunkFyRepositoryRoot
$composePath = Join-Path $root 'deploy/preview/compose.yaml'
$template = Join-Path $root 'deploy/preview/.env.example'
$originalProfileExists = Test-Path Env:BUNKFY_INFRA_PROFILE
$originalProfile = [Environment]::GetEnvironmentVariable('BUNKFY_INFRA_PROFILE')
$originalGeneration = [Environment]::GetEnvironmentVariable('BUNKFY_INFRA_GENERATION')
try {
    $env:BUNKFY_INFRA_PROFILE = 'legacy'
    $env:BUNKFY_INFRA_GENERATION = '1'
    $legacy = Get-BunkFyPreviewComposeDefinition -Root $root -ComposePath $composePath -EnvironmentPath $template
    $env:BUNKFY_INFRA_PROFILE = 'maintained'
    $env:BUNKFY_INFRA_GENERATION = '2'
    $maintained = Get-BunkFyPreviewComposeDefinition -Root $root -ComposePath $composePath -EnvironmentPath $template
}
finally {
    [Environment]::SetEnvironmentVariable('BUNKFY_INFRA_GENERATION', $originalGeneration)
    if ($originalProfileExists) { [Environment]::SetEnvironmentVariable('BUNKFY_INFRA_PROFILE', $originalProfile) }
    else { Remove-Item Env:BUNKFY_INFRA_PROFILE -ErrorAction SilentlyContinue }
}
# Fixture strings from reviewed policy, not inspected local Docker images.
# Hosted image/config and signature verification are separate gates.
$ids = [ordered]@{}
foreach ($entry in (Get-BunkFyPreviewInfrastructurePolicy).profiles.maintained.configurationIds.PSObject.Properties) {
    $ids[$entry.Name] = [string]$entry.Value
}
$ids['minio'] = (Get-Content -LiteralPath (Join-Path $root '.gma/preview-storage-review.json') -Raw | ConvertFrom-Json).imageConfigDigest
$script:DaemonCalls = 0
function docker { $script:DaemonCalls++; throw 'Pure infrastructure guard unexpectedly called Docker.' }
function Copy-Value([object] $Value) { return $Value | ConvertTo-Json -Depth 50 | ConvertFrom-Json }
$cases = [Collections.Generic.List[object]]::new()
function Check-Case([string] $Name, [scriptblock] $Action, [bool] $Reject = $false) {
    $caught = $null
    try { & $Action | Out-Null }
    catch { $caught = $_ }
    $passed = if ($Reject) { $null -ne $caught } else { $null -eq $caught }
    $cases.Add([pscustomobject]@{ name = $Name; passed = $passed; expectedRejection = $Reject;
        error = if ($null -ne $caught) { [string]$caught.Exception.Message } else { $null } })
}

Check-Case 'actual-resolved-legacy-profile' {
    if ((Get-BunkFyPreviewInfrastructureProfile $legacy).Name -cne 'legacy') { throw 'Wrong legacy profile.' }
}
Check-Case 'actual-resolved-maintained-profile' {
    if ((Get-BunkFyPreviewInfrastructureProfile $maintained).Name -cne 'maintained') { throw 'Wrong maintained profile.' }
}
$record = New-BunkFyPreviewInfrastructureRecord -ComposeDefinition $maintained -ImageIds $ids
$manifest = Copy-Value ([pscustomobject]@{ schemaVersion = 7; infrastructure = $record })
Check-Case 'old-maintained-volume-generation-rejected' {
    $bad = Copy-Value $maintained
    $bad.volumes.'postgres-data'.labels.'com.bunkfy.preview.infrastructure-generation' = 'maintained:1'
    Assert-BunkFyPreviewInfrastructureVolumes $bad
} $true
Check-Case 'actual-maintained-schema7-roundtrip' {
    Assert-BunkFyPreviewBackupInfrastructure $manifest $maintained $ids
}
foreach ($schema in @(2, 3, 4, 5, 6)) {
    Check-Case "legacy-schema-$schema-retained-on-original-images" {
        Assert-BunkFyPreviewBackupInfrastructure ([pscustomobject]@{ schemaVersion = $schema }) $legacy
    }
}
Check-Case 'legacy-backup-rejected-on-maintained-servers' {
    Assert-BunkFyPreviewBackupInfrastructure ([pscustomobject]@{ schemaVersion = 5 }) $maintained
} $true
Check-Case 'downgraded-schema-with-new-infrastructure-metadata-rejected' {
    $bad = Copy-Value $manifest; $bad.schemaVersion = 6
    Assert-BunkFyPreviewBackupInfrastructure $bad $legacy
} $true
Check-Case 'mixed-redis-version-rejected' {
    $bad = Copy-Value $maintained; $bad.services.redis.image = $legacy.services.redis.image
    Get-BunkFyPreviewInfrastructureProfile $bad
} $true
Check-Case 'postgres-root-user-rejected' {
    $bad = Copy-Value $maintained; $bad.services.postgres.user = '0:0'
    Get-BunkFyPreviewInfrastructureProfile $bad
} $true
Check-Case 'postgres-writable-root-rejected' {
    $bad = Copy-Value $maintained; $bad.services.postgres.read_only = $false
    Get-BunkFyPreviewInfrastructureProfile $bad
} $true
Check-Case 'postgres-missing-privilege-boundary-rejected' {
    $bad = Copy-Value $maintained; $bad.services.postgres.PSObject.Properties.Remove('security_opt')
    Get-BunkFyPreviewInfrastructureProfile $bad
} $true
Check-Case 'postgres-extra-capability-rejected' {
    $bad = Copy-Value $maintained; $bad.services.postgres.cap_drop = @()
    Get-BunkFyPreviewInfrastructureProfile $bad
} $true
Check-Case 'postgres-added-capability-rejected' {
    $bad = Copy-Value $maintained
    $bad.services.postgres | Add-Member -NotePropertyName cap_add -NotePropertyValue @('SYS_ADMIN')
    Get-BunkFyPreviewInfrastructureProfile $bad
} $true
Check-Case 'postgres-overridden-entrypoint-rejected' {
    $bad = Copy-Value $maintained; $bad.services.postgres.entrypoint = @('/bin/sh')
    Get-BunkFyPreviewInfrastructureProfile $bad
} $true
Check-Case 'postgres-etc-bind-rejected' {
    $bad = Copy-Value $maintained
    $bad.services.postgres.volumes += [pscustomobject]@{ type = 'bind'; source = '/tmp/not-a-real-group-file'; target = '/etc/group' }
    Get-BunkFyPreviewInfrastructureProfile $bad
} $true
Check-Case 'postgres-root-owned-tmpfs-rejected' {
    $bad = Copy-Value $maintained; $bad.services.postgres.tmpfs[0] = '/var/run/postgresql:size=8388608,uid=0,gid=0,mode=3775'
    Get-BunkFyPreviewInfrastructureProfile $bad
} $true
Check-Case 'equivalent-tmpfs-option-order-retained' {
    $same = Copy-Value $maintained
    $same.services.postgres.tmpfs[0] = '/var/run/postgresql:mode=3775,gid=70,uid=70,size=8388608'
    Get-BunkFyPreviewInfrastructureProfile $same
}
Check-Case 'unreviewed-platform-rejected' {
    $bad = Copy-Value $maintained; $bad.services.postgres.platform = 'linux/arm64'
    Get-BunkFyPreviewInfrastructureProfile $bad
} $true
Check-Case 'backup-image-configuration-mismatch-rejected' {
    $bad = Copy-Value $manifest; $bad.infrastructure.images[0].imageId = 'sha256:' + ('f' * 64)
    Assert-BunkFyPreviewBackupInfrastructure $bad $maintained $ids
} $true
Check-Case 'backup-image-reference-mismatch-rejected' {
    $bad = Copy-Value $manifest; $bad.infrastructure.images[0].reference = $legacy.services.postgres.image
    Assert-BunkFyPreviewBackupInfrastructure $bad $maintained $ids
} $true
Check-Case 'duplicate-component-rejected' {
    $bad = Copy-Value $manifest; $bad.infrastructure.images[1] = Copy-Value $bad.infrastructure.images[0]
    Assert-BunkFyPreviewBackupInfrastructure $bad $maintained $ids
} $true
Check-Case 'missing-component-rejected' {
    $bad = Copy-Value $manifest; $bad.infrastructure.images = @($bad.infrastructure.images | Select-Object -Skip 1)
    Assert-BunkFyPreviewBackupInfrastructure $bad $maintained $ids
} $true
Check-Case 'backup-postgres-execution-mismatch-rejected' {
    $bad = Copy-Value $manifest; $bad.infrastructure.postgresExecution.user = '0:0'
    Assert-BunkFyPreviewBackupInfrastructure $bad $maintained $ids
} $true
Check-Case 'missing-local-image-identity-rejected' {
    $badIds = @{}; foreach ($entry in $ids.GetEnumerator()) { $badIds[$entry.Key] = $entry.Value }
    $badIds.Remove('nats')
    Assert-BunkFyPreviewBackupInfrastructure $manifest $maintained $badIds
} $true
Check-Case 'matching-backup-and-target-with-unqualified-configuration-rejected' {
    $badIds = @{}; foreach ($entry in $ids.GetEnumerator()) { $badIds[$entry.Key] = $entry.Value }
    $badIds.postgres = 'sha256:' + ('f' * 64)
    $bad = Copy-Value $manifest; $bad.infrastructure.images[0].imageId = $badIds.postgres
    Assert-BunkFyPreviewBackupInfrastructure $bad $maintained $badIds
} $true
Check-Case 'pure-guards-create-no-daemon-resources' {
    if ($script:DaemonCalls -ne 0) { throw 'A guard attempted a Docker operation.' }
}

$fixture = [pscustomobject]@{
    Mode = 'volume'; Compose = $maintained; Volumes = @{}; Containers = @{}
    ImageIds = @{}; Calls = [Collections.Generic.List[string]]::new()
    RecoveryProbeCount = 0; RecoveryTemporaryRoot = $null
    SnapshotPermissionFailures = [Collections.Generic.List[string]]::new()
    ExistingRecoveryDirectories = @()
}
$references = Get-BunkFyPreviewInfrastructureReferences $maintained
foreach ($entry in $references.GetEnumerator()) { $fixture.ImageIds[$entry.Value] = $ids[$entry.Key] }
$backendId = 'sha256:' + ('a' * 64)
$webId = 'sha256:' + ('b' * 64)
$fixture.ImageIds[[string]$maintained.services.api.image] = $backendId
$fixture.ImageIds[[string]$maintained.services.web.image] = $webId
$dockerShim = {
    $fixture.Calls.Add(($args -join ' '))
    $global:LASTEXITCODE = 0
    if ($fixture.Mode -ceq 'recovery-failure' -and $args[0] -ceq 'run') {
        # This shim lives in a closure module when invoked by the full suite.
        # Import its permission predicates there rather than relying on caller scope.
        . (Join-Path $root 'eng/operations/local-sensitive-state.common.ps1')
        $fixture.RecoveryProbeCount++
        $new = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'bunkfy-recovery-*' |
                Where-Object { $_.FullName -cnotin $fixture.ExistingRecoveryDirectories })
        if ($new.Count -ne 1) { throw 'The fixture did not observe one new recovery workspace.' }
        $fixture.RecoveryTemporaryRoot = $new[0].FullName
        foreach ($path in @($new[0].FullName, (Join-Path $new[0].FullName 'archive-key-ring'),
                (Join-Path $new[0].FullName 'restored-key-ring'))) {
            try { Assert-BunkFyLocalSensitivePath -Path $path -PathType Container -Description 'Recovery key snapshot fixture' }
            catch { $fixture.SnapshotPermissionFailures.Add($_.Exception.Message) }
        }
        # Simulate an unreadable archive before any target resources exist.
        $global:LASTEXITCODE = 1
        return
    }
    if ($fixture.Mode -ceq 'recovery-failure' -and $args[0] -ceq 'compose' -and $args -contains 'down') { return }
    if ($args[0] -ceq 'volume' -and $args[1] -ceq 'ls') { $fixture.Volumes.Keys; return }
    if ($args[0] -ceq 'volume' -and $args[1] -ceq 'inspect') {
        $fixture.Volumes[[string]$args[-1]] | ConvertTo-Json -Compress; return
    }
    if ($args[0] -ceq 'compose' -and $args -contains 'config') {
        $fixture.Compose | ConvertTo-Json -Depth 50; return
    }
    if ($args[0] -ceq 'compose' -and $args -contains 'ps') {
        if ($fixture.Mode -ceq 'container') {
            if ($fixture.Containers.ContainsKey([string]$args[-1])) { [string]$args[-1] }
        }
        return
    }
    if ($args[0] -ceq 'network' -and $args[1] -ceq 'ls') { return }
    if ($args[0] -ceq 'image' -and $args[1] -ceq 'inspect') {
        $reference = [string]$args[-1]
        if (-not $fixture.ImageIds.ContainsKey($reference)) { $global:LASTEXITCODE = 1; return }
        $fixture.ImageIds[$reference]; return
    }
    if ($args[0] -ceq 'inspect') {
        $fixture.Containers[[string]$args[-1]] | ConvertTo-Json -Depth 12; return
    }
    throw "Infrastructure preflight attempted a Docker mutation: $($args[0])."
}.GetNewClosure()
Set-Item -Path Function:docker -Value $dockerShim

Check-Case 'empty-new-generation-has-no-existing-state-to-reinterpret' {
    Assert-BunkFyPreviewInfrastructureVolumes $maintained
}
foreach ($logicalName in @('postgres-data', 'redis-data', 'nats-data')) {
    $fixture.Volumes = @{ ([string]$maintained.volumes.PSObject.Properties[$logicalName].Value.name) = @{} }
    Check-Case "$logicalName-unlabelled-original-state-rejected-on-maintained" {
        Assert-BunkFyPreviewInfrastructureVolumes $maintained
    } $true
    Check-Case "$logicalName-unlabelled-original-state-retained-on-legacy" {
        Assert-BunkFyPreviewInfrastructureVolumes $legacy
    }
    $fixture.Volumes.Values | ForEach-Object { $_['com.bunkfy.preview.infrastructure-generation'] = 'maintained:2' }
    Check-Case "$logicalName-maintained-state-accepted" {
        Assert-BunkFyPreviewInfrastructureVolumes $maintained
    }
    Check-Case "$logicalName-maintained-state-rejected-on-legacy" {
        Assert-BunkFyPreviewInfrastructureVolumes $legacy
    } $true
}
$fixture.Volumes = @{}
$postgresContainer = [pscustomobject]@{
    Image = $ids.postgres
    Config = [pscustomobject]@{ User = '70:70' }
    HostConfig = [pscustomobject]@{
        ReadonlyRootfs = $true; Privileged = $false; CapDrop = @('ALL'); CapAdd = $null
        SecurityOpt = @('no-new-privileges:true')
        Tmpfs = [pscustomobject]@{
            '/var/run/postgresql' = 'size=8388608,uid=70,gid=70,mode=3775'
            '/tmp' = 'size=33554432,mode=1777'
        }
    }
    Mounts = @([pscustomobject]@{
            Type = 'volume'; Name = $maintained.volumes.'postgres-data'.name
            Destination = '/var/lib/postgresql/data'
        })
}
$fixture.Mode = 'container'
$fixture.Containers = @{ postgres = $postgresContainer }
Check-Case 'actual-container-inspection-profile-accepted' {
    Assert-BunkFyPreviewInfrastructureContainers $maintained @('compose') $ids
}
foreach ($mutation in @('image', 'user', 'writable-root', 'privileged', 'etc-bind', 'capabilities', 'added-capability', 'tmpfs')) {
    $bad = Copy-Value $postgresContainer
    switch ($mutation) {
        'image' { $bad.Image = 'sha256:' + ('f' * 64) }
        'user' { $bad.Config.User = '0:0' }
        'writable-root' { $bad.HostConfig.ReadonlyRootfs = $false }
        'privileged' { $bad.HostConfig.Privileged = $true }
        'etc-bind' { $bad.Mounts += [pscustomobject]@{ Type = 'bind'; Name = ''; Destination = '/etc/group' } }
        'capabilities' { $bad.HostConfig.CapDrop = @() }
        'added-capability' { $bad.HostConfig.CapAdd = @('SYS_ADMIN') }
        'tmpfs' { $bad.HostConfig.Tmpfs.'/tmp' = 'size=33554432,mode=0777' }
    }
    $fixture.Containers.postgres = $bad
    Check-Case "runtime-postgres-$mutation-rejected" {
        Assert-BunkFyPreviewInfrastructureContainers $maintained @('compose') $ids
    } $true
}
$fixture.Containers = @{}
Check-Case 'missing-database-container-rejected' {
    Assert-BunkFyPreviewInfrastructureContainers $maintained @('compose') $ids
} $true

# Invoke the actual operators with private synthetic artifacts. The shim rejects
# every Docker mutation, so a missing admission check cannot pass accidentally.
$fixture.Mode = 'operator'
$temporary = Join-Path ([IO.Path]::GetTempPath()) "bunkfy-infrastructure-operator-$([Guid]::NewGuid().ToString('N'))"
$environmentPath = Join-Path $temporary 'preview.env'
$backupPath = Join-Path $temporary 'backup'
$originalBackend = [Environment]::GetEnvironmentVariable('BUNKFY_BACKEND_IMAGE')
$originalWeb = [Environment]::GetEnvironmentVariable('BUNKFY_WEB_IMAGE')
$originalBackendExists = Test-Path Env:BUNKFY_BACKEND_IMAGE
$originalWebExists = Test-Path Env:BUNKFY_WEB_IMAGE
function git {
    if ($args -contains 'status' -and $args -contains '--porcelain=v1') { $global:LASTEXITCODE = 0; return }
    throw 'Operator fixture attempted an unexpected Git operation.'
}
try {
    New-BunkFyLocalSensitiveDirectory -Path $temporary -Description 'Infrastructure operator fixtures'
    New-BunkFyLocalSensitiveDirectory -Path $backupPath -Description 'Infrastructure fixture backup'
    & (Join-Path $PSScriptRoot 'new-preview-env.ps1') -OutputPath $environmentPath | Out-Null
    $artifacts = @()
    $volumes = @()
    foreach ($name in (@('postgres.dump') + @($script:BunkFyPreviewStateArchives.Values))) {
        $path = Join-Path $backupPath $name
        Write-BunkFyLocalSensitiveTextFile -Path $path -Content 'synthetic fixture bytes' -Description 'Synthetic state artifact'
        $artifacts += [pscustomobject]@{
            file = $name; length = (Get-Item -LiteralPath $path).Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    foreach ($entry in $script:BunkFyPreviewStateArchives.GetEnumerator()) {
        $volumes += [pscustomobject]@{ logicalName = $entry.Key; dockerName = "fixture-$($entry.Key)"; artifact = $entry.Value }
    }
    $operatorManifest = [pscustomobject]@{
        schemaVersion = 7; infrastructure = $record
        objectStorage = [pscustomobject]@{ provider = 'silo'; image = $script:BunkFyPreviewSiloImage }
        backupId = [Guid]::NewGuid().ToString('D'); createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        projectName = 'synthetic-fixture'; repositoryCommit = 'a' * 40; backendCommit = 'b' * 40; webCommit = 'c' * 40
        stateContract = [pscustomobject]@{ name = 'bunkfy-preview-state'; version = 2 }
        stateVolumes = $volumes; artifacts = $artifacts
        protectedLedgerSnapshot = [pscustomobject]@{
            logicalName = 'data-rights-ledger-delta'; artifact = 'data-rights-ledger-delta.tar.gz'
            capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('O'); restorePolicy = 'explicit-current-snapshot-required'
        }
        images = @(
            [pscustomobject]@{ kind = 'backend'; reference = $maintained.services.api.image; imageId = $backendId }
            [pscustomobject]@{ kind = 'web'; reference = $maintained.services.web.image; imageId = $webId }
        )
    }
    function Save-OperatorManifest([object] $Value) {
        $path = Join-Path $backupPath 'manifest.json'
        Write-BunkFyLocalSensitiveTextFile -Path $path -Content ($Value | ConvertTo-Json -Depth 20) -Overwrite -Description 'Synthetic manifest'
        $digest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-BunkFyLocalSensitiveTextFile -Path (Join-Path $backupPath 'manifest.sha256') -Content $digest -Overwrite -Description 'Synthetic manifest digest'
        return $digest
    }
    $restore = Join-Path $PSScriptRoot 'operations/restore-preview.ps1'
    $recovery = Join-Path $PSScriptRoot 'operations/rehearse-preview-recovery.ps1'
    foreach ($variant in @('current', 'image-mismatch', 'profile-mismatch', 'missing-component', 'downgraded-metadata', 'old-backup-on-new-servers')) {
        $value = Copy-Value $operatorManifest
        switch ($variant) {
            'image-mismatch' { $value.infrastructure.images[0].imageId = 'sha256:' + ('f' * 64) }
            'profile-mismatch' { $value.infrastructure.profile = 'legacy' }
            'missing-component' { $value.infrastructure.images = @($value.infrastructure.images | Select-Object -Skip 1) }
            'downgraded-metadata' { $value.schemaVersion = 6 }
            'old-backup-on-new-servers' { $value.schemaVersion = 6; $value.PSObject.Properties.Remove('infrastructure') }
        }
        $manifestDigest = Save-OperatorManifest $value
        foreach ($operator in @($restore, $recovery)) {
            $fixture.Calls.Clear()
            $caught = $null
            try {
                if ($operator -ceq $restore) {
                    & $operator -BackupPath $backupPath -EnvironmentPath $environmentPath `
                        -ExpectedManifestSha256 $manifestDigest -AllowBackupPointProtectedLedger -WhatIf
                }
                else {
                    & $operator -BackupPath $backupPath -EnvironmentPath $environmentPath `
                        -ExpectedManifestSha256 $manifestDigest -WhatIf
                }
            }
            catch { $caught = $_ }
            $name = [IO.Path]::GetFileNameWithoutExtension($operator)
            if ($variant -ceq 'current' -and $null -ne $caught) { throw $caught }
            if ($variant -cne 'current' -and ($null -eq $caught -or
                    $caught.Exception.Message -notmatch '(infrastructure|Older backups)')) {
                throw "$name did not reject '$variant' at the infrastructure admission boundary: $caught"
            }
            if (@($fixture.Calls | Where-Object { $_ -cmatch '^(run|create|pull|start|rm) ' -or $_ -match ' (create|up|stop|down) ' }).Count -ne 0) {
                throw "$name created or changed resources during preflight."
            }
            $cases.Add([pscustomobject]@{ name = "$name-$variant-before-target-resources"; passed = $true; expectedRejection = $variant -cne 'current'; error = $null })
        }
    }
    # Original schema-6/Silo backups still pass both operators on original servers.
    $fixture.Compose = $legacy
    $value = Copy-Value $operatorManifest
    $value.schemaVersion = 6; $value.PSObject.Properties.Remove('infrastructure')
    $manifestDigest = Save-OperatorManifest $value
    & $restore -BackupPath $backupPath -EnvironmentPath $environmentPath `
        -ExpectedManifestSha256 $manifestDigest -AllowBackupPointProtectedLedger -WhatIf
    & $recovery -BackupPath $backupPath -EnvironmentPath $environmentPath `
        -ExpectedManifestSha256 $manifestDigest -WhatIf
    $cases.Add([pscustomobject]@{ name = 'actual-operators-retain-original-schema6-on-legacy-servers'; passed = $true; expectedRejection = $false; error = $null })
    $fixture.Compose = Copy-Value $legacy
    $fixture.Compose.services.minio.image = $script:BunkFyPreviewLegacyStorageImage
    $fixture.Compose.services.minio.PSObject.Properties.Remove('platform')
    $fixture.Compose.volumes.'minio-data'.labels.'com.bunkfy.preview.storage-provider' = 'legacy-minio'
    $fixture.Compose.volumes.'minio-data'.labels.'com.bunkfy.preview.storage-image' = $script:BunkFyPreviewLegacyStorageImage
    $value.schemaVersion = 5; $value.PSObject.Properties.Remove('objectStorage')
    $manifestDigest = Save-OperatorManifest $value
    & $restore -BackupPath $backupPath -EnvironmentPath $environmentPath `
        -ExpectedManifestSha256 $manifestDigest -AllowBackupPointProtectedLedger -WhatIf
    & $recovery -BackupPath $backupPath -EnvironmentPath $environmentPath `
        -ExpectedManifestSha256 $manifestDigest -WhatIf
    $cases.Add([pscustomobject]@{ name = 'actual-operators-retain-original-schema5-MinIO-on-legacy-servers'; passed = $true; expectedRejection = $false; error = $null })

    $fixture.Mode = 'recovery-failure'
    $fixture.Compose = $maintained
    $manifestDigest = Save-OperatorManifest (Copy-Value $operatorManifest)
    $recoveryVariables = @('BUNKFY_COMPOSE_PROJECT_NAME', 'BUNKFY_VOLUME_PREFIX',
        'BUNKFY_PUBLIC_PORT', 'BUNKFY_ADMIN_PORT', 'BUNKFY_RELEASE_ID')
    $savedVariables = @{}
    foreach ($name in $recoveryVariables) {
        $savedVariables[$name] = @{ Exists = Test-Path "Env:$name"; Value = [Environment]::GetEnvironmentVariable($name) }
    }
    try {
        foreach ($variant in @('originally-absent', 'originally-present')) {
            foreach ($name in $recoveryVariables) {
                if ($variant -ceq 'originally-absent') { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
                else { [Environment]::SetEnvironmentVariable($name, 'fixture-original-' + $name) }
            }
            $fixture.RecoveryProbeCount = 0
            $fixture.RecoveryTemporaryRoot = $null
            $fixture.SnapshotPermissionFailures.Clear()
            $fixture.ExistingRecoveryDirectories = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) `
                -Directory -Filter 'bunkfy-recovery-*' | ForEach-Object FullName)
            $caught = $null
            try {
                & $recovery -BackupPath $backupPath -EnvironmentPath $environmentPath `
                    -ExpectedManifestSha256 $manifestDigest -Confirm:$false
            }
            catch { $caught = $_ }
            if ($null -eq $caught -or $caught.Exception.Message -notmatch 'failed structural validation' -or
                $fixture.RecoveryProbeCount -ne 1) { throw "Recovery fixture failed outside its intended archive boundary: $caught" }
            $environmentRestored = $true
            foreach ($name in $recoveryVariables) {
                if ($variant -ceq 'originally-absent') {
                    if (Test-Path "Env:$name") { $environmentRestored = $false }
                }
                elseif ([Environment]::GetEnvironmentVariable($name) -cne ('fixture-original-' + $name)) {
                    $environmentRestored = $false
                }
            }
            $cases.Add([pscustomobject]@{ name = "failed-recovery-restores-$variant-environment";
                passed = $environmentRestored; expectedRejection = $false; error = $null })
            $cases.Add([pscustomobject]@{ name = "recovery-key-workspaces-private-from-creation-$variant";
                passed = $fixture.SnapshotPermissionFailures.Count -eq 0; expectedRejection = $false;
                error = $fixture.SnapshotPermissionFailures -join '; ' })
            $cases.Add([pscustomobject]@{ name = "failed-recovery-removes-owned-temporary-keys-$variant";
                passed = -not (Test-Path -LiteralPath $fixture.RecoveryTemporaryRoot); expectedRejection = $false; error = $null })
        }
    }
    finally {
        foreach ($name in $recoveryVariables) {
            if ($savedVariables[$name].Exists) { [Environment]::SetEnvironmentVariable($name, [string]$savedVariables[$name].Value) }
            else { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        }
    }
}
finally {
    if ($originalBackendExists) { [Environment]::SetEnvironmentVariable('BUNKFY_BACKEND_IMAGE', $originalBackend) }
    else { Remove-Item Env:BUNKFY_BACKEND_IMAGE -ErrorAction SilentlyContinue }
    if ($originalWebExists) { [Environment]::SetEnvironmentVariable('BUNKFY_WEB_IMAGE', $originalWeb) }
    else { Remove-Item Env:BUNKFY_WEB_IMAGE -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
$failed = @($cases | Where-Object { -not $_.passed })
if ($failed.Count -gt 0) { throw ($failed | ConvertTo-Json -Depth 5 -Compress) }
Write-Host "Preview infrastructure: $($cases.Count) guard/operator checks passed; no daemon mutations."

