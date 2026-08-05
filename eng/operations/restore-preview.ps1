[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string] $BackupPath,
    [string] $EnvironmentPath,
    [switch] $LeaveStopped
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

$manifestPath = Join-Path $BackupPath 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Backup manifest '$manifestPath' does not exist."
}
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}
catch {
    throw "Backup manifest '$manifestPath' is invalid JSON: $($_.Exception.Message)"
}
if ($manifest.schemaVersion -ne 2) {
    throw "Backup manifest schema '$($manifest.schemaVersion)' is not supported."
}

Assert-BunkFyGitWorktreeClean -RepositoryPath $root
Assert-BunkFyGitWorktreeClean -RepositoryPath (Join-BunkFyPath 'apps\backend')
Assert-BunkFyGitWorktreeClean -RepositoryPath (Join-BunkFyPath 'apps\web')

$expectedCommits = [ordered]@{
    repositoryCommit = Get-BunkFyGitCommit -RepositoryPath $root
    backendCommit = Get-BunkFyGitCommit `
        -RepositoryPath (Join-BunkFyPath 'apps\backend')
    webCommit = Get-BunkFyGitCommit `
        -RepositoryPath (Join-BunkFyPath 'apps\web')
}
foreach ($entry in $expectedCommits.GetEnumerator()) {
    $recorded = [string]$manifest.PSObject.Properties[$entry.Key].Value
    if ($recorded -cne [string]$entry.Value) {
        throw "Backup '$($entry.Key)' is '$recorded', but the checkout is '$($entry.Value)'."
    }
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
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Backup artifact '$file' is missing."
    }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -ne [long]$record.length) {
        throw "Backup artifact '$file' has an unexpected length."
    }
    $digest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($digest -cne [string]$record.sha256) {
        throw "Backup artifact '$file' failed SHA-256 verification."
    }
}
foreach ($file in $expectedArtifacts) {
    if (-not $seenArtifacts.Contains($file)) {
        throw "Backup manifest is missing required artifact '$file'."
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
$recordedImages = @($manifest.images)
if ($recordedImages.Count -ne $expectedImages.Count) {
    throw 'Backup manifest does not contain the exact image set.'
}
foreach ($entry in $expectedImages.GetEnumerator()) {
    $matching = @($recordedImages | Where-Object {
        [string]$_.kind -ceq [string]$entry.Key
    })
    if ($matching.Count -ne 1 -or
        [string]$matching[0].reference -cne [string]$entry.Value) {
        throw "Backup image record '$($entry.Key)' is invalid."
    }
    $localImageId = Get-BunkFyDockerImageId -Reference ([string]$entry.Value)
    if ([string]$matching[0].imageId -cne $localImageId) {
        throw "Local $($entry.Key) image does not match the backed-up image ID."
    }
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
        [Parameter(Mandatory = $true)][string] $Archive
    )

    Invoke-BunkFyCommand -FilePath 'docker' -Arguments @(
        'run', '--rm',
        '--mount', "type=volume,src=$Volume,dst=/target",
        '--mount', "type=bind,src=$BackupPath,dst=/backup,readonly",
        'alpine:3.21',
        'tar', '-xzf', "/backup/$Archive", '-C', '/target'
    ) -WorkingDirectory $root
}

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
        -Archive ([string]$entry.Value)
}

$temporaryDump = '/tmp/bunkfy-preview-restore.dump'
$restoreComplete = $false
try {
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
}

if ($restoreComplete) {
    $state = if ($LeaveStopped) { 'stopped' } else { 'running' }
    Write-Host "Preview restore complete: project '$projectName' is $state."
}
