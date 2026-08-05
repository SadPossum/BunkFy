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
$resolvedComposeJson = & docker compose `
    --env-file $environmentFile `
    -f $composeFile `
    config `
    --format json
if ($LASTEXITCODE -ne 0) {
    throw 'Preview Compose configuration is invalid.'
}

$resolvedCompose = $resolvedComposeJson | ConvertFrom-Json
$migrationsEnvironment = $resolvedCompose.services.migrations.environment
if ($migrationsEnvironment.DOTNET_ENVIRONMENT -ne 'Preview' -or
    $migrationsEnvironment.BunkFy__Deployment__Profile -ne 'Preview') {
    throw 'Preview migrations must retain both the Preview host environment and deployment profile.'
}

$apiEnvironment = $resolvedCompose.services.api.environment
if ($apiEnvironment.DOTNET_ENVIRONMENT -ne 'Preview' -or
    $apiEnvironment.BunkFy__Deployment__Profile -ne 'Preview') {
    throw 'The preview API must retain both the Preview host environment and deployment profile.'
}

$workerEnvironment = $resolvedCompose.services.worker.environment
$requiredWorkerModules = @(
    'Auth',
    'AccessControl',
    'Notifications',
    'Organizations',
    'Properties',
    'Inventory',
    'Reservations',
    'Guests',
    'DataRights',
    'Staff',
    'Ingestion',
    'TaskRuntime'
)

foreach ($module in $requiredWorkerModules) {
    $setting = "Worker__Modules__$module"
    $configuredValue = $workerEnvironment.PSObject.Properties[$setting].Value
    if ($configuredValue -ne 'true') {
        throw "Preview worker module '$module' must be enabled through '$setting'."
    }
}

Write-Host 'BunkFy preview Compose configuration is valid.'

$previewScript = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'preview.ps1') -Raw
foreach ($requiredToken in @('gma-bootstrap.ps1', "@('build', 'up')", '-Force')) {
    if (-not $previewScript.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Preview build source-composition bootstrap is missing '$requiredToken'."
    }
}

Write-Host 'BunkFy preview build bootstrap is valid.'
