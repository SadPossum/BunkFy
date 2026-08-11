[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string] $BackupPath,
    [string] $EnvironmentPath,
    [string] $ExpectedManifestSha256,
    [string] $ProtectedLedgerSnapshotPath,
    [string] $ProtectedLedgerSnapshotSha256,
    [string] $BackendImage,
    [string] $WebImage,
    [switch] $AllowBackupPointProtectedLedger,
    [switch] $LeaveStopped,
    [switch] $RemoveFailedTarget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'preview-state.common.ps1')

$root = Get-BunkFyRepositoryRoot
$composePath = Join-BunkFyPath 'deploy\preview\compose.yaml'
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

$manifestPath = Join-Path $BackupPath 'manifest.json'
[void](Assert-BunkFyRegularFile `
        -Path $manifestPath `
        -Description 'Backup manifest')
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}
catch {
    throw "Backup manifest '$manifestPath' is invalid JSON: $($_.Exception.Message)"
}
$manifestSchemaVersion = 0
$manifestSchemaProperty = $manifest.PSObject.Properties['schemaVersion']
if ($null -eq $manifestSchemaProperty -or
    -not [int]::TryParse(
        [string]$manifestSchemaProperty.Value,
        [ref]$manifestSchemaVersion)) {
    throw 'Backup manifest schema is missing or invalid.'
}
[void](Assert-BunkFyBackupManifestIntegrity `
        -ManifestPath $manifestPath `
        -SchemaVersion $manifestSchemaVersion `
        -ExpectedSha256 $ExpectedManifestSha256)
$stateContract = Get-BunkFyPreviewStateContract -Manifest $manifest
Assert-BunkFyPreviewStateContractCompatible -Contract $stateContract

if ($manifestSchemaVersion -ge 4) {
    $backupId = [Guid]::Empty
    $backupIdProperty = $manifest.PSObject.Properties['backupId']
    if ($null -eq $backupIdProperty -or
        -not [Guid]::TryParse([string]$backupIdProperty.Value, [ref]$backupId) -or
        $backupId -eq [Guid]::Empty) {
        throw 'Backup manifest backupId is missing or invalid.'
    }

    $protectedLedgerProperty = $manifest.PSObject.Properties['protectedLedgerSnapshot']
    if ($null -eq $protectedLedgerProperty -or
        $null -eq $protectedLedgerProperty.Value -or
        [string]$protectedLedgerProperty.Value.logicalName -cne
            $script:BunkFyPreviewProtectedLedgerLogicalName -or
        [string]$protectedLedgerProperty.Value.artifact -cne
            [string]$script:BunkFyPreviewStateArchives[
                $script:BunkFyPreviewProtectedLedgerLogicalName] -or
        [string]$protectedLedgerProperty.Value.restorePolicy -cne
            'explicit-current-snapshot-required') {
        throw 'Backup manifest protected-ledger recovery policy is invalid.'
    }
    $protectedLedgerCapturedAtUtc = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
            [string]$protectedLedgerProperty.Value.capturedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$protectedLedgerCapturedAtUtc)) {
        throw 'Backup manifest protected-ledger capture time is invalid.'
    }
}

Assert-BunkFyGitWorktreeClean -RepositoryPath $root
Assert-BunkFyGitWorktreeClean -RepositoryPath (Join-BunkFyPath 'apps\backend')
Assert-BunkFyGitWorktreeClean -RepositoryPath (Join-BunkFyPath 'apps\web')

foreach ($name in @('repositoryCommit', 'backendCommit', 'webCommit')) {
    $property = $manifest.PSObject.Properties[$name]
    $value = if ($null -eq $property) { $null } else { $property.Value }
    Assert-BunkFyGitCommitRecord `
        -Value $value `
        -Name $name
}

$expectedArtifacts = @('postgres.dump') +
    @($script:BunkFyPreviewStateArchives.Values)
$artifactRecords = @($manifest.artifacts)
if ($artifactRecords.Count -ne $expectedArtifacts.Count) {
    throw 'Backup manifest does not contain the exact required artifact set.'
}
$seenArtifacts = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
foreach ($record in $artifactRecords) {
    $file = [string]$record.file
    if ([string]::IsNullOrWhiteSpace($file) -or
        $file -match '[\\/]' -or
        -not $seenArtifacts.Add($file) -or
        $expectedArtifacts -cnotcontains $file) {
        throw "Backup manifest contains an invalid artifact name '$file'."
    }

    $path = Join-Path $BackupPath $file
    $item = Assert-BunkFyRegularFile `
        -Path $path `
        -Description "Backup artifact '$file'"
    $recordedLength = [long]0
    if (-not [long]::TryParse([string]$record.length, [ref]$recordedLength) -or
        $recordedLength -le 0 -or
        $item.Length -ne $recordedLength) {
        throw "Backup artifact '$file' has an unexpected length."
    }
    $recordedDigest = [string]$record.sha256
    Assert-BunkFySha256Digest `
        -Value $recordedDigest `
        -Name "Backup artifact '$file' digest"
    $digest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($digest -cne $recordedDigest) {
        throw "Backup artifact '$file' failed SHA-256 verification."
    }
}
foreach ($file in $expectedArtifacts) {
    if (-not $seenArtifacts.Contains($file)) {
        throw "Backup manifest is missing required artifact '$file'."
    }
}

$protectedLedgerArtifact = [string]$script:BunkFyPreviewStateArchives[
    $script:BunkFyPreviewProtectedLedgerLogicalName]
$protectedLedgerRecord = @($artifactRecords | Where-Object {
        [string]$_.file -ceq $protectedLedgerArtifact
    })
if ($protectedLedgerRecord.Count -ne 1) {
    throw 'Backup manifest protected-ledger artifact is not unique.'
}
if ($AllowBackupPointProtectedLedger -and
    -not [string]::IsNullOrWhiteSpace($ProtectedLedgerSnapshotPath)) {
    throw 'AllowBackupPointProtectedLedger cannot be combined with ProtectedLedgerSnapshotPath.'
}
if ([string]::IsNullOrWhiteSpace($ProtectedLedgerSnapshotPath)) {
    if (-not $AllowBackupPointProtectedLedger) {
        throw 'A current protected-ledger snapshot is required. Supply ProtectedLedgerSnapshotPath and ProtectedLedgerSnapshotSha256, or explicitly allow the backup-point snapshot only for a disposable rehearsal.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ProtectedLedgerSnapshotSha256)) {
        throw 'ProtectedLedgerSnapshotSha256 requires ProtectedLedgerSnapshotPath.'
    }
    $selectedProtectedLedgerPath = Join-Path $BackupPath $protectedLedgerArtifact
    $selectedProtectedLedgerDigest = [string]$protectedLedgerRecord[0].sha256
}
else {
    if ([string]::IsNullOrWhiteSpace($ProtectedLedgerSnapshotSha256)) {
        throw 'ProtectedLedgerSnapshotSha256 is required with ProtectedLedgerSnapshotPath.'
    }
    Assert-BunkFySha256Digest `
        -Value $ProtectedLedgerSnapshotSha256 `
        -Name 'ProtectedLedgerSnapshotSha256'
    $selectedProtectedLedgerPath = [IO.Path]::GetFullPath($ProtectedLedgerSnapshotPath)
    [void](Assert-BunkFyRegularFile `
            -Path $selectedProtectedLedgerPath `
            -Description 'Protected-ledger snapshot')
    $selectedProtectedLedgerDigest = (Get-FileHash `
            -LiteralPath $selectedProtectedLedgerPath `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($selectedProtectedLedgerDigest -cne $ProtectedLedgerSnapshotSha256) {
        throw 'Protected-ledger snapshot failed the supplied SHA-256 verification.'
    }
}

$recordedVolumes = @($manifest.stateVolumes)
if ($recordedVolumes.Count -ne $script:BunkFyPreviewStateArchives.Count) {
    throw 'Backup manifest does not contain the exact state-volume set.'
}
foreach ($entry in $script:BunkFyPreviewStateArchives.GetEnumerator()) {
    $matching = @($recordedVolumes | Where-Object {
        [string]$_.logicalName -ceq [string]$entry.Key
    })
    if ($matching.Count -ne 1 -or
        [string]$matching[0].artifact -cne [string]$entry.Value -or
        [string]::IsNullOrWhiteSpace([string]$matching[0].dockerName)) {
        throw "Backup state-volume record '$($entry.Key)' is invalid."
    }
}

$recordedImages = @($manifest.images)
if ($recordedImages.Count -ne 2) {
    throw 'Backup manifest does not contain the exact image set.'
}
$selectedImages = [ordered]@{}
foreach ($kind in @('backend', 'web')) {
    $matching = @($recordedImages | Where-Object {
            [string]$_.kind -ceq $kind
        })
    if ($matching.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$matching[0].reference) -or
        [string]$matching[0].imageId -cnotmatch '^sha256:[a-f0-9]{64}$') {
        throw "Backup image record '$kind' is invalid."
    }

    $requested = if ($kind -ceq 'backend') { $BackendImage } else { $WebImage }
    if ([string]::IsNullOrWhiteSpace($requested)) {
        $requested = [string]$matching[0].reference
    }
    $selectedImages[$kind] = Assert-BunkFyPreviewImageReference `
        -Value $requested `
        -Name "$kind image"
}
[Environment]::SetEnvironmentVariable(
    'BUNKFY_BACKEND_IMAGE',
    [string]$selectedImages.backend,
    [EnvironmentVariableTarget]::Process)
[Environment]::SetEnvironmentVariable(
    'BUNKFY_WEB_IMAGE',
    [string]$selectedImages.web,
    [EnvironmentVariableTarget]::Process)

$composeDefinition = Get-BunkFyPreviewComposeDefinition `
    -Root $root `
    -ComposePath $composePath `
    -EnvironmentPath $EnvironmentPath
$projectName = [string]$composeDefinition.name
if ([string]::IsNullOrWhiteSpace($projectName)) {
    throw 'Preview Compose configuration has no resolved project name.'
}
$volumeMap = Get-BunkFyPreviewVolumeMap -ComposeDefinition $composeDefinition
$expectedImages = [ordered]@{
    backend = [string]$composeDefinition.services.api.image
    web = [string]$composeDefinition.services.web.image
}
foreach ($service in @('migrations', 'worker')) {
    if ([string]$composeDefinition.services.PSObject.Properties[$service].Value.image -cne
        $expectedImages.backend) {
        throw "Preview service '$service' does not use the API backend image."
    }
}
foreach ($entry in $expectedImages.GetEnumerator()) {
    $matching = @($recordedImages | Where-Object {
        [string]$_.kind -ceq [string]$entry.Key
    })
    if ([string]$entry.Value -cne [string]$selectedImages[$entry.Key]) {
        throw "Preview Compose did not select the requested $($entry.Key) image."
    }
    $localImageId = Get-BunkFyDockerImageId -Reference ([string]$entry.Value)
    if ([string]$matching[0].imageId -cne $localImageId) {
        throw "Local $($entry.Key) image does not match the backed-up image ID."
    }
}
$postgresImageReference = [string]$composeDefinition.services.postgres.image
if ([string]::IsNullOrWhiteSpace($postgresImageReference)) {
    throw 'Preview PostgreSQL service has no image reference.'
}

function Assert-BunkFyVolumeArchiveReadable {
    param([Parameter(Mandatory = $true)][string] $Path)

    $archiveDirectory = Split-Path -Parent $Path
    $archiveName = Split-Path -Leaf $Path
    & docker run --rm `
        --mount "type=bind,src=$archiveDirectory,dst=/backup,readonly" `
        $script:BunkFyPreviewArchiveUtilityImage `
        'tar' '-tzf' "/backup/$archiveName" 1>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Backup archive '$archiveName' failed structural validation."
    }
}

$stateArchivePaths = [ordered]@{}
foreach ($entry in $script:BunkFyPreviewStateArchives.GetEnumerator()) {
    $path = if ($entry.Key -ceq $script:BunkFyPreviewProtectedLedgerLogicalName) {
        $selectedProtectedLedgerPath
    }
    else {
        Join-Path $BackupPath ([string]$entry.Value)
    }
    Assert-BunkFyVolumeArchiveReadable -Path $path
    $stateArchivePaths[$entry.Key] = $path
}
& docker run --rm `
    --mount "type=bind,src=$BackupPath,dst=/backup,readonly" `
    $postgresImageReference `
    'pg_restore' '--list' '/backup/postgres.dump' 1>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Backup PostgreSQL dump failed structural validation.'
}

$compose = @(
    'compose', '--env-file', $EnvironmentPath, '-f', $composePath
)

$targetContainers = @(& docker @compose ps --all --quiet)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect restore target '$projectName'."
}
if ($targetContainers.Count -gt 0) {
    throw "Restore target '$projectName' already has containers."
}
$targetNetworks = @(& docker network ls `
    --filter "label=com.docker.compose.project=$projectName" --quiet)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect Docker networks.'
}
if ($targetNetworks.Count -gt 0) {
    throw "Restore target '$projectName' already has networks."
}
$existingVolumes = @(& docker volume ls --format '{{.Name}}')
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect Docker volumes.'
}
$existingVolumeSet = [Collections.Generic.HashSet[string]]::new(
    [string[]]$existingVolumes,
    [StringComparer]::Ordinal)
foreach ($volumeName in $volumeMap.Values) {
    if ($existingVolumeSet.Contains([string]$volumeName)) {
        throw "Restore target volume '$volumeName' already exists."
    }
}

if (-not $PSCmdlet.ShouldProcess(
        $projectName,
        "Restore verified preview backup '$BackupPath' into an empty deployment")) {
    return
}

function Restore-BunkFyVolume {
    param(
        [Parameter(Mandatory = $true)][string] $Volume,
        [Parameter(Mandatory = $true)][string] $ArchivePath
    )

    $archiveDirectory = Split-Path -Parent $ArchivePath
    $archiveName = Split-Path -Leaf $ArchivePath

    Invoke-BunkFyCommand -FilePath 'docker' -Arguments @(
        'run', '--rm',
        '--mount', "type=volume,src=$Volume,dst=/target",
        '--mount', "type=bind,src=$archiveDirectory,dst=/backup,readonly",
        $script:BunkFyPreviewArchiveUtilityImage,
        'tar', '-xzf', "/backup/$archiveName", '-C', '/target'
    ) -WorkingDirectory $root
}

$temporaryDump = '/tmp/bunkfy-preview-restore.dump'
$restoreComplete = $false
$targetCreationAttempted = $false
try {
    $targetCreationAttempted = $true
    Invoke-BunkFyCommand -FilePath 'docker' -Arguments (
        $compose + @('create', '--no-build')) -WorkingDirectory $root
    $createdVolumes = @(& docker volume ls --format '{{.Name}}')
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to verify the created restore volumes.'
    }
    $createdVolumeSet = [Collections.Generic.HashSet[string]]::new(
        [string[]]$createdVolumes,
        [StringComparer]::Ordinal)
    foreach ($volumeName in $volumeMap.Values) {
        if (-not $createdVolumeSet.Contains([string]$volumeName)) {
            throw "Compose did not create restore target volume '$volumeName'."
        }
    }
    foreach ($entry in $script:BunkFyPreviewStateArchives.GetEnumerator()) {
        Restore-BunkFyVolume `
            -Volume ([string]$volumeMap[$entry.Key]) `
            -ArchivePath ([string]$stateArchivePaths[$entry.Key])
    }

    Invoke-BunkFyCommand -FilePath 'docker' -Arguments (
        $compose + @('up', '--detach', '--no-build', '--wait', 'postgres')) `
        -WorkingDirectory $root
    Invoke-BunkFyCommand -FilePath 'docker' -Arguments (
        $compose + @(
            'cp', (Join-Path $BackupPath 'postgres.dump'),
            "postgres:$temporaryDump"
        )) -WorkingDirectory $root
    Invoke-BunkFyCommand -FilePath 'docker' -Arguments (
        $compose + @(
            'exec', '-T', 'postgres',
            'pg_restore', '--clean', '--if-exists', '--no-owner', '--exit-on-error',
            '-U', 'bunkfy', '-d', 'bunkfy', $temporaryDump
        )) -WorkingDirectory $root
    Invoke-BunkFyCommand -FilePath 'docker' -Arguments (
        $compose + @('exec', '-T', 'postgres', 'rm', '-f', $temporaryDump)) `
        -WorkingDirectory $root

    if ($LeaveStopped) {
        Invoke-BunkFyCommand -FilePath 'docker' -Arguments (
            $compose + @('stop', 'postgres')) -WorkingDirectory $root
    }
    else {
        Invoke-BunkFyCommand -FilePath 'docker' -Arguments (
            $compose + @('up', '--detach', '--no-build', '--wait')) `
            -WorkingDirectory $root
    }
    $restoreComplete = $true
}
finally {
    & docker @compose exec -T postgres rm -f $temporaryDump 2>$null
    if (-not $restoreComplete -and
        $targetCreationAttempted -and
        $RemoveFailedTarget) {
        & docker @compose down --volumes --remove-orphans 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to remove incomplete restore target '$projectName'."
        }
    }
}

if ($restoreComplete) {
    $state = if ($LeaveStopped) { 'stopped' } else { 'running' }
    Write-Host "Preview restore complete: project '$projectName' is $state."
}
