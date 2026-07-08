param(
    [ValidateSet('all', 'framework', 'administration', 'auth', 'files', 'notifications', 'task-runtime', 'tenancy')]
    [string[]] $Module = @('all')
)

. (Join-Path $PSScriptRoot 'common.ps1')

$targets = [ordered]@{
    'framework' = 'gma/framework'
    'administration' = 'gma/modules/administration'
    'auth' = 'gma/modules/auth'
    'files' = 'gma/modules/files'
    'notifications' = 'gma/modules/notifications'
    'task-runtime' = 'gma/modules/task-runtime'
    'tenancy' = 'gma/modules/tenancy'
}

$selected = if ($Module -contains 'all') { $targets.Keys } else { $Module }

foreach ($name in $selected) {
    $path = Join-BunkFyPath $targets[$name]
    Write-Host "Updating ${name}: $path"
    Invoke-BunkFyCommand -FilePath git -Arguments @('fetch', 'origin') -WorkingDirectory $path
    Invoke-BunkFyCommand -FilePath git -Arguments @('switch', 'dev') -WorkingDirectory $path
    Invoke-BunkFyCommand -FilePath git -Arguments @('pull', '--ff-only') -WorkingDirectory $path
}

& (Join-Path $PSScriptRoot 'bootstrap.ps1') -SkipSubmodules -SkipFrontendInstall -SkipRestore -Force

Write-Host 'GMA update complete. Review root submodule pointer changes before committing.'

