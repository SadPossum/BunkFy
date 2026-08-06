Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scripts = @(
    (Join-Path $PSScriptRoot 'operations\admin-api.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\provision-staff-access.ps1'),
    (Join-Path $PSScriptRoot 'operations\offboard-staff-access.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-preview-isolation.ps1'),
    (Join-Path $PSScriptRoot 'operations\preview-state.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\backup-preview.ps1'),
    (Join-Path $PSScriptRoot 'operations\restore-preview.ps1'),
    (Join-Path $PSScriptRoot 'operations\rehearse-production-migrations.ps1'),
    (Join-Path $PSScriptRoot 'operations\deployed-public-edge.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\deployed-authenticated-smoke.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-deployed-public-edge.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-deployed-workspace-enrollment.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-deployed-workspace-invitation.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-public-edge.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-workspace-enrollment.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-workspace-invitation.ps1'),
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

. (Join-Path $PSScriptRoot 'operations\admin-api.common.ps1')
. (Join-Path $PSScriptRoot 'operations\preview-state.common.ps1')
if ((Assert-BunkFyAdminApiBaseUri -BaseUri 'http://127.0.0.1:5195') -ne
    'http://127.0.0.1:5195') {
    throw 'The Admin API loopback origin validator did not preserve a valid origin.'
}
$insecureRemoteRejected = $false
try {
    Assert-BunkFyAdminApiBaseUri -BaseUri 'http://admin.example.test:5195' | Out-Null
}
catch {
    $insecureRemoteRejected = $true
}
if (-not $insecureRemoteRejected) {
    throw 'The Admin API origin validator accepted insecure remote HTTP.'
}

Write-Host 'BunkFy Admin API origin validation is valid.'

$legacyStateContract = Get-BunkFyPreviewStateContract -Manifest (
    [pscustomobject]@{ schemaVersion = 2 })
$currentStateContract = Get-BunkFyPreviewStateContract -Manifest (
    [pscustomobject]@{
        schemaVersion = 3
        stateContract = [pscustomobject]@{
            name = $script:BunkFyPreviewStateContractName
            version = $script:BunkFyPreviewStateContractVersion
        }
    })
foreach ($contract in @($legacyStateContract, $currentStateContract)) {
    Assert-BunkFyPreviewStateContractCompatible -Contract $contract
}
$futureStateContractRejected = $false
try {
    $futureStateContract = Get-BunkFyPreviewStateContract -Manifest (
        [pscustomobject]@{
            schemaVersion = 3
            stateContract = [pscustomobject]@{
                name = $script:BunkFyPreviewStateContractName
                version = $script:BunkFyPreviewStateContractVersion + 1
            }
        })
    Assert-BunkFyPreviewStateContractCompatible -Contract $futureStateContract
}
catch {
    $futureStateContractRejected = $true
}
if (-not $futureStateContractRejected) {
    throw 'Preview restore accepted an unsupported future state contract.'
}

Write-Host 'BunkFy preview state-contract compatibility is valid.'

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

if ($null -ne $resolvedCompose.services.PSObject.Properties['admin-api']) {
    throw 'The Admin API must remain outside the default preview service set.'
}

$resolvedOperationsComposeJson = & docker compose `
    --env-file $environmentFile `
    -f $composeFile `
    --profile operations `
    --profile tools `
    config `
    --format json
if ($LASTEXITCODE -ne 0) {
    throw 'Preview operations Compose configuration is invalid.'
}
$resolvedOperationsCompose = $resolvedOperationsComposeJson | ConvertFrom-Json

function Assert-BunkFyServiceNetworks {
    param(
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][string[]] $ExpectedNetworks
    )

    $service = $resolvedOperationsCompose.services.PSObject.Properties[$ServiceName].Value
    $actualNetworks = @($service.networks.PSObject.Properties.Name | Sort-Object)
    $expected = @($ExpectedNetworks | Sort-Object)
    if (@(Compare-Object -ReferenceObject $expected -DifferenceObject $actualNetworks).Count -gt 0) {
        throw "Preview service '$ServiceName' has networks '$($actualNetworks -join ', ')'; expected '$($expected -join ', ')'."
    }
}

Assert-BunkFyServiceNetworks -ServiceName 'web' -ExpectedNetworks @('edge')
Assert-BunkFyServiceNetworks -ServiceName 'api' -ExpectedNetworks @('backend', 'edge')
Assert-BunkFyServiceNetworks -ServiceName 'admin-api' `
    -ExpectedNetworks @('backend', 'management')
foreach ($serviceName in @(
        'postgres',
        'redis',
        'nats',
        'minio',
        'migrations',
        'worker',
        'admin-cli')) {
    Assert-BunkFyServiceNetworks -ServiceName $serviceName -ExpectedNetworks @('backend')
}

if (-not $resolvedOperationsCompose.networks.backend.internal) {
    throw 'The preview backend network must remain internal.'
}
$managementInternal =
    $resolvedOperationsCompose.networks.management.PSObject.Properties['internal']
if ($null -ne $managementInternal -and $managementInternal.Value) {
    throw 'The preview management network must support the loopback host binding.'
}

$adminApi = $resolvedOperationsCompose.services.'admin-api'
if (@($adminApi.profiles).Count -ne 1 -or $adminApi.profiles[0] -ne 'operations') {
    throw 'The Admin API must remain opt-in through only the operations profile.'
}
if ($adminApi.restart -ne 'no') {
    throw 'The preview Admin API must not restart outside an explicit operations window.'
}

foreach ($serviceName in @('web', 'admin-api')) {
    $service = $resolvedOperationsCompose.services.PSObject.Properties[$serviceName].Value
    $ports = @($service.ports)
    if ($ports.Count -ne 1 -or
        $ports[0].host_ip -ne '127.0.0.1' -or
        [int]$ports[0].target -ne 8080) {
        throw "Preview service '$serviceName' must publish port 8080 only on loopback."
    }
}

foreach ($serviceName in @(
        'api',
        'worker',
        'postgres',
        'redis',
        'nats',
        'minio',
        'migrations',
        'admin-cli')) {
    $service = $resolvedOperationsCompose.services.PSObject.Properties[$serviceName].Value
    $portsProperty = $service.PSObject.Properties['ports']
    if ($null -ne $portsProperty -and @($portsProperty.Value).Count -gt 0) {
        throw "Preview service '$serviceName' must not publish a host port."
    }
}

$nginxConfiguration = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot '..\apps\web\nginx.conf') -Raw
if ($nginxConfiguration.Contains('admin-api', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The public edge must not contain an Admin API upstream or route.'
}

Write-Host 'BunkFy preview Compose configuration is valid.'

$previewScript = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'preview.ps1') -Raw
foreach ($requiredToken in @(
        'gma-bootstrap.ps1',
        "@('build', 'up')",
        '-Force',
        'open-operations',
        'close-operations',
        "@('rm', '--stop', '--force', 'admin-api')",
        'docker network rm $managementNetwork')) {
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
        'schemaVersion = 3',
        'stateContract =',
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
        'Get-BunkFyPreviewStateContract',
        'Assert-BunkFyGitCommitRecord',
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
if ($restoreScript.Contains('$expectedCommits', [StringComparison]::Ordinal)) {
    throw 'Preview restore must treat recorded Git commits as provenance, not an exact runtime binding.'
}

Write-Host 'BunkFy preview backup and restore guards are valid.'

$migrationRehearsalScript = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\rehearse-production-migrations.ps1') -Raw
foreach ($requiredToken in @(
        "DOTNET_ENVIRONMENT = 'Production'",
        'cat-file -e',
        "Migrations__Mode = `$Mode",
        'Migrations__ProductionAdmission__ContainerImageDigest',
        'Migrations__ProductionAdmission__ApprovedDatabaseTargetSha256',
        'Migrations__ProductionAdmission__ApprovedTargetCatalogSha256',
        "DataRights__LedgerDelta__Provider = 'External'",
        "DataRights__TenantTerminationReplay__Provider = 'External'",
        'DataRights__Pseudonymisation__Keys__1',
        'DataRights__ReplayEnvelope__Keys__1',
        'DataRights__ExportArtifacts__Keys__1',
        'Ingestion__AnonymisationFingerprints__Keys__1',
        "'network',",
        "'create',",
        "'--internal',",
        "'--rm'",
        'Get-BunkFyDatabaseSchemaFingerprint',
        "'pg_dump',",
        "'--schema-only',",
        'Malformed source admission',
        'Malformed backup-evidence admission',
        'Wrong database-target admission',
        'PendingMigrationCount -ne 0',
        'Approved apply rerun',
        'Remove-BunkFyRehearsalResources',
        'resourcesRemoved = $true',
        "evidenceKind = 'bunkfy-production-migration-rehearsal'")) {
    if (-not $migrationRehearsalScript.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Production migration rehearsal guard is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'docker pull',
        'docker build',
        "'--publish'",
        "'-p'")) {
    if ($migrationRehearsalScript.Contains($forbiddenToken, [StringComparison]::Ordinal)) {
        throw "Production migration rehearsal contains forbidden token '$forbiddenToken'."
    }
}

Write-Host 'BunkFy Production migration rehearsal policy is valid.'

$deployedEdgeCommon = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\deployed-public-edge.common.ps1') -Raw
foreach ($requiredToken in @(
        '$script:BunkFyPublicEdgeMaximumBodyBytes = 64KB',
        'Assert-BunkFyPublicEdgeOrigin',
        'Assert-BunkFyPublicEdgeSecurityHeaders',
        'Assert-BunkFySmokeResponse',
        'HttpCompletionOption]::ResponseHeadersRead',
        'CancellationTokenSource',
        'Content-Security-Policy',
        'Strict-Transport-Security')) {
    if (-not $deployedEdgeCommon.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed public edge common policy is missing '$requiredToken'."
    }
}

$deployedEdgeProbe = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\verify-deployed-public-edge.ps1') -Raw
foreach ($requiredToken in @(
        '$handler.AllowAutoRedirect = $false',
        '/healthz',
        '/api/smoke',
        '/api/admin/audit/',
        '-HostHeader $UntrustedHost',
        "evidenceKind = 'bunkfy-deployed-public-edge-probe'",
        "'release-identity-not-observed'",
        "'private-infrastructure-not-observed'",
        "'authenticated-workflows-not-executed'")) {
    if (-not $deployedEdgeProbe.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed public edge probe policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        'Authorization',
        'sourceCommit',
        'imageDigest',
        '$handler.AllowAutoRedirect = $true')) {
    if ($deployedEdgeProbe.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployed public edge probe contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-deployed-public-edge.ps1')
Write-Host 'BunkFy deployed public edge probe policy is valid.'

$authenticatedSmokeCommon = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\deployed-authenticated-smoke.common.ps1') -Raw
foreach ($requiredToken in @(
        '$script:BunkFyAuthenticatedSmokeMaximumBodyBytes = 256KB',
        'Resolve-BunkFySmokeAccessToken',
        'AuthenticationHeaderValue',
        'X-Tenant-Id',
        'HttpCompletionOption]::ResponseHeadersRead',
        'CancellationTokenSource')) {
    if (-not $authenticatedSmokeCommon.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed authenticated smoke common policy is missing '$requiredToken'."
    }
}

$workspaceInvitationProbe = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\verify-deployed-workspace-invitation.ps1') -Raw
foreach ($requiredToken in @(
        "SupportsShouldProcess = `$true",
        '$handler.AllowAutoRedirect = $false',
        'BUNKFY_SMOKE_OWNER_TOKEN',
        'BUNKFY_SMOKE_APPLICANT_TOKEN',
        '/api/workspace-staff-enrollment/sources/invitations',
        '/api/organization-invitations/preview',
        '/api/organization-invitations/accept',
        '/api/access/permissions/evaluate',
        "'properties.read'",
        "'staff.manage'",
        'Revoke-SmokeInvitationBestEffort',
        "evidenceKind = 'bunkfy-deployed-workspace-invitation-probe'",
        "'browser-ui-not-exercised'",
        "'joined-member-not-automatically-offboarded'")) {
    if (-not $workspaceInvitationProbe.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed workspace invitation probe policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        '$handler.AllowAutoRedirect = $true')) {
    if ($workspaceInvitationProbe.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase) -or
        $authenticatedSmokeCommon.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployed workspace invitation probe contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-deployed-workspace-invitation.ps1')
Write-Host 'BunkFy deployed workspace invitation probe policy is valid.'

$workspaceEnrollmentProbe = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\verify-deployed-workspace-enrollment.ps1') -Raw
foreach ($requiredToken in @(
        "SupportsShouldProcess = `$true",
        '$handler.AllowAutoRedirect = $false',
        'BUNKFY_SMOKE_OWNER_TOKEN',
        'BUNKFY_SMOKE_APPLICANT_TOKEN',
        '/api/workspace-staff-enrollment/sources/enrollment-links',
        '/api/organization-enrollment/preview',
        '/api/organization-enrollment/claim',
        '/join-requests/',
        "-Decision reject",
        "-Decision approve",
        "'properties.read'",
        "'staff.manage'",
        'Disable-SmokeEnrollmentSourcesBestEffort',
        "evidenceKind = 'bunkfy-deployed-workspace-enrollment-probe'",
        "'browser-ui-and-qr-rendering-not-exercised'",
        "'joined-member-not-automatically-offboarded'")) {
    if (-not $workspaceEnrollmentProbe.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed workspace enrollment probe policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        '$handler.AllowAutoRedirect = $true')) {
    if ($workspaceEnrollmentProbe.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployed workspace enrollment probe contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-deployed-workspace-enrollment.ps1')
Write-Host 'BunkFy deployed workspace enrollment probe policy is valid.'
