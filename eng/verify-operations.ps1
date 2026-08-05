Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scripts = @(
    (Join-Path $PSScriptRoot 'operations\admin-api.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\provision-staff-access.ps1'),
    (Join-Path $PSScriptRoot 'operations\offboard-staff-access.ps1'),
    (Join-Path $PSScriptRoot 'operations\preview-state.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\backup-preview.ps1'),
    (Join-Path $PSScriptRoot 'operations\restore-preview.ps1'),
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
if ($resolvedCompose.name -ne 'bunkfy-preview') {
    throw 'Preview Compose must retain its default project name.'
}
$expectedVolumeNames = [ordered]@{
    'postgres-data' = 'bunkfy-preview-postgres-data'
    'redis-data' = 'bunkfy-preview-redis-data'
    'nats-data' = 'bunkfy-preview-nats-data'
    'minio-data' = 'bunkfy-preview-minio-data'
    'data-protection' = 'bunkfy-preview-data-protection'
    'adapter-file-drop' = 'bunkfy-preview-adapter-file-drop'
    'data-rights-ledger-delta' = 'bunkfy-preview-data-rights-ledger-delta'
}
foreach ($entry in $expectedVolumeNames.GetEnumerator()) {
    $actual = [string]$resolvedCompose.volumes.PSObject.Properties[$entry.Key].Value.name
    if ($actual -cne $entry.Value) {
        throw "Preview volume '$($entry.Key)' resolved to '$actual'."
    }
}
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
if ($resolvedCompose.services.api.image -ne 'bunkfy/backend:preview' -or
    $resolvedCompose.services.migrations.image -ne $resolvedCompose.services.api.image -or
    $resolvedCompose.services.worker.image -ne $resolvedCompose.services.api.image -or
    $resolvedCompose.services.web.image -ne 'bunkfy/web:preview') {
    throw 'Preview services must retain explicit, shared backend and web image identities.'
}
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
    'Retention',
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

$backupScript = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\backup-preview.ps1') -Raw
foreach ($requiredToken in @(
        'Get-BunkFyPreviewVolumeMap',
        'Assert-BunkFyGitWorktreeClean',
        'Get-BunkFyDockerImageId',
        "docker volume ls --format '{{.Name}}'",
        '$defaultServices')) {
    if (-not $backupScript.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Preview backup guard is missing '$requiredToken'."
    }
}

$restoreScript = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\restore-preview.ps1') -Raw
foreach ($requiredToken in @(
        'Get-FileHash',
        'Get-BunkFyGitCommit',
        'Assert-BunkFyGitWorktreeClean',
        'Get-BunkFyDockerImageId',
        '--exit-on-error',
        "@('create', '--no-build')",
        'already has containers',
        'already exists')) {
    if (-not $restoreScript.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Preview restore guard is missing '$requiredToken'."
    }
}

Write-Host 'BunkFy preview backup and restore guards are valid.'
