[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $EnvironmentPath,
    [string[]] $BackupPath = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'local-sensitive-state.common.ps1')
. (Join-Path $PSScriptRoot 'preview-state.common.ps1')

$root = Get-BunkFyRepositoryRoot
$environmentRequested = $PSBoundParameters.ContainsKey('EnvironmentPath')
$backupRequested = $PSBoundParameters.ContainsKey('BackupPath') -and
    $BackupPath.Count -gt 0
if (-not $environmentRequested -and -not $backupRequested) {
    $EnvironmentPath = Join-BunkFyPath 'deploy\preview\.env'
    $environmentRequested = $true
}

if ($environmentRequested) {
    if ([string]::IsNullOrWhiteSpace($EnvironmentPath)) {
        throw 'EnvironmentPath cannot be empty when it is supplied.'
    }
    $EnvironmentPath = [IO.Path]::GetFullPath($EnvironmentPath)
    [void](Get-BunkFyLocalSensitiveItem `
            -Path $EnvironmentPath `
            -PathType Leaf `
            -Description 'Preview environment')
    if ($PSCmdlet.ShouldProcess(
            $EnvironmentPath,
            'Restrict the Preview environment to the local operator boundary')) {
        Protect-BunkFyLocalSensitivePath `
            -Path $EnvironmentPath `
            -PathType Leaf `
            -Description 'Preview environment'
        Write-Host "Protected Preview environment: $EnvironmentPath"
    }
}

$resolvedBackups = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
foreach ($path in $BackupPath) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw 'BackupPath cannot contain an empty path.'
    }
    $resolved = [IO.Path]::GetFullPath($path)
    if (-not $resolvedBackups.Add($resolved)) {
        throw "BackupPath contains duplicate path '$resolved'."
    }
}

foreach ($path in $resolvedBackups) {
    [void](Get-BunkFyLocalSensitiveTreeEntries `
            -Path $path `
            -Description 'Preview backup')
    if (-not $PSCmdlet.ShouldProcess(
            $path,
            'Restrict the Preview backup tree to the local operator boundary')) {
        continue
    }

    if (Test-BunkFyWindowsPlatform) {
        Protect-BunkFyLocalSensitiveTree `
            -Path $path `
            -Description 'Preview backup'
    }
    else {
        if ($path.Contains(':')) {
            throw "Unix backup path '$path' cannot contain ':' for Docker ownership repair."
        }
        $identity = Get-BunkFyLocalUnixIdentity
        Invoke-BunkFyCommand -FilePath 'docker' -Arguments @(
            'run', '--rm', '--network', 'none',
            '--volume', "${path}:/state",
            $script:BunkFyPreviewArchiveUtilityImage,
            'sh', '-eu', '-c',
            'test -z "$(find /state -type l -print -quit)"; chown -R "$1:$2" /state; find /state -type d -exec chmod 700 {} +; find /state -type f -exec chmod 600 {} +',
            'protect-preview-state', $identity.UserId, $identity.GroupId
        ) -WorkingDirectory $root
    }

    Assert-BunkFyLocalSensitiveTree `
        -Path $path `
        -Description 'Preview backup'
    Write-Host "Protected Preview backup: $path"
}
