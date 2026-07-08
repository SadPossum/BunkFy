param(
    [switch] $SkipRestore,
    [switch] $SkipBuild,
    [switch] $SkipFrontend,
    [switch] $SkipBackend,
    [switch] $SkipSubmoduleGuard,
    [switch] $SkipSubmoduleFetch
)

. (Join-Path $PSScriptRoot 'common.ps1')

& (Join-Path $PSScriptRoot 'bootstrap.ps1') -SkipSubmodules -SkipFrontendInstall -SkipRestore

$root = Get-BunkFyRepositoryRoot
$dotnet = Resolve-BunkFyDotNet

if (-not $SkipSubmoduleGuard) {
    & (Join-Path $PSScriptRoot 'guard-submodules-latest.ps1') -SkipFetch:$SkipSubmoduleFetch
}

if (-not $SkipRestore) {
    Invoke-BunkFyCommand -FilePath $dotnet -Arguments @('restore', (Join-BunkFyPath 'BunkFy.slnx')) -WorkingDirectory $root

    if (-not $SkipBackend) {
        Invoke-BunkFyCommand -FilePath $dotnet -Arguments @('restore', (Join-BunkFyPath 'apps\backend\BunkFy.slnx')) -WorkingDirectory (Join-BunkFyPath 'apps\backend')
    }
}

if (-not $SkipBuild) {
    Invoke-BunkFyCommand -FilePath $dotnet -Arguments @('build', (Join-BunkFyPath 'BunkFy.slnx'), '--no-restore', '-m:1') -WorkingDirectory $root
}

if (-not $SkipBackend) {
    Invoke-BunkFyCommand -FilePath $dotnet -Arguments @('build', (Join-BunkFyPath 'apps\backend\BunkFy.slnx'), '--no-restore', '-m:1') -WorkingDirectory (Join-BunkFyPath 'apps\backend')
}

if (-not $SkipFrontend) {
    $pnpm = Resolve-BunkFyPnpm
    $webRoot = Join-BunkFyPath 'apps\web'
    Invoke-BunkFyCommand -FilePath $pnpm -Arguments @('install', '--frozen-lockfile') -WorkingDirectory $webRoot
    Invoke-BunkFyCommand -FilePath $pnpm -Arguments @('typecheck') -WorkingDirectory $webRoot
    Invoke-BunkFyCommand -FilePath $pnpm -Arguments @('lint') -WorkingDirectory $webRoot
    Invoke-BunkFyCommand -FilePath $pnpm -Arguments @('test') -WorkingDirectory $webRoot
    Invoke-BunkFyCommand -FilePath $pnpm -Arguments @('build') -WorkingDirectory $webRoot
}

Write-Host 'BunkFy verification complete.'
