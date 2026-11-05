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

& (Join-Path $PSScriptRoot 'check-repository-security.ps1')
& (Join-Path $PSScriptRoot 'check-product-image-evidence.ps1')

if (-not $SkipSubmoduleGuard) {
    & (Join-Path $PSScriptRoot 'guard-submodules-latest.ps1') -SkipFetch:$SkipSubmoduleFetch
}

& (Join-BunkFyPath 'apps\backend\eng\update-solutions.ps1') -IncludeRootWorkspace -Check
& (Join-Path $PSScriptRoot 'verify-operations.ps1')

if (-not $SkipRestore) {
    Invoke-BunkFyCommand -FilePath $dotnet -Arguments @('restore', (Join-BunkFyPath 'BunkFy.Workspace.slnx'), '--disable-parallel', '-m:1', '-p:BuildInParallel=false') -WorkingDirectory $root
}

if (-not $SkipBuild) {
    Invoke-BunkFyCommand -FilePath $dotnet -Arguments @('build', (Join-BunkFyPath 'BunkFy.Workspace.slnx'), '--no-restore', '-m:1') -WorkingDirectory $root
}

$pnpm = $null
$webRoot = $null
if (-not $SkipFrontend) {
    $pnpm = Resolve-BunkFyPnpm
    $webRoot = Join-BunkFyPath 'apps\web'
    Invoke-BunkFyCommand -FilePath $pnpm -Arguments @('install', '--frozen-lockfile') -WorkingDirectory $webRoot
    if (-not $SkipBackend) {
        & (Join-Path $PSScriptRoot 'update-web-contracts.ps1') -Check -NoBuild
    }
}

if (-not $SkipBackend) {
    $backendVerifyArguments = @()
    if ($SkipRestore) {
        $backendVerifyArguments += '-SkipRestore'
    }

    if ($SkipBuild) {
        $backendVerifyArguments += '-SkipBuild'
    }

    Invoke-BunkFyCommand `
        -FilePath (Join-BunkFyPath 'apps\backend\eng\verify.ps1') `
        -Arguments $backendVerifyArguments `
        -WorkingDirectory (Join-BunkFyPath 'apps\backend')
}

if (-not $SkipFrontend) {
    Invoke-BunkFyCommand -FilePath $pnpm -Arguments @('typecheck') -WorkingDirectory $webRoot
    Invoke-BunkFyCommand -FilePath $pnpm -Arguments @('lint') -WorkingDirectory $webRoot
    Invoke-BunkFyCommand -FilePath $pnpm -Arguments @('test') -WorkingDirectory $webRoot
    Invoke-BunkFyCommand -FilePath $pnpm -Arguments @('build') -WorkingDirectory $webRoot
}

Write-Host 'BunkFy verification complete.'
