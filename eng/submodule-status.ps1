. (Join-Path $PSScriptRoot 'common.ps1')

$root = Get-BunkFyRepositoryRoot

Write-Host "Repository: $root"
Write-Host ''
Write-Host 'Root status:'
Invoke-BunkFyCommand -FilePath git -Arguments @('status', '--short', '--branch') -WorkingDirectory $root

Write-Host ''
Write-Host 'Submodules:'
Invoke-BunkFyCommand -FilePath git -Arguments @('submodule', 'status', '--recursive') -WorkingDirectory $root

Write-Host ''
Write-Host 'Submodule working trees:'
foreach ($submodule in Get-BunkFySubmoduleConfig) {
    $fullPath = Join-BunkFyPath $submodule.Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        Write-Host "- $($submodule.Path): missing"
        continue
    }

    $branch = git -C $fullPath status --short --branch
    Write-Host "- $($submodule.Path) [$($submodule.Branch)]: $($branch -join ' | ')"
}

