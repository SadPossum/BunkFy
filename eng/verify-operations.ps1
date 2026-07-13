Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scripts = @(
    (Join-Path $PSScriptRoot 'operations\admin-api.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\provision-staff-access.ps1'),
    (Join-Path $PSScriptRoot 'operations\offboard-staff-access.ps1'),
    (Join-Path $PSScriptRoot 'operations\backup-preview.ps1'),
    (Join-Path $PSScriptRoot 'new-preview-env.ps1'),
    (Join-Path $PSScriptRoot 'preview.ps1')
)

foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $messages = $errors | ForEach-Object { $_.Message }
        throw "PowerShell syntax validation failed for '$script': $($messages -join '; ')"
    }
}

Write-Host 'BunkFy operations scripts are syntactically valid.'

$composeFile = Join-Path $PSScriptRoot '..\deploy\preview\compose.yaml'
$environmentFile = Join-Path $PSScriptRoot '..\deploy\preview\.env.example'
& docker compose --env-file $environmentFile -f $composeFile config --quiet
if ($LASTEXITCODE -ne 0) {
    throw 'Preview Compose configuration is invalid.'
}

Write-Host 'BunkFy preview Compose configuration is valid.'
