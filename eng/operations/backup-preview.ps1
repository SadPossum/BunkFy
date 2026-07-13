[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $EnvironmentPath,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')

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

    $volumes = [ordered]@{
        'bunkfy-preview-minio-data' = 'minio-data.tar.gz'
        'bunkfy-preview-nats-data' = 'nats-data.tar.gz'
        'bunkfy-preview-redis-data' = 'redis-data.tar.gz'
        'bunkfy-preview-data-protection' = 'data-protection.tar.gz'
        'bunkfy-preview-adapter-file-drop' = 'adapter-file-drop.tar.gz'
    }
    foreach ($entry in $volumes.GetEnumerator()) {
        Backup-BunkFyVolume -Volume $entry.Key -Archive $entry.Value
    }

    $artifacts = Get-ChildItem -LiteralPath $OutputPath -File | ForEach-Object {
        [ordered]@{
            file = $_.Name
            length = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        repositoryCommit = (& git -C $root rev-parse HEAD).Trim()
        backendCommit = (& git -C (Join-BunkFyPath 'apps\backend') rev-parse HEAD).Trim()
        webCommit = (& git -C (Join-BunkFyPath 'apps\web') rev-parse HEAD).Trim()
        artifacts = @($artifacts)
    }
    $manifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $OutputPath 'manifest.json') -Encoding utf8
    $backupComplete = $true
}
finally {
    & docker @compose exec -T postgres rm -f $temporaryDump 2>$null
    Invoke-PreviewCompose -Arguments @('up', '--detach', '--no-build', '--wait')
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
