Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'operations\preview-storage.common.ps1')
. (Join-Path $PSScriptRoot 'operations\preview-state.common.ps1')
. (Join-Path $PSScriptRoot 'operations\local-sensitive-state.common.ps1')

$image = 'pgsty/silo:RELEASE.2026-10-26T00-00-00Z@sha256:7bb2aff6b89efe1cb1303c10fc21d579447434ed06649ac9ec05a5e2dbf30ad7'
$legacyImage = 'minio/minio:RELEASE.2025-04-22T22-12-26Z@sha256:a1ea29fa28355559ef137d71fc570e508a214ec84ff8083e39bc5428980b015e'
$silo = [pscustomobject]@{
    services = [pscustomobject]@{ minio = [pscustomobject]@{ image = $image; platform = 'linux/amd64' } }
    volumes = [pscustomobject]@{ 'minio-data' = [pscustomobject]@{
            name = 'bunkfy-preview-minio-data'
            labels = [pscustomobject]@{ 'com.bunkfy.preview.storage-provider' = 'silo'; 'com.bunkfy.preview.storage-image' = $image }
        } }
}
$infrastructure = Get-BunkFyPreviewInfrastructurePolicy
foreach ($name in @('postgres', 'redis', 'nats', 'mailpit')) {
    $silo.services | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{
            image = $infrastructure.profiles.legacy.images.PSObject.Properties[$name].Value
        })
}
foreach ($name in @('postgres-data', 'redis-data', 'nats-data')) {
    $silo.volumes | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{
            name = "bunkfy-preview-$name"
            labels = [pscustomobject]@{ 'com.bunkfy.preview.infrastructure-generation' = 'legacy:1' }
        })
}
$legacy = ($silo | ConvertTo-Json -Depth 8) | ConvertFrom-Json
$legacy.services.minio.image = $legacyImage
$legacy.services.minio.PSObject.Properties.Remove('platform')
$legacy.volumes.'minio-data'.labels.'com.bunkfy.preview.storage-provider' = 'legacy-minio'
$legacy.volumes.'minio-data'.labels.'com.bunkfy.preview.storage-image' = $legacyImage
$state = [pscustomobject]@{ Mode = 'absent'; Compose = $silo; Calls = [Collections.Generic.List[string]]::new() }
$dockerShim = {
    $state.Calls.Add(($args -join ' '))
    $global:LASTEXITCODE = 0
    if ($args[0] -ceq 'volume' -and $args[1] -ceq 'ls') {
        if ($state.Mode -ceq 'unavailable') { $global:LASTEXITCODE = 1; return }
        if ($state.Mode -cne 'absent') { 'bunkfy-preview-minio-data' }
        return
    }
    if ($args[0] -ceq 'volume' -and $args[1] -ceq 'inspect') {
        switch ($state.Mode) {
            'valid' { @{ 'com.bunkfy.preview.storage-provider' = 'silo'; 'com.bunkfy.preview.storage-image' = $image } | ConvertTo-Json -Compress }
            'legacy-labelled' { @{ 'com.bunkfy.preview.storage-provider' = 'legacy-minio'; 'com.bunkfy.preview.storage-image' = $legacyImage } | ConvertTo-Json -Compress }
            'old-image' { @{ 'com.bunkfy.preview.storage-provider' = 'silo'; 'com.bunkfy.preview.storage-image' = 'old-image' } | ConvertTo-Json -Compress }
            'legacy' { '{}' }
            'other-provider' { '{"com.bunkfy.preview.storage-provider":"minio"}' }
            'malformed' { '{' }
            'inspect-failed' { $global:LASTEXITCODE = 1 }
            default { throw 'Unexpected storage-volume fixture mode.' }
        }
        return
    }
    if ($args[0] -ceq 'compose') {
        if ($args -contains 'config') { $state.Compose | ConvertTo-Json -Depth 8 }
        return
    }
    throw 'The storage preflight must not create, start, delete or mutate Docker resources.'
}.GetNewClosure()
Set-Item -Path Function:docker -Value $dockerShim

Assert-BunkFyPreviewStorageVolume -ComposeDefinition $silo
$state.Mode = 'valid'
Assert-BunkFyPreviewStorageVolume -ComposeDefinition $silo
foreach ($mode in @('legacy', 'legacy-labelled', 'other-provider', 'old-image', 'malformed', 'unavailable', 'inspect-failed')) {
    $state.Mode = $mode
    $rejected = $false
    try { Assert-BunkFyPreviewStorageVolume -ComposeDefinition $silo } catch { $rejected = $true }
    if (-not $rejected) { throw "Unverified existing storage '$mode' was accepted." }
}
$before = $state.Calls.Count
$rejected = $false
$invalid = ($silo | ConvertTo-Json -Depth 8) | ConvertFrom-Json
$invalid.volumes.'minio-data'.name = '../unowned'
try { Assert-BunkFyPreviewStorageVolume -ComposeDefinition $invalid } catch { $rejected = $true }
if (-not $rejected -or $state.Calls.Count -ne $before) { throw 'Invalid volume prefix reached Docker.' }
foreach ($mode in @('absent', 'legacy', 'legacy-labelled')) {
    $state.Mode = $mode
    Assert-BunkFyPreviewStorageVolume -ComposeDefinition $legacy
}
foreach ($mode in @('valid', 'old-image', 'other-provider', 'malformed', 'unavailable', 'inspect-failed')) {
    $state.Mode = $mode
    $rejected = $false
    try { Assert-BunkFyPreviewStorageVolume -ComposeDefinition $legacy } catch { $rejected = $true }
    if (-not $rejected) { throw "Legacy profile accepted mismatched storage '$mode'." }
}
foreach ($mutation in @('image', 'platform', 'provider', 'label-image')) {
    $invalid = ($silo | ConvertTo-Json -Depth 8) | ConvertFrom-Json
    switch ($mutation) {
        'image' { $invalid.services.minio.image = 'unreviewed/storage:latest' }
        'platform' { $invalid.services.minio.platform = 'linux/arm64' }
        'provider' { $invalid.volumes.'minio-data'.labels.'com.bunkfy.preview.storage-provider' = 'legacy-minio' }
        'label-image' { $invalid.volumes.'minio-data'.labels.'com.bunkfy.preview.storage-image' = 'unreviewed/storage:latest' }
    }
    $rejected = $false
    try { Get-BunkFyPreviewStorageProfile -ComposeDefinition $invalid | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Unreviewed resolved storage '$mutation' was accepted." }
}

$current = [pscustomobject]@{
    schemaVersion = 6
    stateContract = [pscustomobject]@{ name = 'bunkfy-preview-state'; version = 2 }
    objectStorage = [pscustomobject]@{ provider = 'silo'; image = $image }
}
Assert-BunkFyPreviewBackupStorageProvider -Manifest $current -ComposeDefinition $silo
$contract = Get-BunkFyPreviewStateContract -Manifest $current
if ($contract.Version -ne 2) { throw 'Provider-bound backup changed the established logical archive set.' }
foreach ($manifest in @(
        [pscustomobject]@{ schemaVersion = 5 },
        [pscustomobject]@{ schemaVersion = 6 },
        [pscustomobject]@{ schemaVersion = 6; objectStorage = [pscustomobject]@{ provider = 'legacy-unverified'; image = $null } },
        [pscustomobject]@{ schemaVersion = 6; objectStorage = [pscustomobject]@{ provider = 'silo'; image = 'other-image' } })) {
    $rejected = $false
    try { Assert-BunkFyPreviewBackupStorageProvider -Manifest $manifest -ComposeDefinition $silo } catch { $rejected = $true }
    if (-not $rejected) { throw 'Restore accepted legacy or mismatched provider state.' }
}
foreach ($schema in @(2, 3, 4, 5)) {
    $manifest = [pscustomobject]@{ schemaVersion = $schema }
    Assert-BunkFyPreviewBackupStorageProvider -Manifest $manifest -ComposeDefinition $legacy
    $rejected = $false
    try { Assert-BunkFyPreviewBackupStorageProvider -Manifest $manifest -ComposeDefinition $silo } catch { $rejected = $true }
    if (-not $rejected) { throw "Legacy schema '$schema' crossed into Silo." }
}
$rejected = $false
try { Assert-BunkFyPreviewBackupStorageProvider -Manifest $current -ComposeDefinition $legacy } catch { $rejected = $true }
if (-not $rejected) { throw 'Silo data crossed into the archived MinIO profile.' }
$downgraded = ($current | ConvertTo-Json -Depth 8) | ConvertFrom-Json
$downgraded.schemaVersion = 5
$rejected = $false
try { Assert-BunkFyPreviewBackupStorageProvider -Manifest $downgraded -ComposeDefinition $legacy } catch { $rejected = $true }
if (-not $rejected) { throw 'Downgraded provider metadata bypassed legacy restore admission.' }

$preview = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'preview.ps1') -Raw
if ($preview.IndexOf('Assert-BunkFyPreviewStorageVolume -ComposeDefinition $storageCompose', [StringComparison]::Ordinal) -lt 0 -or
    $preview.IndexOf('Assert-BunkFyPreviewStorageVolume -ComposeDefinition $storageCompose', [StringComparison]::Ordinal) -gt
    $preview.IndexOf("Invoke-BunkFyCommand -FilePath 'docker'", [StringComparison]::Ordinal)) {
    throw 'Storage compatibility preflight must precede starting any Compose services.'
}

# Exercise the actual up wrapper with generated private fixture settings.
# The Docker shim records commands and never reaches a real daemon.
$temporary = Join-Path $PSScriptRoot ("../.tmp/storage-guard-tests/" + [Guid]::NewGuid().ToString('N'))
$environmentPath = Join-Path $temporary 'preview.env'
try {
    New-BunkFyLocalSensitiveDirectory -Path $temporary -Description 'Storage guard test directory'
    & (Join-Path $PSScriptRoot 'new-preview-env.ps1') -OutputPath $environmentPath | Out-Null
    foreach ($mode in @('legacy', 'old-image')) {
        $state.Mode = $mode
        $state.Calls.Clear()
        $rejected = $false
        try { & (Join-Path $PSScriptRoot 'preview.ps1') -Action up -NoBuild -NoPull -EnvironmentPath $environmentPath }
        catch { $rejected = $true }
        if (-not $rejected -or @($state.Calls | Where-Object { $_.Contains('up --detach', [StringComparison]::Ordinal) }).Count -ne 0) {
            throw 'The actual Preview up wrapper started services for unverified existing storage.'
        }
    }
    $state.Mode = 'valid'
    $state.Calls.Clear()
    & (Join-Path $PSScriptRoot 'preview.ps1') -Action up -NoBuild -NoPull -EnvironmentPath $environmentPath
    if (@($state.Calls | Where-Object { $_.Contains('up --detach --no-build --pull never --wait', [StringComparison]::Ordinal) }).Count -ne 1) {
        throw 'The actual Preview up wrapper did not preserve valid no-build/no-pull startup.'
    }
    # Exercise an old environment file and the actual unchanged MinIO path.
    $oldEnvironment = (Get-Content -LiteralPath $environmentPath) | Where-Object { $_ -cnotmatch '^BUNKFY_STORAGE_' }
    Write-BunkFyLocalSensitiveTextFile -Path $environmentPath -Content ($oldEnvironment -join "`n") -Overwrite -Description 'Legacy storage test environment'
    $state.Compose = $legacy
    $state.Mode = 'legacy'
    $state.Calls.Clear()
    & (Join-Path $PSScriptRoot 'preview.ps1') -Action up -NoBuild -NoPull -EnvironmentPath $environmentPath
    if (@($state.Calls | Where-Object { $_.Contains('up --detach --no-build --pull never --wait', [StringComparison]::Ordinal) }).Count -ne 1) {
        throw 'The actual Preview up wrapper removed legacy startup support.'
    }
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
Write-Host 'Preview storage volume and backup provider boundaries passed.'
