param(
    [switch] $SkipBootstrap,
    [switch] $SkipFetch
)

. (Join-Path $PSScriptRoot 'common.ps1')

$root = Get-BunkFyRepositoryRoot
$submodules = Get-BunkFySubmoduleConfig

Invoke-BunkFyCommand -FilePath git -Arguments @('submodule', 'sync', '--recursive') -WorkingDirectory $root

foreach ($submodule in $submodules) {
    $path = Join-BunkFyPath $submodule.Path
    $remoteRef = "origin/$($submodule.Branch)"
    $remoteFetchRef = "+refs/heads/$($submodule.Branch):refs/remotes/origin/$($submodule.Branch)"

    Write-Host "Syncing $($submodule.Path) from $remoteRef"
    Invoke-BunkFyCommand -FilePath git -Arguments @('submodule', 'update', '--init', '--recursive', '--', $submodule.Path) -WorkingDirectory $root

    $status = git -C $path status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read status for submodule '$($submodule.Path)'."
    }

    if (@($status).Count -gt 0) {
        throw "Submodule '$($submodule.Path)' has local changes. Commit, stash, or discard them before syncing."
    }

    if (-not $SkipFetch) {
        Invoke-BunkFyCommand -FilePath git -Arguments @('fetch', '--quiet', 'origin', $remoteFetchRef) -WorkingDirectory $path
    }

    git -C $path show-ref --verify --quiet "refs/heads/$($submodule.Branch)"
    $hasLocalBranch = $LASTEXITCODE -eq 0

    if ($hasLocalBranch) {
        Invoke-BunkFyCommand -FilePath git -Arguments @('switch', $submodule.Branch) -WorkingDirectory $path
    }
    else {
        Invoke-BunkFyCommand -FilePath git -Arguments @('switch', '--track', '-c', $submodule.Branch, $remoteRef) -WorkingDirectory $path
    }

    Invoke-BunkFyCommand -FilePath git -Arguments @('pull', '--ff-only', 'origin', $submodule.Branch) -WorkingDirectory $path
}

& (Join-Path $PSScriptRoot 'guard-submodules-latest.ps1') -SkipFetch:$SkipFetch

if (-not $SkipBootstrap) {
    & (Join-Path $PSScriptRoot 'bootstrap.ps1') -SkipSubmodules -SkipFrontendInstall -SkipRestore -Force
}

Write-Host 'Submodule sync complete. Commit root submodule pointer changes when git status shows updated pointers.'
