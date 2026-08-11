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
    (Join-Path $PSScriptRoot 'operations\rehearse-preview-recovery.ps1'),
    (Join-Path $PSScriptRoot 'operations\rehearse-production-migrations.ps1'),
    (Join-Path $PSScriptRoot 'image-promotion.common.ps1'),
    (Join-Path $PSScriptRoot 'verify-image-promotion.ps1'),
    (Join-Path $PSScriptRoot 'production-admission.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\assemble-production-admission.ps1'),
    (Join-Path $PSScriptRoot 'verify-production-admission.ps1'),
    (Join-Path $PSScriptRoot 'operations\deployed-public-edge.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\deployed-authenticated-smoke.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\preview-mail-capture.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\preview-property-processing-fixture.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\preview-sellable-room-fixture.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\rehearse-preview-onboarding.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-deployed-adapter-host.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-deployed-admin-boundary.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-deployed-public-edge.ps1'),
    (Join-Path $PSScriptRoot 'operations\rehearse-deployed-release-rollback.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-deployed-operations-notifications.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-deployed-reservations-inventory.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-deployed-workspace-enrollment.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-deployed-workspace-invitation.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-deployed-retention.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-adapter-host.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-admin-boundary.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-public-edge.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-release-rollback.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-operations-notifications.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-reservations-inventory.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-workspace-enrollment.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-workspace-invitation.ps1'),
    (Join-Path $PSScriptRoot 'test-preview-mail-capture.ps1'),
    (Join-Path $PSScriptRoot 'test-preview-property-processing-fixture.ps1'),
    (Join-Path $PSScriptRoot 'test-preview-sellable-room-fixture.ps1'),
    (Join-Path $PSScriptRoot 'test-deployed-retention.ps1'),
    (Join-Path $PSScriptRoot 'test-production-admission.ps1'),
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
$schemaThreeStateContract = Get-BunkFyPreviewStateContract -Manifest (
    [pscustomobject]@{
        schemaVersion = 3
        stateContract = [pscustomobject]@{
            name = $script:BunkFyPreviewStateContractName
            version = $script:BunkFyPreviewStateContractVersion
        }
    })
$currentStateContract = Get-BunkFyPreviewStateContract -Manifest (
    [pscustomobject]@{
        schemaVersion = 4
        stateContract = [pscustomobject]@{
            name = $script:BunkFyPreviewStateContractName
            version = $script:BunkFyPreviewStateContractVersion
        }
    })
foreach ($contract in @(
        $legacyStateContract,
        $schemaThreeStateContract,
        $currentStateContract)) {
    Assert-BunkFyPreviewStateContractCompatible -Contract $contract
}
$futureStateContractRejected = $false
try {
    $futureStateContract = Get-BunkFyPreviewStateContract -Manifest (
        [pscustomobject]@{
            schemaVersion = 4
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

$manifestFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-preview-manifest-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $manifestFixtureRoot)
try {
    $manifestFixturePath = Join-Path $manifestFixtureRoot 'manifest.json'
    [IO.File]::WriteAllText(
        $manifestFixturePath,
        "{`"schemaVersion`":4}`n",
        [Text.UTF8Encoding]::new($false))
    $manifestFixtureDigest = (Get-FileHash `
            -LiteralPath $manifestFixturePath `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $manifestFixtureRoot $script:BunkFyPreviewManifestDigestFileName),
        "$manifestFixtureDigest`n",
        [Text.UTF8Encoding]::new($false))
    [void](Assert-BunkFyBackupManifestIntegrity `
            -ManifestPath $manifestFixturePath `
            -SchemaVersion 4 `
            -ExpectedSha256 $manifestFixtureDigest)

    $firstTree = Join-Path $manifestFixtureRoot 'first-tree'
    $secondTree = Join-Path $manifestFixtureRoot 'second-tree'
    [void](New-Item -ItemType Directory -Path (Join-Path $firstTree 'nested') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $secondTree 'nested') -Force)
    foreach ($tree in @($firstTree, $secondTree)) {
        [IO.File]::WriteAllText(
            (Join-Path $tree 'nested/state.txt'),
            "recovery-state`n",
            [Text.UTF8Encoding]::new($false))
    }
    $firstFingerprint = Get-BunkFyStateTreeFingerprint -Path $firstTree
    $secondFingerprint = Get-BunkFyStateTreeFingerprint -Path $secondTree
    if ($firstFingerprint.FileCount -ne 1 -or
        $firstFingerprint.TotalBytes -ne $secondFingerprint.TotalBytes -or
        $firstFingerprint.Sha256 -cne $secondFingerprint.Sha256) {
        throw 'Preview recovery state-tree fingerprint is not deterministic.'
    }
    [IO.File]::AppendAllText(
        (Join-Path $secondTree 'nested/state.txt'),
        "changed`n",
        [Text.UTF8Encoding]::new($false))
    $changedFingerprint = Get-BunkFyStateTreeFingerprint -Path $secondTree
    if ($changedFingerprint.Sha256 -ceq $firstFingerprint.Sha256) {
        throw 'Preview recovery state-tree fingerprint did not detect changed content.'
    }

    [IO.File]::AppendAllText(
        $manifestFixturePath,
        " `n",
        [Text.UTF8Encoding]::new($false))
    $tamperedManifestRejected = $false
    try {
        [void](Assert-BunkFyBackupManifestIntegrity `
                -ManifestPath $manifestFixturePath `
                -SchemaVersion 4)
    }
    catch {
        $tamperedManifestRejected = $true
    }
    if (-not $tamperedManifestRejected) {
        throw 'Preview backup manifest integrity accepted modified content.'
    }
}
finally {
    Remove-Item -LiteralPath $manifestFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
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
    $apiEnvironment.BunkFy__Deployment__Profile -ne 'Preview' -or
    $apiEnvironment.BunkFy__Deployment__ReleaseId -ne 'preview-local') {
    throw 'The preview API must retain its host environment, deployment profile, and release identity.'
}
if ($apiEnvironment.AllowedHosts -cne 'localhost;127.0.0.1' -or
    $apiEnvironment.Http__AllowAnyHost -cne 'false') {
    throw 'The preview API must use explicit local host filtering by default.'
}
if ($apiEnvironment.Email__Smtp__Enabled -ne 'true' -or
    $apiEnvironment.Email__Smtp__Host -cne 'mailpit' -or
    $apiEnvironment.Email__Smtp__Port -ne '1025' -or
    $apiEnvironment.Email__Smtp__SecurityMode -cne 'None' -or
    $apiEnvironment.Notifications__Adapters__Email__Enabled -ne 'true') {
    throw 'The generated Preview environment must compose API email verification through private Mailpit capture.'
}
$previewPolicyPath = [IO.Path]::GetFullPath((Join-Path `
        $PSScriptRoot `
        '..\apps\backend\eng\country-policies\development\example-hostel-policy.v2.json'))
$previewPolicyDigest = (Get-FileHash `
        -LiteralPath $previewPolicyPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedPreviewPolicySettings = [ordered]@{
    BunkFy__CountryPolicies__PackDirectory = '/etc/bunkfy/country-policies'
    BunkFy__CountryPolicies__Allowlist__0__OperatingCountryCode = 'GB'
    BunkFy__CountryPolicies__Allowlist__0__PolicyId = 'development-hostel-example'
    BunkFy__CountryPolicies__Allowlist__0__PolicyVersion = '2'
    BunkFy__CountryPolicies__Allowlist__0__ContentSha256 = $previewPolicyDigest
    BunkFy__CountryPolicies__Allowlist__0__LaunchStatus = 'Engineering'
}
$expectedPreviewPolicySource = [IO.Path]::GetFullPath((Join-Path `
        $PSScriptRoot `
        '..\apps\backend\eng\country-policies\development'))
foreach ($serviceName in @('api', 'worker')) {
    $service = $resolvedCompose.services.PSObject.Properties[$serviceName].Value
    foreach ($setting in $expectedPreviewPolicySettings.GetEnumerator()) {
        $actual = [string]$service.environment.PSObject.Properties[$setting.Key].Value
        if ($actual -cne [string]$setting.Value) {
            throw "Preview $serviceName country-policy setting '$($setting.Key)' is not digest-pinned."
        }
    }

    $policyMounts = @($service.volumes | Where-Object {
            [string]$_.target -ceq '/etc/bunkfy/country-policies'
        })
    if ($policyMounts.Count -ne 1 -or
        [string]$policyMounts[0].type -cne 'bind' -or
        [IO.Path]::GetFullPath([string]$policyMounts[0].source) -cne $expectedPreviewPolicySource -or
        -not [bool]$policyMounts[0].read_only -or
        [bool]$policyMounts[0].bind.create_host_path) {
        throw "Preview $serviceName must mount the tracked engineering policy pack read-only without creating a missing host path."
    }
}

$remoteEnvironmentFile = Join-Path (
    [IO.Path]::GetTempPath()) "bunkfy-preview-remote-$([Guid]::NewGuid().ToString('N')).env"
try {
    $remoteEnvironment = Get-Content -LiteralPath $environmentFile -Raw
    $remoteEnvironment = $remoteEnvironment.Replace(
        'BUNKFY_PUBLIC_URL=http://localhost:8080',
        'BUNKFY_PUBLIC_URL=https://preview.example.test')
    $remoteEnvironment = $remoteEnvironment.Replace(
        'BUNKFY_ALLOWED_HOSTS=localhost;127.0.0.1',
        'BUNKFY_ALLOWED_HOSTS=preview.example.test;localhost;127.0.0.1')
    [IO.File]::WriteAllText(
        $remoteEnvironmentFile,
        $remoteEnvironment,
        [Text.UTF8Encoding]::new($false))
    $remoteComposeJson = & docker compose `
        --env-file $remoteEnvironmentFile `
        -f $composeFile `
        config `
        --format json
    if ($LASTEXITCODE -ne 0) {
        throw 'Remote preview Compose configuration is invalid.'
    }
    $remoteCompose = $remoteComposeJson | ConvertFrom-Json
    $remoteApiEnvironment = $remoteCompose.services.api.environment
    if ($remoteApiEnvironment.AllowedHosts -cne
            'preview.example.test;localhost;127.0.0.1' -or
        $remoteApiEnvironment.Http__AllowAnyHost -cne 'false') {
        throw 'Remote preview host filtering did not retain its explicit environment value.'
    }
}
finally {
    Remove-Item -LiteralPath $remoteEnvironmentFile -Force -ErrorAction SilentlyContinue
}

$workerEnvironment = $resolvedCompose.services.worker.environment
if ($workerEnvironment.BunkFy__Deployment__ReleaseId -ne
    $apiEnvironment.BunkFy__Deployment__ReleaseId) {
    throw 'Preview API and Worker must share one release identity.'
}
foreach ($setting in @(
        'Email__Smtp__Enabled',
        'Email__Smtp__Host',
        'Email__Smtp__Port',
        'Email__Smtp__SecurityMode',
        'Email__Smtp__DefaultSenderAddress',
        'Email__Smtp__DefaultSenderName',
        'Email__Smtp__AllowSenderOverride',
        'Email__Smtp__TimeoutSeconds',
        'Notifications__Adapters__Email__Enabled')) {
    if ($workerEnvironment.PSObject.Properties[$setting].Value -cne
        $apiEnvironment.PSObject.Properties[$setting].Value) {
        throw "Preview API and Worker email setting '$setting' must be identical."
    }
}
if ($workerEnvironment.Notifications__Delivery__Enabled -ne 'true') {
    throw 'The generated Preview environment must enable durable notification delivery for captured email.'
}
$webEnvironment = $resolvedCompose.services.web.environment
if ($webEnvironment.BUNKFY_RELEASE_ID -ne
    $apiEnvironment.BunkFy__Deployment__ReleaseId) {
    throw 'Preview web, API, and Worker must share one release identity.'
}
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
        'mailpit',
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
$adminEnvironment = $adminApi.environment
if ($adminEnvironment.AllowedHosts -cne 'localhost;127.0.0.1' -or
    $adminEnvironment.Http__AllowAnyHost -cne 'false') {
    throw 'The preview Admin API must use explicit local host filtering by default.'
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
        'mailpit',
        'migrations',
        'admin-cli')) {
    $service = $resolvedOperationsCompose.services.PSObject.Properties[$serviceName].Value
    $portsProperty = $service.PSObject.Properties['ports']
    if ($null -ne $portsProperty -and @($portsProperty.Value).Count -gt 0) {
        throw "Preview service '$serviceName' must not publish a host port."
    }
}

$mailpit = $resolvedOperationsCompose.services.mailpit
if ($mailpit.image -cne
    'axllent/mailpit:v1.30.7@sha256:d5ecbb067db3705fa953d79e1b7f81ef84038df67aba6c52825d8c02a1ea748a' -or
    $mailpit.restart -cne 'unless-stopped' -or
    $mailpit.environment.MP_MAX_MESSAGES -ne '500' -or
    $mailpit.environment.MP_DISABLE_VERSION_CHECK -ne 'true') {
    throw 'Preview Mailpit must retain its pinned, bounded capture configuration.'
}
if (@($mailpit.tmpfs).Count -ne 1 -or
    $mailpit.tmpfs[0] -cne '/data:size=67108864,mode=0700') {
    throw 'Preview Mailpit capture must remain ephemeral and size-bounded on tmpfs.'
}

$mailpitOperatorCompose = Join-Path $PSScriptRoot `
    '..\deploy\preview\compose.mailpit-operator.yaml'
$resolvedMailpitOperatorJson = & docker compose `
    --env-file $environmentFile `
    -f $composeFile `
    -f $mailpitOperatorCompose `
    config `
    --format json
if ($LASTEXITCODE -ne 0) {
    throw 'Preview Mailpit operator Compose overlay is invalid.'
}
$resolvedMailpitOperator = $resolvedMailpitOperatorJson | ConvertFrom-Json
$mailpitOperatorPorts = @($resolvedMailpitOperator.services.mailpit.ports)
if ($mailpitOperatorPorts.Count -ne 1 -or
    $mailpitOperatorPorts[0].host_ip -cne '127.0.0.1' -or
    [int]$mailpitOperatorPorts[0].target -ne 8025) {
    throw 'The Mailpit operator overlay must publish only its UI on loopback.'
}
$mailpitOperatorNetworks = @(
    $resolvedMailpitOperator.services.mailpit.networks.PSObject.Properties.Name |
        Sort-Object)
$mailpitOperatorNetwork = $resolvedMailpitOperator.networks.PSObject.Properties[
    'mailpit-operator']
$mailpitOperatorInternal = if ($null -eq $mailpitOperatorNetwork -or
    $null -eq $mailpitOperatorNetwork.Value.PSObject.Properties['internal']) {
    $false
}
else {
    [bool]$mailpitOperatorNetwork.Value.internal
}
if (($mailpitOperatorNetworks -join "`n") -cne "backend`nmailpit-operator" -or
    $mailpitOperatorInternal) {
    throw 'The Mailpit operator overlay must use the private backend and one temporary non-internal operator network.'
}
foreach ($service in $resolvedMailpitOperator.services.PSObject.Properties) {
    if ($service.Name -ceq 'mailpit') {
        continue
    }
    if ($null -ne $service.Value.networks.PSObject.Properties['mailpit-operator']) {
        throw "Preview service '$($service.Name)' must not join the Mailpit operator network."
    }
}

$nginxConfiguration = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot '..\apps\web\nginx.conf') -Raw
foreach ($privateService in @('admin-api', 'mailpit')) {
    if ($nginxConfiguration.Contains(
            $privateService,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "The public edge must not contain a $privateService upstream or route."
    }
}

Write-Host 'BunkFy preview Compose configuration is valid.'

$previewScript = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'preview.ps1') -Raw
foreach ($requiredToken in @(
        'gma-bootstrap.ps1',
        "(`$Action -eq 'up' -and -not `$NoBuild)",
        '-Force',
        'EnvironmentPath',
        '-NoBuild is supported only with the up action.',
        'BUNKFY_ALLOWED_HOSTS',
        'without wildcards',
        'must include the host from BUNKFY_PUBLIC_URL',
        "@('--no-build')",
        'open-operations',
        'close-operations',
        'BUNKFY_RELEASE_ID',
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
        'schemaVersion = 4',
        'backupId =',
        'stateContract =',
        'protectedLedgerSnapshot =',
        "restorePolicy = 'explicit-current-snapshot-required'",
        '$script:BunkFyPreviewManifestDigestFileName',
        'pg_restore --list',
        '$concurrentOperators',
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
        'Assert-BunkFyBackupManifestIntegrity',
        'Assert-BunkFyGitCommitRecord',
        'Assert-BunkFyGitWorktreeClean',
        'Get-BunkFyDockerImageId',
        'ProtectedLedgerSnapshotPath',
        'ProtectedLedgerSnapshotSha256',
        'AllowBackupPointProtectedLedger',
        'explicitly allow the backup-point snapshot only for a disposable rehearsal',
        'Assert-BunkFyVolumeArchiveReadable',
        '--exit-on-error',
        "@('create', '--no-build')",
        '$RemoveFailedTarget',
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

$previewRecoveryRehearsal = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\rehearse-preview-recovery.ps1') -Raw
foreach ($requiredToken in @(
        "SupportsShouldProcess = `$true",
        'ExpectedManifestSha256',
        "schemaVersion -ne 4",
        '-AllowBackupPointProtectedLedger',
        '-RemoveFailedTarget',
        'BUNKFY_RELEASE_ID',
        '-ExpectedReleaseId',
        'verify-deployed-public-edge.ps1',
        'verify-deployed-admin-boundary.ps1',
        'Get-BunkFyStateTreeFingerprint',
        "evidenceKind = 'bunkfy-preview-recovery-rehearsal'",
        "'protected-authenticator-decryption-not-exercised'",
        "'hosted-rpo-and-rto-not-established'")) {
    if (-not $previewRecoveryRehearsal.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Preview recovery rehearsal guard is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        'AccessToken',
        'Password',
        'Totp',
        'docker pull',
        'docker build',
        "'--publish'")) {
    if ($previewRecoveryRehearsal.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Preview recovery rehearsal contains forbidden token '$forbiddenToken'."
    }
}

Write-Host 'BunkFy isolated preview recovery rehearsal policy is valid.'

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
        'Assert-BunkFyWebReleaseIdentity',
        'Assert-BunkFySmokeResponse',
        'Assert-BunkFyPublicApiReleaseIdentity',
        'New-BunkFyPublicEdgeHttpClient',
        'Invoke-BunkFyUntrustedHttpsHostRequest',
        'Get-BunkFyObservedComposedReleaseId',
        'ExpectedReleaseId',
        'releaseId',
        '$handler.AllowAutoRedirect = $false',
        'HttpCompletionOption]::ResponseHeadersRead',
        'CancellationTokenSource',
        'Select-Object -First 1',
        "'--disable'",
        "'--proto', '=https'",
        "'--proxy', ''",
        "'--max-filesize'",
        'Content-Security-Policy',
        'Strict-Transport-Security')) {
    if (-not $deployedEdgeCommon.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed public edge common policy is missing '$requiredToken'."
    }
}

$deployedEdgeProbe = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\verify-deployed-public-edge.ps1') -Raw
foreach ($requiredToken in @(
        '/healthz',
        '/api/smoke',
        '/api/admin/audit/',
        'ExpectedReleaseId',
        'Invoke-BunkFyUntrustedHttpsHostRequest',
        '-HostHeader $UntrustedHost',
        'schemaVersion = 3',
        "evidenceKind = 'bunkfy-deployed-public-edge-probe'",
        'releaseId = $observedReleaseId',
        "'registry-and-image-provenance-require-promotion-record'",
        "'private-infrastructure-not-observed'",
        "'authenticated-workflows-not-executed'")) {
    if (-not $deployedEdgeProbe.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed public edge probe policy is missing '$requiredToken'."
    }
}
$deployedEdgeTransportSources = $deployedEdgeCommon + "`n" + $deployedEdgeProbe
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        '--insecure',
        'Authorization',
        'sourceCommit',
        'imageDigest',
        '$handler.AllowAutoRedirect = $true')) {
    if ($deployedEdgeTransportSources.Contains(
            $forbiddenToken,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployed public edge probe contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-deployed-public-edge.ps1')
Write-Host 'BunkFy deployed public edge probe policy is valid.'

$deployedRollbackRehearsal = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\rehearse-deployed-release-rollback.ps1') -Raw
foreach ($requiredToken in @(
        'Get-BunkFyVerifiedImagePromotion',
        'Get-BunkFyObservedComposedReleaseId',
        'verify-deployed-public-edge.ps1',
        'rollbackEvidenceReference',
        'checksums.sha256',
        "evidenceKind = 'bunkfy-deployed-release-rollback-rehearsal'",
        "'deployment-control-plane-and-commands-not-observed'",
        "'worker-and-admin-release-identities-not-observed'",
        "'public-smoke-does-not-prove-all-schema-and-domain-compatibility'",
        "'registry-availability-and-immutability-not-reverified'",
        "'hosted-approval-alerting-and-traffic-drain-not-observed'")) {
    if (-not $deployedRollbackRehearsal.Contains(
            $requiredToken,
            [StringComparison]::Ordinal)) {
        throw "Deployed release rollback rehearsal policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        'Invoke-Expression',
        'Start-Process',
        'docker pull',
        'docker build',
        'kubectl',
        'Authorization',
        'AccessToken',
        'Password',
        'Credential')) {
    if ($deployedRollbackRehearsal.Contains(
            $forbiddenToken,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployed release rollback rehearsal contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-deployed-release-rollback.ps1')
Write-Host 'BunkFy deployed release rollback rehearsal policy is valid.'

$adminBoundaryProbe = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\verify-deployed-admin-boundary.ps1') -Raw
foreach ($requiredToken in @(
        '$script:AdminBoundaryMaximumBodyBytes = 64KB',
        '$handler.AllowAutoRedirect = $false',
        'ExpectedReleaseId',
        'release-identity-continuous',
        'releaseId',
        'ExpectedAdminReachability',
        'EvidenceSetId',
        'HttpCompletionOption]::ResponseHeadersRead',
        '/healthz',
        '/health',
        '/api/admin/audit/',
        'Http.PrivateNetworkRequired',
        'Broken TLS is not proof',
        "evidenceKind = 'bunkfy-deployed-admin-boundary-probe'",
        "'single-vantage-point-observation'",
        "'authenticated-admin-operations-not-executed'")) {
    if (-not $adminBoundaryProbe.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed Admin API boundary probe policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        '$handler.AllowAutoRedirect = $true',
        'AuthenticationHeaderValue',
        'AccessToken',
        'X-Tenant-Id',
        'Invoke-RestMethod',
        '-Method POST',
        '-Method PUT',
        '-Method DELETE')) {
    if ($adminBoundaryProbe.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployed Admin API boundary probe contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-deployed-admin-boundary.ps1')
Write-Host 'BunkFy deployed Admin API boundary probe policy is valid.'

$authenticatedSmokeCommon = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\deployed-authenticated-smoke.common.ps1') -Raw
foreach ($requiredToken in @(
        '$script:BunkFyAuthenticatedSmokeMaximumBodyBytes = 256KB',
        'Resolve-BunkFySmokeAccessToken',
        'AuthenticationHeaderValue',
        'X-Tenant-Id',
        'HttpCompletionOption]::ResponseHeadersRead',
        'CancellationTokenSource',
        'Invoke-BunkFyAuthenticatedJsonRequestWithConvergence',
        'Get-BunkFyAuthenticatedProblemCode',
        '$response.StatusCode -ne 409')) {
    if (-not $authenticatedSmokeCommon.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed authenticated smoke common policy is missing '$requiredToken'."
    }
}

$workspaceInvitationProbe = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\verify-deployed-workspace-invitation.ps1') -Raw
foreach ($requiredToken in @(
        "SupportsShouldProcess = `$true",
        '$handler.AllowAutoRedirect = $false',
        'ExpectedReleaseId',
        'release-identity-continuous',
        'releaseId',
        'BUNKFY_SMOKE_OWNER_TOKEN',
        'BUNKFY_SMOKE_APPLICANT_TOKEN',
        '/api/workspace-staff-enrollment/sources/invitations',
        'Workspaces.StaffAccessProfileUnavailable',
        'Workspaces.StaffAccessPropertyUnavailable',
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
        'ExpectedReleaseId',
        'release-identity-continuous',
        'releaseId',
        'BUNKFY_SMOKE_OWNER_TOKEN',
        'BUNKFY_SMOKE_APPLICANT_TOKEN',
        '/api/workspace-staff-enrollment/sources/enrollment-links',
        'Workspaces.StaffAccessProfileUnavailable',
        'Workspaces.StaffAccessPropertyUnavailable',
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

$previewMailCaptureCommon = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\preview-mail-capture.common.ps1') -Raw
foreach ($requiredToken in @(
        'Get-BunkFyMailpitMessagesForRecipient',
        'Get-BunkFyMailpitVerificationCode',
        'Use this one-time verification code:',
        'FromBase64String',
        '[Array]::Clear')) {
    if (-not $previewMailCaptureCommon.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Preview mail-capture parser policy is missing '$requiredToken'."
    }
}

$previewOnboardingRehearsal = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\rehearse-preview-onboarding.ps1') -Raw
foreach ($requiredToken in @(
        "SupportsShouldProcess = `$true",
        '$handler.AllowAutoRedirect = $false',
        '$mailpitHandler.AllowAutoRedirect = $false',
        'ExpectedReleaseId',
        '$PollIntervalMilliseconds = 2000',
        'release-identity-continuous',
        '/api/product-capabilities',
        '/api/auth/browser/register',
        'RegistrationOutcome',
        '-State ([ref]$owner)',
        '-State ([ref]$allowedPropertyId)',
        '-State ([ref]$deniedPropertyId)',
        '/api/auth/email-verification',
        '/api/auth/email-verification/confirm',
        '/api/v1/messages?limit=100',
        '/api/v1/message/',
        'verify-deployed-workspace-invitation.ps1',
        'verify-deployed-workspace-enrollment.ps1',
        'preview-property-processing-fixture.common.ps1',
        'preview-sellable-room-fixture.common.ps1',
        'IncludeOperationsNotifications',
        'verify-deployed-operations-notifications.ps1',
        'operations-notifications-child-proof-passed',
        "`$cleanup['operationsNotificationsFixture'] = 'room-retired'",
        'IncludeReservationsInventory',
        'verify-deployed-reservations-inventory.ps1',
        'reservations-inventory-child-proof-passed',
        'WorkspaceBinding Required',
        'WorkspaceBinding Forbidden',
        "`$evidence.PSObject.Properties['workspaceId']",
        'preview-engineering-country-policy-activated',
        'reservationsInventoryEvidencePath',
        "`$cleanup['reservationsInventoryFixture'] = 'room-retired'",
        '/api/staff/members',
        '/depart',
        '/retire',
        '/suspend',
        '/archive',
        '/api/auth/sign-out-all',
        'purged-and-loopback-closed',
        "'label=com.docker.compose.network=mailpit-operator'",
        "evidenceKind = 'bunkfy-preview-onboarding-rehearsal'",
        "'proof-failed'",
        'Get-RehearsalFailureCode',
        'cleanupFailures = @($cleanupFailures)',
        'fingerprintSha256',
        "'mailpit-capture-is-not-real-provider-delivery-or-inbox-placement-proof'",
        "'synthetic-global-identities-retained-signed-out-no-public-delete-contract'")) {
    if (-not $previewOnboardingRehearsal.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Preview onboarding rehearsal policy is missing '$requiredToken'."
    }
}
$failureEvidenceIndex = $previewOnboardingRehearsal.IndexOf(
    "'proof-failed'",
    [StringComparison]::Ordinal)
$proofRethrowIndex = $previewOnboardingRehearsal.LastIndexOf(
    'if ($null -ne $proofError)',
    [StringComparison]::Ordinal)
if ($failureEvidenceIndex -lt 0 -or
    $proofRethrowIndex -lt 0 -or
    $failureEvidenceIndex -gt $proofRethrowIndex) {
    throw 'Preview onboarding rehearsal must assemble minimized failure evidence before rethrowing a proof failure.'
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        '$handler.AllowAutoRedirect = $true',
        '$mailpitHandler.AllowAutoRedirect = $true',
        '/members/remove',
        '/api/admin/',
        'Invoke-Sqlcmd',
        'NpgsqlConnection',
        'psql ')) {
    if ($previewOnboardingRehearsal.Contains(
            $forbiddenToken,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Preview onboarding rehearsal contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-preview-mail-capture.ps1')
Write-Host 'BunkFy Preview onboarding rehearsal policy is valid.'

$previewPropertyProcessingFixture = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\preview-property-processing-fixture.common.ps1') -Raw
foreach ($requiredToken in @(
        'Get-BunkFyPreviewEngineeringCountryPolicy',
        'Enable-BunkFyPreviewEngineeringPropertyProcessing',
        '/country-policies',
        '/processing/activate',
        '/processing',
        "'engineering'",
        "'example'",
        "'Properties.CountryPolicy.Allowed'")) {
    if (-not $previewPropertyProcessingFixture.Contains(
            $requiredToken,
            [StringComparison]::Ordinal)) {
        throw "Preview property-processing fixture policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        '/api/admin/',
        'Invoke-Sqlcmd',
        'NpgsqlConnection',
        'psql ',
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback')) {
    if ($previewPropertyProcessingFixture.Contains(
            $forbiddenToken,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Preview property-processing fixture contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-preview-property-processing-fixture.ps1')
Write-Host 'BunkFy Preview property-processing fixture policy is valid.'

$previewSellableRoomFixture = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\preview-sellable-room-fixture.common.ps1') -Raw
foreach ($requiredToken in @(
        'New-BunkFyPreviewSellableRoomFixture',
        'Remove-BunkFyPreviewSellableRoomFixture',
        '/api/properties/',
        '/api/inventory/properties/',
        '/sales-mode',
        '/retirement',
        'room-retirements',
        "-Name 'roomLevel'",
        "-Name 'completed'")) {
    if (-not $previewSellableRoomFixture.Contains(
            $requiredToken,
            [StringComparison]::Ordinal)) {
        throw "Preview sellable-room fixture policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        '/api/admin/',
        'Invoke-Sqlcmd',
        'NpgsqlConnection',
        'psql ',
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback')) {
    if ($previewSellableRoomFixture.Contains(
            $forbiddenToken,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Preview sellable-room fixture contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-preview-sellable-room-fixture.ps1')
Write-Host 'BunkFy Preview sellable-room fixture policy is valid.'

$operationsNotificationsProbe = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\verify-deployed-operations-notifications.ps1') -Raw
foreach ($requiredToken in @(
        "SupportsShouldProcess = `$true",
        '$handler.AllowAutoRedirect = $false',
        'ExpectedReleaseId',
        'release-identity-continuous',
        'releaseId',
        'BUNKFY_SMOKE_NOTIFICATION_ACTOR_TOKEN',
        'BUNKFY_SMOKE_NOTIFICATION_OBSERVER_TOKEN',
        '$createOperationId',
        '$releaseOperationId',
        'operationId = $createOperationId',
        'operationId = $releaseOperationId',
        '/api/notifications/history/stream?afterSequence=',
        "'delivery:web'",
        'manual-inventory-block-created',
        'manual-inventory-block-released',
        'initiating-actor-excluded',
        'Release-SmokeBlockBestEffort',
        "evidenceKind = 'bunkfy-deployed-operations-notifications-probe'",
        "'browser-attention-rendering-not-exercised'",
        "'released-block-and-notification-history-retained'")) {
    if (-not $operationsNotificationsProbe.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed Operations Notifications probe policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        '$handler.AllowAutoRedirect = $true',
        '/api/notifications/read-all')) {
    if ($operationsNotificationsProbe.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployed Operations Notifications probe contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-deployed-operations-notifications.ps1')
Write-Host 'BunkFy deployed Operations Notifications probe policy is valid.'

$reservationsInventoryProbe = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\verify-deployed-reservations-inventory.ps1') -Raw
foreach ($requiredToken in @(
        "SupportsShouldProcess = `$true",
        '$handler.AllowAutoRedirect = $false',
        'ExpectedReleaseId',
        'release-identity-continuous',
        'BUNKFY_SMOKE_RESERVATION_OPERATOR_TOKEN',
        '/api/inventory/properties/',
        '/api/reservations/properties/',
        'Reservations.CountryPolicyDenied.MissingBinding',
        'reservation-create-replay-stable',
        'reservation-check-in-replay-stable',
        'reservation-checkout-converged',
        'reservation-checkout-replay-current',
        'inventory-released-after-checkout',
        'Complete-SmokeReservationBestEffort',
        "evidenceKind = 'bunkfy-deployed-reservations-inventory-probe'",
        "'durable-guest-record-not-created'",
        "'synthetic-checked-out-reservation-retained'")) {
    if (-not $reservationsInventoryProbe.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed Reservations and Inventory probe policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        '$handler.AllowAutoRedirect = $true',
        '/api/admin/',
        '/api/guests')) {
    if ($reservationsInventoryProbe.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployed Reservations and Inventory probe contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-deployed-reservations-inventory.ps1')
Write-Host 'BunkFy deployed Reservations and Inventory probe policy is valid.'

$adapterHostProbe = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\verify-deployed-adapter-host.ps1') -Raw
foreach ($requiredToken in @(
        '$script:AdapterHostMaximumBodyBytes = 32KB',
        '$handler.AllowAutoRedirect = $false',
        'ExpectedReleaseId',
        'release-identity-continuous',
        'releaseId',
        'BUNKFY_SMOKE_INGESTION_OPERATOR_TOKEN',
        "StatusEndpointExposure -ceq 'LoopbackOnly'",
        '/health/live',
        '/health/ready',
        '/api/ingestion/properties/',
        'remoteLeaseId',
        'remoteWorkerId',
        'rawPayloadFileId',
        'server-checkpoint-advanced',
        "evidenceKind = 'bunkfy-deployed-adapter-host-probe'",
        "'synthetic-provider-record-injection-not-performed-by-probe'",
        "'credential-rotation-and-process-restart-not-exercised'")) {
    if (-not $adapterHostProbe.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed AdapterHost probe policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        '$handler.AllowAutoRedirect = $true',
        'ReadAsByteArrayAsync',
        '/raw-payload')) {
    if ($adapterHostProbe.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployed AdapterHost probe contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-deployed-adapter-host.ps1')
Write-Host 'BunkFy deployed AdapterHost probe policy is valid.'

$retentionProbe = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\verify-deployed-retention.ps1') -Raw
foreach ($requiredToken in @(
        '$handler.AllowAutoRedirect = $false',
        'ExpectedReleaseId',
        'release-identity-continuous',
        'releaseId',
        'BUNKFY_SMOKE_RETENTION_READER_TOKEN',
        '/api/retention/schedules?page=',
        "DataClassKey = 'raw-source-evidence'",
        "DataClassKey = 'sensitive-reservation-history'",
        'cross-workspace-retention-denied',
        'automatic-retention-occurrence-observed',
        "evidenceKind = 'bunkfy-deployed-retention-probe'",
        "'owner-data-not-seeded-or-read'",
        "'generic-task-lease-and-restart-not-observed'")) {
    if (-not $retentionProbe.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Deployed Retention probe policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        '$handler.AllowAutoRedirect = $true',
        '-Method POST',
        '-Method PUT',
        '/api/admin/')) {
    if ($retentionProbe.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployed Retention probe contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-deployed-retention.ps1')
Write-Host 'BunkFy deployed Retention probe policy is valid.'

$productionAdmissionCommon = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'production-admission.common.ps1') -Raw
$productionAdmissionAssembler = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\assemble-production-admission.ps1') -Raw
$productionAdmissionVerifier = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'verify-production-admission.ps1') -Raw
foreach ($requiredToken in @(
        'Get-BunkFyVerifiedProductionAdmissionProbe',
        'Get-BunkFyVerifiedProductionMigrationRehearsal',
        'Get-BunkFyVerifiedDeployedRollbackRehearsal',
        'Get-BunkFyVerifiedProductionAdmission',
        'ConvertFrom-Json -DateKind String',
        'Get-BunkFyClosedChecksumSet',
        "'bunkfy-production-admission-bundle'",
        "'evidence-complete-awaiting-private-approval'",
        "'private-evidence-content-and-authenticity-not-verified'")) {
    if (-not $productionAdmissionCommon.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Production admission common policy is missing '$requiredToken'."
    }
}
foreach ($requiredToken in @(
        'CandidatePromotionDirectory',
        'AdmissionEvidenceReference',
        'RollbackPromotionDirectory',
        'RollbackRehearsalDirectory',
        'MigrationRehearsalPath',
        'AdminAllowedEvidencePath',
        'AdminDeniedEvidencePath',
        'BrowserRehearsalReference',
        'HostedRecoveryReference',
        'DeploymentControlReference',
        'RuntimeOperationsReference',
        'Get-BunkFyVerifiedProductionAdmission',
        '[IO.Directory]::Move')) {
    if (-not $productionAdmissionAssembler.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Production admission assembler policy is missing '$requiredToken'."
    }
}
foreach ($requiredToken in @(
        'AdmissionDirectory',
        'ExpectedPublicOrigin',
        'ExpectedReleaseId',
        'ExpectedSourceCommit',
        'ExpectedAdmissionEvidenceReference',
        'Get-BunkFyVerifiedProductionAdmission')) {
    if (-not $productionAdmissionVerifier.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Production admission verifier policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        'Invoke-RestMethod',
        'AuthenticationHeaderValue',
        'SecureString',
        'Invoke-Expression',
        'Start-Process',
        'docker ',
        'kubectl')) {
    if ($productionAdmissionCommon.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase) -or
        $productionAdmissionAssembler.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase) -or
        $productionAdmissionVerifier.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Production admission tooling contains forbidden token '$forbiddenToken'."
    }
}

& (Join-Path $PSScriptRoot 'test-production-admission.ps1')
Write-Host 'BunkFy production admission evidence policy is valid.'
