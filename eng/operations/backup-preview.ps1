[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $EnvironmentPath,
    [string] $OutputPath
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
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $OutputPath = Join-BunkFyPath ".tmp\backups\preview-$stamp"
}

$EnvironmentPath = [IO.Path]::GetFullPath($EnvironmentPath)
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath $EnvironmentPath -PathType Leaf)) {
    throw "Preview environment '$EnvironmentPath' does not exist."
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Backup destination '$OutputPath' already exists."
}

$compose = @(
    'compose', '--env-file', $EnvironmentPath, '-f', $composePath
)
$composeDefinition = Get-BunkFyPreviewComposeDefinition `
    -Root $root `
    -ComposePath $composePath `
    -EnvironmentPath $EnvironmentPath
$projectName = [string]$composeDefinition.name
if ([string]::IsNullOrWhiteSpace($projectName)) {
    throw 'Preview Compose configuration has no resolved project name.'
}
$volumeMap = Get-BunkFyPreviewVolumeMap -ComposeDefinition $composeDefinition
$backendImageReference = [string]$composeDefinition.services.api.image
$webImageReference = [string]$composeDefinition.services.web.image
foreach ($service in @('migrations', 'worker')) {
    if ([string]$composeDefinition.services.PSObject.Properties[$service].Value.image -cne
        $backendImageReference) {
        throw "Preview service '$service' does not use the API backend image."
    }
}
$imageRecords = @(
    [ordered]@{
        kind = 'backend'
        reference = $backendImageReference
        imageId = Get-BunkFyDockerImageId -Reference $backendImageReference
    }
    [ordered]@{
        kind = 'web'
        reference = $webImageReference
        imageId = Get-BunkFyDockerImageId -Reference $webImageReference
    }
)

Assert-BunkFyGitWorktreeClean -RepositoryPath $root
Assert-BunkFyGitWorktreeClean -RepositoryPath (Join-BunkFyPath 'apps\backend')
Assert-BunkFyGitWorktreeClean -RepositoryPath (Join-BunkFyPath 'apps\web')

function Invoke-PreviewCompose {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    Invoke-BunkFyCommand -FilePath 'docker' -Arguments ($compose + $Arguments) -WorkingDirectory $root
}

function Backup-BunkFyVolume {
    param(
        [Parameter(Mandatory = $true)][string] $Volume,
        [Parameter(Mandatory = $true)][string] $Archive
    )

    Invoke-BunkFyCommand -FilePath 'docker' -Arguments @(
        'run', '--rm',
        '--mount', "type=volume,src=$Volume,dst=/source,readonly",
        '--mount', "type=bind,src=$OutputPath,dst=/backup",
        'alpine:3.21',
        'tar', '-czf', "/backup/$Archive", '-C', '/source', '.'
    ) -WorkingDirectory $root
}

$runningServices = @(& docker @compose ps --services --filter status=running)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect the preview stack.'
}
if ($runningServices -notcontains 'postgres') {
    throw 'The preview PostgreSQL service must be running before backup.'
}
foreach ($service in @('api', 'worker', 'web')) {
    if ($runningServices -notcontains $service) {
        continue
    }

    $containerIds = @(& docker @compose ps --quiet $service)
    if ($LASTEXITCODE -ne 0 -or $containerIds.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$containerIds[0])) {
        throw "Unable to resolve the running preview '$service' container."
    }
    $runningImageIds = @(& docker inspect --format '{{.Image}}' $containerIds[0])
    if ($LASTEXITCODE -ne 0 -or $runningImageIds.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$runningImageIds[0])) {
        throw "Unable to inspect the running preview '$service' image."
    }
    $runningImageId = ([string]$runningImageIds[0]).Trim()
    $imageKind = if ($service -eq 'web') { 'web' } else { 'backend' }
    $expectedImageId = [string]($imageRecords |
        Where-Object { $_.kind -eq $imageKind }).imageId
    if ($runningImageId -cne $expectedImageId) {
        throw "Running preview service '$service' does not use the tagged $imageKind image."
    }
}

$existingVolumes = @(& docker volume ls --format '{{.Name}}')
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect Docker volumes.'
}
$existingVolumeSet = [Collections.Generic.HashSet[string]]::new(
    [string[]]$existingVolumes,
    [StringComparer]::Ordinal)
foreach ($entry in $volumeMap.GetEnumerator()) {
    if (-not $existingVolumeSet.Contains([string]$entry.Value)) {
        throw "Required preview volume '$($entry.Value)' does not exist."
    }
}

if (-not $PSCmdlet.ShouldProcess(
        $OutputPath,
        'Briefly quiesce the preview stack and create a recoverable backup')) {
    return
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$appServices = @('web', 'admin-api', 'api', 'worker') |
    Where-Object { $runningServices -contains $_ }
$stateServices = @('nats', 'redis', 'minio') |
    Where-Object { $runningServices -contains $_ }
$temporaryDump = '/tmp/bunkfy-preview.dump'
$backupComplete = $false

try {
    if ($appServices.Count -gt 0) {
        Invoke-PreviewCompose -Arguments (@('stop') + $appServices)
    }

    Invoke-PreviewCompose -Arguments @(
        'exec', '-T', 'postgres',
        'pg_dump', '-U', 'bunkfy', '-d', 'bunkfy',
        '--format=custom', "--file=$temporaryDump"
    )
    Invoke-PreviewCompose -Arguments @(
        'cp', "postgres:$temporaryDump", (Join-Path $OutputPath 'postgres.dump')
    )
    Invoke-PreviewCompose -Arguments @('exec', '-T', 'postgres', 'rm', '-f', $temporaryDump)

    if ($stateServices.Count -gt 0) {
        Invoke-PreviewCompose -Arguments (@('stop') + $stateServices)
    }

    foreach ($entry in $script:BunkFyPreviewStateArchives.GetEnumerator()) {
        Backup-BunkFyVolume `
            -Volume ([string]$volumeMap[$entry.Key]) `
            -Archive ([string]$entry.Value)
    }

    $artifacts = Get-ChildItem -LiteralPath $OutputPath -File |
        Sort-Object -Property Name |
        ForEach-Object {
            [ordered]@{
                file = $_.Name
                length = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    $manifest = [ordered]@{
        schemaVersion = 2
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        projectName = $projectName
        repositoryCommit = Get-BunkFyGitCommit -RepositoryPath $root
        backendCommit = Get-BunkFyGitCommit `
            -RepositoryPath (Join-BunkFyPath 'apps\backend')
        webCommit = Get-BunkFyGitCommit `
            -RepositoryPath (Join-BunkFyPath 'apps\web')
        stateVolumes = @(
            $script:BunkFyPreviewStateArchives.GetEnumerator() | ForEach-Object {
                [ordered]@{
                    logicalName = $_.Key
                    dockerName = [string]$volumeMap[$_.Key]
                    artifact = $_.Value
                }
            }
        )
        images = $imageRecords
        artifacts = @($artifacts)
    }
    $manifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $OutputPath 'manifest.json') -Encoding utf8
    $backupComplete = $true
}
finally {
    & docker @compose exec -T postgres rm -f $temporaryDump 2>$null
    $defaultServices = @($runningServices | Where-Object { $_ -ne 'admin-api' })
    if ($defaultServices.Count -gt 0) {
        Invoke-PreviewCompose -Arguments (
            @('up', '--detach', '--no-build', '--wait') + $defaultServices)
    }
    if ($runningServices -contains 'admin-api') {
        Invoke-BunkFyCommand -FilePath 'docker' -Arguments (
            $compose + @(
                '--profile', 'operations', 'up', '--detach', '--no-build', '--wait', 'admin-api'
            )) -WorkingDirectory $root
    }
}

if ($backupComplete) {
    Write-Host "Preview backup complete: $OutputPath"
}
