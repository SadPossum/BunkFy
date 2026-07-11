[CmdletBinding()]
param(
    [switch] $SkipSubmodules,
    [switch] $SkipFrontendInstall,
    [switch] $SkipRestore,
    [switch] $Force
)

. (Join-Path $PSScriptRoot 'common.ps1')

$root = Get-BunkFyRepositoryRoot

if (-not $SkipSubmodules) {
    Invoke-BunkFyCommand -FilePath git -Arguments @('submodule', 'sync', '--recursive')
    Invoke-BunkFyCommand -FilePath git -Arguments @('submodule', 'update', '--init', '--recursive')
}

$backendBootstrap = Join-BunkFyPath 'apps\backend\eng\gma-bootstrap.ps1'
if (Test-Path -LiteralPath $backendBootstrap -PathType Leaf) {
    & $backendBootstrap -Force:$Force
}

if (-not $SkipFrontendInstall) {
    Invoke-BunkFyCommand `
        -FilePath (Resolve-BunkFyPnpm) `
        -Arguments @('--dir', (Join-BunkFyPath 'apps\web'), 'install', '--frozen-lockfile') `
        -WorkingDirectory $root
}

if (-not $SkipRestore) {
    Invoke-BunkFyCommand `
        -FilePath (Resolve-BunkFyDotNet) `
        -Arguments @('restore', (Join-BunkFyPath 'BunkFy.Workspace.slnx')) `
        -WorkingDirectory $root
}

Write-Host 'BunkFy bootstrap complete.'
