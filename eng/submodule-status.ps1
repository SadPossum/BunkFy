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
$submodulePaths = @(
    'apps/backend',
    'apps/web',
    'gma/framework',
    'gma/modules/administration',
    'gma/modules/auth',
    'gma/modules/files',
    'gma/modules/notifications',
    'gma/modules/task-runtime',
    'gma/modules/tenancy'
)

foreach ($path in $submodulePaths) {
    $fullPath = Join-BunkFyPath $path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        Write-Host "- ${path}: missing"
        continue
    }

    $branch = git -C $fullPath status --short --branch
    Write-Host "- ${path}: $($branch -join ' | ')"
}

