param(
    [switch] $SkipFetch
)

. (Join-Path $PSScriptRoot 'common.ps1')

$root = Get-BunkFyRepositoryRoot
$submodules = Get-BunkFySubmoduleConfig
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($submodule in $submodules) {
    $path = Join-BunkFyPath $submodule.Path
    $remoteRef = "origin/$($submodule.Branch)"
    $remoteFetchRef = "+refs/heads/$($submodule.Branch):refs/remotes/origin/$($submodule.Branch)"

    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        $failures.Add("$($submodule.Path): missing checkout. Run .\eng\sync-submodules.ps1.")
        continue
    }

    if (-not $SkipFetch) {
        git -C $path fetch --quiet origin $remoteFetchRef
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("$($submodule.Path): failed to fetch $remoteRef.")
            continue
        }
    }

    $head = (git -C $path rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("$($submodule.Path): failed to resolve local HEAD.")
        continue
    }

    $expected = (git -C $path rev-parse "$remoteRef^{commit}").Trim()
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("$($submodule.Path): failed to resolve $remoteRef.")
        continue
    }

    $headShort = (git -C $path rev-parse --short HEAD).Trim()
    $expectedShort = (git -C $path rev-parse --short "$remoteRef^{commit}").Trim()

    if ($head -ne $expected) {
        $failures.Add("$($submodule.Path): pinned at $headShort, but $remoteRef is $expectedShort. Run .\eng\sync-submodules.ps1 and commit the root pointer update.")
        continue
    }

    Write-Host "OK $($submodule.Path) -> $remoteRef@$expectedShort"
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Submodule latest guard failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }

    throw 'One or more submodules are not at their configured branch tips.'
}

$backendGmaGuard = Join-BunkFyPath 'apps\backend\eng\check-submodule-dev-heads.ps1'
if (Test-Path -LiteralPath $backendGmaGuard -PathType Leaf) {
    & $backendGmaGuard
}

Write-Host 'Submodule latest guard complete.'
