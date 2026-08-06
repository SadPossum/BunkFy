[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string] $BackupPath,
    [Parameter(Mandatory = $true)][string] $ExpectedManifestSha256,
    [string] $EnvironmentPath,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [string] $OutputPath,
    [switch] $KeepRestoredTarget,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'preview-state.common.ps1')

$root = Get-BunkFyRepositoryRoot
$composePath = Join-BunkFyPath 'deploy\preview\compose.yaml'
$restoreScript = Join-Path $PSScriptRoot 'restore-preview.ps1'
$publicProbeScript = Join-Path $PSScriptRoot 'verify-deployed-public-edge.ps1'
$adminProbeScript = Join-Path $PSScriptRoot 'verify-deployed-admin-boundary.ps1'
if ([string]::IsNullOrWhiteSpace($EnvironmentPath)) {
    $EnvironmentPath = Join-BunkFyPath 'deploy\preview\.env'
}

$EnvironmentPath = [IO.Path]::GetFullPath($EnvironmentPath)
$BackupPath = [IO.Path]::GetFullPath($BackupPath)
if (-not (Test-Path -LiteralPath $EnvironmentPath -PathType Leaf)) {
    throw "Preview environment '$EnvironmentPath' does not exist."
}
if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) {
    throw "Backup directory '$BackupPath' does not exist."
}
$backupItem = Get-Item -LiteralPath $BackupPath -Force
if ($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Backup directory '$BackupPath' must not be a reparse point."
}
Assert-BunkFySha256Digest `
    -Value $ExpectedManifestSha256 `
    -Name 'ExpectedManifestSha256'

$manifestPath = Join-Path $BackupPath 'manifest.json'
[void](Assert-BunkFyRegularFile `
        -Path $manifestPath `
        -Description 'Backup manifest')
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 12
}
catch {
    throw "Backup manifest '$manifestPath' is invalid JSON."
}
$schemaVersion = 0
if ($null -eq $manifest.PSObject.Properties['schemaVersion'] -or
    -not [int]::TryParse([string]$manifest.schemaVersion, [ref]$schemaVersion) -or
    $schemaVersion -ne 4) {
    throw 'Preview recovery rehearsal requires a schema-4 backup.'
}
$manifestDigest = Assert-BunkFyBackupManifestIntegrity `
    -ManifestPath $manifestPath `
    -SchemaVersion $schemaVersion `
    -ExpectedSha256 $ExpectedManifestSha256
$stateContract = Get-BunkFyPreviewStateContract -Manifest $manifest
Assert-BunkFyPreviewStateContractCompatible -Contract $stateContract

$backupId = [Guid]::Empty
if ($null -eq $manifest.PSObject.Properties['backupId'] -or
    -not [Guid]::TryParse([string]$manifest.backupId, [ref]$backupId) -or
    $backupId -eq [Guid]::Empty) {
    throw 'Backup manifest backupId is missing or invalid.'
}
$backupCreatedAtUtc = [DateTimeOffset]::MinValue
try {
    if ($null -eq $manifest.PSObject.Properties['createdAtUtc']) {
        throw 'missing'
    }
    $backupCreatedAtUtc = [DateTimeOffset]$manifest.createdAtUtc
}
catch {
    throw 'Backup manifest creation time is missing or invalid.'
}
if ($backupCreatedAtUtc -eq [DateTimeOffset]::MinValue -or
    $backupCreatedAtUtc -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
    throw 'Backup manifest creation time is outside the accepted range.'
}

$rehearsalId = [Guid]::NewGuid()
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-BunkFyPath (
        ".tmp/recovery-rehearsals/preview-$($rehearsalId.ToString('N')).json")
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$backupPrefix = $BackupPath.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if ($OutputPath.StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Recovery rehearsal evidence must be written outside the backup directory.'
}
if (Test-Path -LiteralPath $OutputPath) {
    $outputItem = Get-Item -LiteralPath $OutputPath -Force
    if ($outputItem.PSIsContainer -or
        ($outputItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The output path is not a regular file: '$OutputPath'."
    }
    if (-not $Force) {
        throw "The output file already exists: '$OutputPath'. Use -Force to replace it."
    }
}

if (-not $PSCmdlet.ShouldProcess(
        $backupId.ToString('D'),
        'Restore the backup into a disposable isolated preview target and verify recovery')) {
    return
}

function Get-BunkFyFreeLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Set-BunkFyProcessEnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Value
    )

    [Environment]::SetEnvironmentVariable(
        $Name,
        $Value,
        [EnvironmentVariableTarget]::Process)
}

$shortId = $rehearsalId.ToString('N').Substring(0, 12)
$projectName = "bunkfy-recovery-$shortId"
$volumePrefix = $projectName
$publicPort = Get-BunkFyFreeLoopbackPort
do {
    $adminPort = Get-BunkFyFreeLoopbackPort
} while ($adminPort -eq $publicPort)
$publicOrigin = [Uri]"http://127.0.0.1:$publicPort/"
$adminOrigin = [Uri]"http://127.0.0.1:$adminPort/"

$overrideValues = [ordered]@{
    BUNKFY_COMPOSE_PROJECT_NAME = $projectName
    BUNKFY_VOLUME_PREFIX = $volumePrefix
    BUNKFY_PUBLIC_PORT = [string]$publicPort
    BUNKFY_ADMIN_PORT = [string]$adminPort
    BUNKFY_RELEASE_ID = "recovery-$shortId"
}
$previousValues = [ordered]@{}
foreach ($entry in $overrideValues.GetEnumerator()) {
    $environmentVariablePath = "Env:$($entry.Key)"
    $previousValues[$entry.Key] = [pscustomobject]@{
        Exists = Test-Path -LiteralPath $environmentVariablePath
        Value = [Environment]::GetEnvironmentVariable(
            $entry.Key,
            [EnvironmentVariableTarget]::Process)
    }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "bunkfy-recovery-$($rehearsalId.ToString('N'))")
[void](New-Item -ItemType Directory -Path $temporaryRoot)
$archiveKeyTreePath = Join-Path $temporaryRoot 'archive-key-ring'
$restoredKeyTreePath = Join-Path $temporaryRoot 'restored-key-ring'
[void](New-Item -ItemType Directory -Path $archiveKeyTreePath)
[void](New-Item -ItemType Directory -Path $restoredKeyTreePath)
$publicEvidencePath = Join-Path $temporaryRoot 'public-edge.json'
$adminEvidencePath = Join-Path $temporaryRoot 'admin-boundary.json'
$compose = @(
    'compose', '--env-file', $EnvironmentPath, '-f', $composePath
)
$targetCreationAttempted = $false
$rehearsalPassed = $false
$cleanupFailed = $false
$evidence = $null
$startedAtUtc = [DateTimeOffset]::UtcNow

try {
    foreach ($entry in $overrideValues.GetEnumerator()) {
        Set-BunkFyProcessEnvironmentValue -Name $entry.Key -Value ([string]$entry.Value)
    }

    $targetCreationAttempted = $true
    & $restoreScript `
        -BackupPath $BackupPath `
        -EnvironmentPath $EnvironmentPath `
        -ExpectedManifestSha256 $ExpectedManifestSha256 `
        -AllowBackupPointProtectedLedger `
        -RemoveFailedTarget `
        -Confirm:$false

    Invoke-BunkFyCommand -FilePath 'docker' -Arguments (
        $compose + @(
            '--profile', 'operations',
            'up', '--detach', '--no-build', '--wait', 'admin-api'
        )) -WorkingDirectory $root

    & $publicProbeScript `
        -PublicOrigin $publicOrigin `
        -ExpectedReleaseId $overrideValues.BUNKFY_RELEASE_ID `
        -AllowLoopbackHttp `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -OutputPath $publicEvidencePath
    & $adminProbeScript `
        -PublicOrigin $publicOrigin `
        -AdminOrigin $adminOrigin `
        -ExpectedAdminReachability Allowed `
        -EvidenceSetId $rehearsalId `
        -RequestTimeoutSeconds $RequestTimeoutSeconds `
        -AllowLoopbackHttp `
        -OutputPath $adminEvidencePath

    $composeDefinition = Get-BunkFyPreviewComposeDefinition `
        -Root $root `
        -ComposePath $composePath `
        -EnvironmentPath $EnvironmentPath
    if ([string]$composeDefinition.name -cne $projectName) {
        throw 'Recovery rehearsal Compose project identity drifted from the isolated target.'
    }
    $volumeMap = Get-BunkFyPreviewVolumeMap -ComposeDefinition $composeDefinition
    $dataProtectionVolume = [string]$volumeMap['data-protection']
    $dataProtectionArchive = Join-Path `
        $BackupPath ([string]$script:BunkFyPreviewStateArchives['data-protection'])
    [void](Assert-BunkFyRegularFile `
            -Path $dataProtectionArchive `
            -Description 'Data Protection backup archive')
    $archiveDirectory = Split-Path -Parent $dataProtectionArchive
    $archiveName = Split-Path -Leaf $dataProtectionArchive
    Invoke-BunkFyCommand -FilePath 'docker' -Arguments @(
        'run', '--rm',
        '--mount', "type=bind,src=$archiveDirectory,dst=/backup,readonly",
        '--mount', "type=bind,src=$archiveKeyTreePath,dst=/target",
        'alpine:3.21',
        'sh', '-euc',
        'tar -xzf "/backup/$1" -C /target && chmod -R a+rX /target',
        '--', $archiveName
    ) -WorkingDirectory $root
    Invoke-BunkFyCommand -FilePath 'docker' -Arguments @(
        'run', '--rm',
        '--mount', "type=volume,src=$dataProtectionVolume,dst=/source,readonly",
        '--mount', "type=bind,src=$restoredKeyTreePath,dst=/target",
        'alpine:3.21',
        'sh', '-euc',
        'cp -a /source/. /target/ && chmod -R a+rX /target'
    ) -WorkingDirectory $root

    $archiveKeyTree = Get-BunkFyStateTreeFingerprint -Path $archiveKeyTreePath
    $restoredKeyTree = Get-BunkFyStateTreeFingerprint -Path $restoredKeyTreePath
    if ($archiveKeyTree.FileCount -lt 1) {
        throw 'The backup contains no Data Protection key material. Exercise a protected smoke authenticator before taking the recovery backup.'
    }
    if ($archiveKeyTree.FileCount -ne $restoredKeyTree.FileCount -or
        $archiveKeyTree.TotalBytes -ne $restoredKeyTree.TotalBytes -or
        $archiveKeyTree.Sha256 -cne $restoredKeyTree.Sha256) {
        throw 'The restored Data Protection key tree does not match the backup.'
    }

    $publicEvidence = Get-Content -LiteralPath $publicEvidencePath -Raw |
        ConvertFrom-Json -Depth 8
    $adminEvidence = Get-Content -LiteralPath $adminEvidencePath -Raw |
        ConvertFrom-Json -Depth 8
    if ($publicEvidence.result -cne 'passed' -or
        @($publicEvidence.checks).Count -ne 5 -or
        $adminEvidence.result -cne 'passed' -or
        $adminEvidence.expectedAdminReachability -cne 'allowed' -or
        @($adminEvidence.checks).Count -ne 4) {
        throw 'Recovery rehearsal deployment probes did not emit the expected passing evidence.'
    }

    $completedAtUtc = [DateTimeOffset]::UtcNow
    $evidence = [ordered]@{
        schemaVersion = 1
        evidenceKind = 'bunkfy-preview-recovery-rehearsal'
        rehearsalId = $rehearsalId.ToString('D')
        generatedAtUtc = $completedAtUtc.ToString('O')
        result = 'passed'
        backup = [ordered]@{
            backupId = $backupId.ToString('D')
            createdAtUtc = $backupCreatedAtUtc.ToString('O')
            manifestSha256 = $manifestDigest
            stateContractName = $stateContract.Name
            stateContractVersion = $stateContract.Version
        }
        target = [ordered]@{
            kind = 'isolated-preview-compose'
            projectName = $projectName
            volumePrefix = $volumePrefix
            publicOrigin = $publicOrigin.GetLeftPart([UriPartial]::Authority)
            adminOrigin = $adminOrigin.GetLeftPart([UriPartial]::Authority)
            keptAfterRehearsal = [bool]$KeepRestoredTarget
        }
        timing = [ordered]@{
            startedAtUtc = $startedAtUtc.ToString('O')
            readyAtUtc = $completedAtUtc.ToString('O')
            durationMilliseconds = [long]($completedAtUtc - $startedAtUtc).TotalMilliseconds
        }
        checks = @(
            [ordered]@{ name = 'schema-4-manifest-and-artifacts-verified'; result = 'passed' }
            [ordered]@{ name = 'empty-isolated-target-restored'; result = 'passed' }
            [ordered]@{ name = 'public-edge-recovered'; result = 'passed' }
            [ordered]@{ name = 'admin-surface-recovered-and-auth-gated'; result = 'passed' }
            [ordered]@{
                name = 'data-protection-key-tree-restored'
                result = 'passed'
                fileCount = $archiveKeyTree.FileCount
                totalBytes = $archiveKeyTree.TotalBytes
            }
        )
        limitations = @(
            'preview-compose-storage-not-hosted-provider-backup',
            'backup-point-protected-ledger-used-only-in-isolated-rehearsal',
            'protected-authenticator-decryption-not-exercised',
            'external-admin-denial-vantage-not-exercised',
            'secret-store-recovery-not-exercised',
            'hosted-rpo-and-rto-not-established'
        )
    }
    $rehearsalPassed = $true
}
finally {
    if ($targetCreationAttempted -and -not $KeepRestoredTarget) {
        & docker @compose --profile operations down --volumes --remove-orphans 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) {
            $cleanupFailed = $true
            Write-Warning "Failed to remove isolated recovery target '$projectName'."
        }
    }
    foreach ($entry in $previousValues.GetEnumerator()) {
        if ($entry.Value.Exists) {
            [Environment]::SetEnvironmentVariable(
                $entry.Key,
                [string]$entry.Value.Value,
                [EnvironmentVariableTarget]::Process)
        }
        else {
            [Environment]::SetEnvironmentVariable(
                $entry.Key,
                $null,
                [EnvironmentVariableTarget]::Process)
        }
    }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $rehearsalPassed) {
    throw 'Preview recovery rehearsal did not complete.'
}
if ($cleanupFailed) {
    throw 'Preview recovery rehearsal passed, but isolated-target cleanup failed.'
}

$parent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $parent -Force)
}
$temporaryOutputPath = "$OutputPath.$([Guid]::NewGuid().ToString('N')).tmp"
try {
    $json = $evidence | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText(
        $temporaryOutputPath,
        ($json.Replace("`r`n", "`n") + "`n"),
        [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryOutputPath -Destination $OutputPath -Force:$Force
}
finally {
    if (Test-Path -LiteralPath $temporaryOutputPath) {
        Remove-Item -LiteralPath $temporaryOutputPath -Force
    }
}

Write-Host "BunkFy isolated preview recovery rehearsal passed $(@($evidence.checks).Count) checks."
Write-Host "Evidence: $OutputPath"
if ($KeepRestoredTarget) {
    Write-Host "Restored target retained as Compose project '$projectName'."
    Write-Host "Public origin: $($publicOrigin.GetLeftPart([UriPartial]::Authority))"
    Write-Host "Admin origin: $($adminOrigin.GetLeftPart([UriPartial]::Authority))"
}
