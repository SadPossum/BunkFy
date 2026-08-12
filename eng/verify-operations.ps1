Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scripts = @(
    (Join-Path $PSScriptRoot 'operations\admin-api.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\provision-staff-access.ps1'),
    (Join-Path $PSScriptRoot 'operations\offboard-staff-access.ps1'),
    (Join-Path $PSScriptRoot 'operations\verify-preview-isolation.ps1'),
    (Join-Path $PSScriptRoot 'operations\local-sensitive-state.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\preview-state.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\preview-workspace-access-estate.common.ps1'),
    (Join-Path $PSScriptRoot 'operations\backup-preview.ps1'),
    (Join-Path $PSScriptRoot 'operations\restore-preview.ps1'),
    (Join-Path $PSScriptRoot 'operations\rehearse-preview-recovery.ps1'),
    (Join-Path $PSScriptRoot 'operations\protect-preview-local-state.ps1'),
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
    (Join-Path $PSScriptRoot 'operations\rehearse-preview-browser-onboarding.ps1'),
    (Join-Path $PSScriptRoot 'operations\rehearse-preview-workspace-access-estate.ps1'),
    (Join-Path $PSScriptRoot 'operations\rehearse-preview-adapter-host.ps1'),
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
    (Join-Path $PSScriptRoot 'test-preview-browser-onboarding-rehearsal.ps1'),
    (Join-Path $PSScriptRoot 'test-preview-workspace-access-estate.ps1'),
    (Join-Path $PSScriptRoot 'test-preview-adapter-host-rehearsal.ps1'),
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

$deployedEvidenceCommon = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\deployed-public-edge.common.ps1') -Raw
foreach ($requiredToken in @(
        'function Write-BunkFyPrivateJsonEvidence',
        'Write-BunkFyLocalSensitiveTextFile',
        '-Overwrite:$Overwrite')) {
    if (-not $deployedEvidenceCommon.Contains(
            $requiredToken,
            [StringComparison]::Ordinal)) {
        throw "Private deployed-evidence writer is missing '$requiredToken'."
    }
}
$deployedEvidenceWriters = @(
    'rehearse-preview-onboarding.ps1',
    'rehearse-preview-workspace-access-estate.ps1',
    'verify-deployed-adapter-host.ps1',
    'verify-deployed-admin-boundary.ps1',
    'verify-deployed-operations-notifications.ps1',
    'verify-deployed-public-edge.ps1',
    'verify-deployed-reservations-inventory.ps1',
    'verify-deployed-retention.ps1',
    'verify-deployed-workspace-enrollment.ps1',
    'verify-deployed-workspace-invitation.ps1')
foreach ($scriptName in $deployedEvidenceWriters) {
    $source = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot "operations\$scriptName") -Raw
    if (-not $source.Contains(
            'Write-BunkFyPrivateJsonEvidence',
            [StringComparison]::Ordinal)) {
        throw "Deployed evidence script '$scriptName' bypasses the private writer."
    }
}

. (Join-Path $PSScriptRoot 'operations\admin-api.common.ps1')
. (Join-Path $PSScriptRoot 'operations\local-sensitive-state.common.ps1')
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

$permissionFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-local-sensitive-state-' + [Guid]::NewGuid().ToString('N'))
try {
    New-BunkFyLocalSensitiveDirectory `
        -Path $permissionFixtureRoot `
        -Description 'Permission fixture'
    $permissionFixtureFile = Join-Path $permissionFixtureRoot 'secret.txt'
    Write-BunkFyLocalSensitiveTextFile `
        -Path $permissionFixtureFile `
        -Content "first`n" `
        -Description 'Permission fixture file'
    Write-BunkFyLocalSensitiveTextFile `
        -Path $permissionFixtureFile `
        -Content "second`n" `
        -Overwrite `
        -Description 'Permission fixture file'
    if ([IO.File]::ReadAllText($permissionFixtureFile) -cne "second`n") {
        throw 'Private atomic file replacement did not preserve exact content.'
    }

    if (-not (Test-BunkFyWindowsPlatform)) {
        [IO.File]::SetUnixFileMode(
            $permissionFixtureFile,
            [IO.UnixFileMode]416)
        $unsafeFileRejected = $false
        try {
            Assert-BunkFyLocalSensitivePath `
                -Path $permissionFixtureFile `
                -PathType Leaf `
                -Description 'Permission fixture file'
        }
        catch {
            $unsafeFileRejected = $_.Exception.Message.Contains(
                'unsafe Unix mode',
                [StringComparison]::Ordinal)
        }
        if (-not $unsafeFileRejected) {
            throw 'Local sensitive-state policy accepted a group-readable file.'
        }

        [IO.File]::SetUnixFileMode(
            $permissionFixtureRoot,
            [IO.UnixFileMode]488)
        $unsafeDirectoryRejected = $false
        try {
            Assert-BunkFyLocalSensitivePath `
                -Path $permissionFixtureRoot `
                -PathType Container `
                -Description 'Permission fixture'
        }
        catch {
            $unsafeDirectoryRejected = $_.Exception.Message.Contains(
                'unsafe Unix mode',
                [StringComparison]::Ordinal)
        }
        if (-not $unsafeDirectoryRejected) {
            throw 'Local sensitive-state policy accepted a group-accessible directory.'
        }
    }

    Protect-BunkFyLocalSensitiveTree `
        -Path $permissionFixtureRoot `
        -Description 'Permission fixture'
    Assert-BunkFyLocalSensitiveTree `
        -Path $permissionFixtureRoot `
        -Description 'Permission fixture'
    if (-not (Test-BunkFyWindowsPlatform)) {
        $directoryMode = [int][IO.File]::GetUnixFileMode($permissionFixtureRoot)
        $fileMode = [int][IO.File]::GetUnixFileMode($permissionFixtureFile)
        if ($directoryMode -ne 448 -or $fileMode -ne 384) {
            throw 'Local sensitive-state protection did not apply Unix 0700/0600.'
        }
    }
}
finally {
    Remove-Item `
        -LiteralPath $permissionFixtureRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

Write-Host 'BunkFy local sensitive-state permissions are valid.'

$legacyStateContract = Get-BunkFyPreviewStateContract -Manifest (
    [pscustomobject]@{ schemaVersion = 2 })
$schemaThreeStateContract = Get-BunkFyPreviewStateContract -Manifest (
    [pscustomobject]@{
        schemaVersion = 3
        stateContract = [pscustomobject]@{
            name = $script:BunkFyPreviewStateContractName
            version = $script:BunkFyPreviewLegacyStateContractVersion
        }
    })
$schemaFourStateContract = Get-BunkFyPreviewStateContract -Manifest (
    [pscustomobject]@{
        schemaVersion = 4
        stateContract = [pscustomobject]@{
            name = $script:BunkFyPreviewStateContractName
            version = $script:BunkFyPreviewLegacyStateContractVersion
        }
    })
$currentStateContract = Get-BunkFyPreviewStateContract -Manifest (
    [pscustomobject]@{
        schemaVersion = 5
        stateContract = [pscustomobject]@{
            name = $script:BunkFyPreviewStateContractName
            version = $script:BunkFyPreviewStateContractVersion
        }
    })
foreach ($contract in @(
        $legacyStateContract,
        $schemaThreeStateContract,
        $schemaFourStateContract,
        $currentStateContract)) {
    Assert-BunkFyPreviewStateContractCompatible -Contract $contract
}
$invalidSchemaContractRejected = $false
try {
    [void](Get-BunkFyPreviewStateContract -Manifest (
            [pscustomobject]@{
                schemaVersion = 4
                stateContract = [pscustomobject]@{
                    name = $script:BunkFyPreviewStateContractName
                    version = $script:BunkFyPreviewStateContractVersion
                }
            }))
}
catch {
    $invalidSchemaContractRejected = $true
}
if (-not $invalidSchemaContractRejected) {
    throw 'Preview restore accepted a state contract from the wrong manifest schema.'
}
$futureStateContractRejected = $false
try {
    $futureStateContract = Get-BunkFyPreviewStateContract -Manifest (
        [pscustomobject]@{
            schemaVersion = 5
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
$composeSourceLines = @(Get-Content -LiteralPath $composeFile)
$backendImageExpression = '${BUNKFY_BACKEND_IMAGE:-bunkfy/backend:preview}'
$webImageExpression = '${BUNKFY_WEB_IMAGE:-bunkfy/web:preview}'
if (@($composeSourceLines | Where-Object {
            $_.Trim() -ceq "image: $backendImageExpression"
        }).Count -ne 6 -or
    @($composeSourceLines | Where-Object {
            $_.Trim() -ceq "image: $webImageExpression"
        }).Count -ne 1) {
    throw 'Preview product services must use the explicit backend and web image selectors.'
}
[Environment]::SetEnvironmentVariable(
    'BUNKFY_BACKEND_IMAGE', $null, [EnvironmentVariableTarget]::Process)
[Environment]::SetEnvironmentVariable(
    'BUNKFY_WEB_IMAGE', $null, [EnvironmentVariableTarget]::Process)
$policyExtensionStarts = @(for ($index = 0; $index -lt $composeSourceLines.Count; $index++) {
        if ($composeSourceLines[$index] -ceq
            'x-preview-country-policy-volume: &preview-country-policy-volume') {
            $index
        }
    })
if ($policyExtensionStarts.Count -ne 1) {
    throw 'Preview Compose must declare exactly one engineering policy volume extension.'
}
$policyExtensionStart = $policyExtensionStarts[0]
$policyExtensionEnd = $composeSourceLines.Count
for ($index = $policyExtensionStart + 1; $index -lt $composeSourceLines.Count; $index++) {
    if ($composeSourceLines[$index] -cmatch '^\S') {
        $policyExtensionEnd = $index
        break
    }
}
$policyExtensionLines = @($composeSourceLines[$policyExtensionStart..($policyExtensionEnd - 1)])
if (@($policyExtensionLines | Where-Object { $_ -cmatch '^  bind:\s*$' }).Count -ne 1 -or
    @($policyExtensionLines | Where-Object { $_ -cmatch '^    create_host_path:\s*false\s*$' }).Count -ne 1) {
    throw 'Preview engineering policy volume must explicitly disable host-path creation.'
}
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
$sourceComposeJson = & docker compose `
    --env-file $environmentFile `
    -f $composeFile `
    config `
    --format json `
    --no-normalize `
    --no-path-resolution
if ($LASTEXITCODE -ne 0) {
    throw 'Preview Compose source configuration is invalid.'
}
$sourceCompose = $sourceComposeJson | ConvertFrom-Json
$expectedInfrastructureImages = [ordered]@{
    postgres = 'postgres:17.5-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa'
    redis = 'redis:8.0-alpine@sha256:5f61955be8ab2ccee9372b84ae4d4da2e2b156f87281e3f218544055e7ee04d4'
    nats = 'nats:2.11-alpine@sha256:e4bf19f15fd3218814a4e3c9e0064e1334bd8aa20d5984b9f1a0afd084f8cc00'
    minio = 'minio/minio:RELEASE.2025-04-22T22-12-26Z@sha256:a1ea29fa28355559ef137d71fc570e508a214ec84ff8083e39bc5428980b015e'
    mailpit = 'axllent/mailpit:v1.30.7@sha256:d5ecbb067db3705fa953d79e1b7f81ef84038df67aba6c52825d8c02a1ea748a'
}
foreach ($entry in $expectedInfrastructureImages.GetEnumerator()) {
    $actual = [string]$resolvedCompose.services.PSObject.Properties[$entry.Key].Value.image
    if ($actual -cne $entry.Value) {
        throw "Preview infrastructure image '$($entry.Key)' is not pinned to the reviewed digest."
    }
}
$expectedArchiveUtilityImage = 'alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d'
if ($script:BunkFyPreviewArchiveUtilityImage -cne $expectedArchiveUtilityImage) {
    throw 'Preview backup and recovery utility image is not pinned to the reviewed digest.'
}
$expectedVolumeNames = [ordered]@{
    'postgres-data' = 'bunkfy-preview-postgres-data'
    'redis-data' = 'bunkfy-preview-redis-data'
    'nats-data' = 'bunkfy-preview-nats-data'
    'minio-data' = 'bunkfy-preview-minio-data'
    'data-protection' = 'bunkfy-preview-data-protection'
    'adapter-file-drop' = 'bunkfy-preview-adapter-file-drop'
    'data-rights-ledger-delta' = 'bunkfy-preview-data-rights-ledger-delta'
    'tenant-termination-replay' = 'bunkfy-preview-tenant-termination-replay'
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
if ($apiEnvironment.Ingestion__AdapterIngress__Enabled -cne 'true') {
    throw 'The preview API must enable adapter ingress for connection-scoped runtime rehearsals.'
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
$expectedPreviewPolicySource = '../../apps/backend/eng/country-policies/development'
$expectedPreviewPolicySourceSuffix = '/apps/backend/eng/country-policies/development'
foreach ($serviceName in @('api', 'worker')) {
    $service = $resolvedCompose.services.PSObject.Properties[$serviceName].Value
    $sourceService = $sourceCompose.services.PSObject.Properties[$serviceName].Value
    foreach ($setting in $expectedPreviewPolicySettings.GetEnumerator()) {
        $actual = [string]$service.environment.PSObject.Properties[$setting.Key].Value
        if ($actual -cne [string]$setting.Value) {
            throw "Preview $serviceName country-policy setting '$($setting.Key)' is not digest-pinned."
        }
    }

    $policyMounts = @($service.volumes | Where-Object {
            [string]$_.target -ceq '/etc/bunkfy/country-policies'
        })
    $sourcePolicyMounts = @($sourceService.volumes | Where-Object {
            [string]$_.target -ceq '/etc/bunkfy/country-policies'
        })
    if ($policyMounts.Count -ne 1) {
        throw "Preview $serviceName must resolve exactly one engineering policy mount."
    }
    $policyMount = $policyMounts[0]
    if ([string]$policyMount.type -cne 'bind' -or
        [string]$policyMount.read_only -ine 'true') {
        throw "Preview $serviceName must resolve the engineering policy mount as a read-only bind."
    }
    if ($sourcePolicyMounts.Count -ne 1) {
        throw "Preview $serviceName source configuration must retain exactly one engineering policy mount."
    }
    $sourcePolicyMount = $sourcePolicyMounts[0]
    $sourcePolicyPath = ([string]$sourcePolicyMount.source).Replace('\', '/').TrimEnd('/')
    $sourcePathMatches = $sourcePolicyPath -ceq $expectedPreviewPolicySource -or
        $sourcePolicyPath.EndsWith(
            $expectedPreviewPolicySourceSuffix,
            [StringComparison]::OrdinalIgnoreCase)
    if ([string]$sourcePolicyMount.type -cne 'bind' -or
        [string]$sourcePolicyMount.read_only -ine 'true' -or
        -not $sourcePathMatches) {
        throw "Preview $serviceName source configuration must retain the tracked read-only engineering policy bind."
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
$fixtureBackendImage = 'registry.fixture.invalid/bunkfy/backend:recovery-fixture'
$fixtureWebImage = 'registry.fixture.invalid/bunkfy/web:recovery-fixture'
try {
    [Environment]::SetEnvironmentVariable(
        'BUNKFY_BACKEND_IMAGE', $fixtureBackendImage, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable(
        'BUNKFY_WEB_IMAGE', $fixtureWebImage, [EnvironmentVariableTarget]::Process)
    $selectedComposeJson = & docker compose `
        --env-file $environmentFile `
        -f $composeFile `
        --profile operations `
        --profile tools `
        config `
        --format json
    if ($LASTEXITCODE -ne 0) {
        throw 'Preview Compose rejected explicit product image selection.'
    }
    $selectedCompose = $selectedComposeJson | ConvertFrom-Json
    foreach ($serviceName in @(
            'tenant-termination-replay-init',
            'migrations',
            'api',
            'worker',
            'admin-api',
            'admin-cli')) {
        if ([string]$selectedCompose.services.PSObject.Properties[$serviceName].Value.image -cne
            $fixtureBackendImage) {
            throw "Preview service '$serviceName' ignored the selected backend image."
        }
    }
    if ([string]$selectedCompose.services.web.image -cne $fixtureWebImage) {
        throw 'Preview web ignored the selected web image.'
    }
}
finally {
    [Environment]::SetEnvironmentVariable(
        'BUNKFY_BACKEND_IMAGE', $null, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable(
        'BUNKFY_WEB_IMAGE', $null, [EnvironmentVariableTarget]::Process)
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

function Assert-BunkFyBoundedServiceLogging {
    param(
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][object] $Service
    )

    $options = $Service.logging.options
    $optionNames = @($options.PSObject.Properties.Name | Sort-Object)
    if ([string]$Service.logging.driver -cne 'local' -or
        ($optionNames -join ',') -cne 'max-file,max-size' -or
        [string]$options.PSObject.Properties['max-file'].Value -cne '3' -or
        [string]$options.PSObject.Properties['max-size'].Value -cne '10m') {
        throw "Preview service '$ServiceName' must use the bounded local log policy."
    }
}

function Assert-BunkFyFirstPartyRuntime {
    param(
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][string[]] $ExpectedTmpfs,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $WritableVolumeTargets
    )

    $service = $resolvedOperationsCompose.services.PSObject.Properties[$ServiceName].Value
    if (-not [bool]$service.read_only -or
        -not [bool]$service.init -or
        [int]$service.pids_limit -ne 512 -or
        [string]$service.stop_grace_period -cne '30s' -or
        (@($service.cap_drop) -join ',') -cne 'ALL' -or
        (@($service.security_opt) -join ',') -cne 'no-new-privileges:true') {
        throw "Preview first-party service '$ServiceName' is missing its runtime hardening policy."
    }

    $actualTmpfs = @($service.tmpfs | Sort-Object)
    $expectedTmpfsSorted = @($ExpectedTmpfs | Sort-Object)
    if (@(Compare-Object `
            -ReferenceObject $expectedTmpfsSorted `
            -DifferenceObject $actualTmpfs).Count -gt 0) {
        throw "Preview first-party service '$ServiceName' has an unexpected writable temporary filesystem."
    }

    $allowedWritableTargets = [Collections.Generic.HashSet[string]]::new(
        [string[]]$WritableVolumeTargets,
        [StringComparer]::Ordinal)
    $observedWritableTargets = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $volumeProperty = $service.PSObject.Properties['volumes']
    $mounts = if ($null -eq $volumeProperty) { @() } else { @($volumeProperty.Value) }
    foreach ($mount in $mounts) {
        $readOnlyProperty = $mount.PSObject.Properties['read_only']
        if ($null -ne $readOnlyProperty -and [bool]$readOnlyProperty.Value) {
            continue
        }
        $target = [string]$mount.target
        if (-not $allowedWritableTargets.Contains($target)) {
            throw "Preview first-party service '$ServiceName' has unexpected writable mount '$target'."
        }
        [void]$observedWritableTargets.Add($target)
    }
    if ($observedWritableTargets.Count -ne $allowedWritableTargets.Count) {
        throw "Preview first-party service '$ServiceName' is missing a required writable state mount."
    }

    Assert-BunkFyBoundedServiceLogging -ServiceName $ServiceName -Service $service
}

$backendDockerfile = @(Get-Content -LiteralPath (
        Join-Path $PSScriptRoot '..\apps\backend\Dockerfile'))
$webDockerfile = @(Get-Content -LiteralPath (
        Join-Path $PSScriptRoot '..\apps\web\Dockerfile'))
if (@($backendDockerfile | Where-Object { $_.Trim() -ceq 'USER app' }).Count -ne 1 -or
    @($webDockerfile | Where-Object { $_.Trim() -ceq 'USER nginx' }).Count -ne 1) {
    throw 'Preview first-party images must retain their reviewed non-root runtime users.'
}

$replayInitializerName = 'tenant-termination-replay-init'
$replayInitializer = $resolvedOperationsCompose.services.PSObject.Properties[
    $replayInitializerName].Value
$replayInitializerMounts = @($replayInitializer.volumes)
if ([string]$replayInitializer.image -cne [string]$resolvedOperationsCompose.services.api.image -or
    [string]$replayInitializer.user -cne '0:0' -or
    -not [bool]$replayInitializer.read_only -or
    [int]$replayInitializer.pids_limit -ne 32 -or
    [string]$replayInitializer.stop_grace_period -cne '5s' -or
    (@($replayInitializer.cap_drop) -join ',') -cne 'ALL' -or
    (@($replayInitializer.cap_add) -join ',') -cne 'CHOWN' -or
    (@($replayInitializer.security_opt) -join ',') -cne 'no-new-privileges:true' -or
    [string]$replayInitializer.network_mode -cne 'none' -or
    (@($replayInitializer.entrypoint) -join ',') -cne 'chown' -or
    (@($replayInitializer.command) -join ',') -cne
        'app:app,/var/lib/bunkfy/tenant-termination-replay' -or
    $replayInitializerMounts.Count -ne 1 -or
    [string]$replayInitializerMounts[0].source -cne 'tenant-termination-replay' -or
    [string]$replayInitializerMounts[0].target -cne
        '/var/lib/bunkfy/tenant-termination-replay') {
    throw 'Preview tenant-termination replay initialization is not least-privilege bounded.'
}
$replayInitializerEnvironment = $replayInitializer.PSObject.Properties['environment']
if ($null -ne $replayInitializerEnvironment -and
    @($replayInitializerEnvironment.Value.PSObject.Properties).Count -gt 0) {
    throw 'Preview tenant-termination replay initialization must not receive application secrets.'
}
Assert-BunkFyBoundedServiceLogging `
    -ServiceName $replayInitializerName `
    -Service $replayInitializer
foreach ($serviceName in @('api', 'worker', 'admin-api', 'admin-cli')) {
    $dependency = $resolvedOperationsCompose.services.PSObject.Properties[
        $serviceName].Value.depends_on.PSObject.Properties[$replayInitializerName]
    if ($null -eq $dependency -or
        [string]$dependency.Value.condition -cne 'service_completed_successfully') {
        throw "Preview service '$serviceName' must wait for replay-volume initialization."
    }
}

$backendTmpfs = @('/tmp:size=67108864,mode=1777')
foreach ($serviceName in @('migrations', 'api', 'worker', 'admin-api', 'admin-cli')) {
    $writableTargets = @(switch ($serviceName) {
        'api' {
            @(
                '/var/lib/bunkfy/data-protection',
                '/var/lib/bunkfy/data-rights-ledger-delta',
                '/var/lib/bunkfy/tenant-termination-replay')
        }
        'worker' {
            @(
                '/var/lib/bunkfy/file-drop',
                '/var/lib/bunkfy/data-rights-ledger-delta',
                '/var/lib/bunkfy/tenant-termination-replay')
        }
        { $_ -in @('admin-api', 'admin-cli') } {
            @(
                '/var/lib/bunkfy/data-rights-ledger-delta',
                '/var/lib/bunkfy/tenant-termination-replay')
        }
        default { @() }
    })
    Assert-BunkFyFirstPartyRuntime `
        -ServiceName $serviceName `
        -ExpectedTmpfs $backendTmpfs `
        -WritableVolumeTargets $writableTargets
}
Assert-BunkFyFirstPartyRuntime `
    -ServiceName 'web' `
    -ExpectedTmpfs @(
        '/tmp:size=67108864,mode=1777',
        '/run:size=16777216,mode=0755,uid=101,gid=101',
        '/var/cache/nginx:size=67108864,mode=0755,uid=101,gid=101',
        '/etc/nginx/conf.d:size=16777216,mode=0755,uid=101,gid=101') `
    -WritableVolumeTargets @()

foreach ($serviceName in @('api', 'worker', 'admin-api', 'admin-cli')) {
    $environment = $resolvedOperationsCompose.services.PSObject.Properties[
        $serviceName].Value.environment
    if ([string]$environment.DataRights__TenantTerminationReplay__Provider -cne
            'LocalFile' -or
        [string]$environment.DataRights__TenantTerminationReplay__LocalFilePath -cne
            '/var/lib/bunkfy/tenant-termination-replay') {
        throw "Preview service '$serviceName' must use the shared tenant-termination replay store."
    }
}

foreach ($service in $resolvedOperationsCompose.services.PSObject.Properties) {
    Assert-BunkFyBoundedServiceLogging `
        -ServiceName $service.Name `
        -Service $service.Value
}

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
    $serviceNetworks = $service.Value.PSObject.Properties['networks']
    if ($null -ne $serviceNetworks -and
        $null -ne $serviceNetworks.Value.PSObject.Properties['mailpit-operator']) {
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
        'local-sensitive-state.common.ps1',
        'Assert-BunkFyLocalSensitivePath',
        "@('rm', '--stop', '--force', 'admin-api')",
        'docker network rm $managementNetwork')) {
    if (-not $previewScript.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Preview build source-composition bootstrap is missing '$requiredToken'."
    }
}

Write-Host 'BunkFy preview build bootstrap is valid.'

$newPreviewEnvironmentScript = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'new-preview-env.ps1') -Raw
foreach ($requiredToken in @(
        'local-sensitive-state.common.ps1',
        'Write-BunkFyLocalSensitiveTextFile',
        '-Overwrite:$Force')) {
    if (-not $newPreviewEnvironmentScript.Contains(
            $requiredToken,
            [StringComparison]::Ordinal)) {
        throw "Preview environment generation guard is missing '$requiredToken'."
    }
}

$previewIsolationScript = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\verify-preview-isolation.ps1') -Raw
foreach ($requiredToken in @(
        'local-sensitive-state.common.ps1',
        'Assert-BunkFyLocalSensitivePath')) {
    if (-not $previewIsolationScript.Contains(
            $requiredToken,
            [StringComparison]::Ordinal)) {
        throw "Preview isolation permission guard is missing '$requiredToken'."
    }
}

Write-Host 'BunkFy Preview environment permission wiring is valid.'

$backupScript = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\backup-preview.ps1') -Raw
foreach ($requiredToken in @(
        'Get-BunkFyPreviewVolumeMap',
        'Assert-BunkFyGitWorktreeClean',
        'Get-BunkFyDockerImageId',
        'schemaVersion = 5',
        'backupId =',
        'stateContract =',
        'protectedLedgerSnapshot =',
        '$script:BunkFyPreviewArchiveUtilityImage',
        "restorePolicy = 'explicit-current-snapshot-required'",
        '$script:BunkFyPreviewManifestDigestFileName',
        'New-BunkFyLocalSensitiveDirectory',
        'Protect-BunkFyLocalSensitivePath',
        'Assert-BunkFyLocalSensitiveTree',
        "'create', '--name', `$containerName",
        '${containerName}:/tmp/bunkfy-volume.tar.gz',
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
        '$script:BunkFyPreviewArchiveUtilityImage',
        'BUNKFY_BACKEND_IMAGE',
        'BUNKFY_WEB_IMAGE',
        'Assert-BunkFyPreviewImageReference',
        'Assert-BunkFyLocalSensitivePath',
        'Assert-BunkFyLocalSensitiveTree',
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

$protectPreviewStateScript = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\protect-preview-local-state.ps1') -Raw
foreach ($requiredToken in @(
        'Get-BunkFyLocalSensitiveTreeEntries',
        'Get-BunkFyLocalUnixIdentity',
        '$script:BunkFyPreviewArchiveUtilityImage',
        "'--network', 'none'",
        'chown -R "$1:$2" /state',
        'find /state -type d -exec chmod 700',
        'find /state -type f -exec chmod 600',
        'Assert-BunkFyLocalSensitiveTree')) {
    if (-not $protectPreviewStateScript.Contains(
            $requiredToken,
            [StringComparison]::Ordinal)) {
        throw "Preview local-state repair guard is missing '$requiredToken'."
    }
}

Write-Host 'BunkFy Preview local-state repair policy is valid.'

$previewRecoveryRehearsal = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\rehearse-preview-recovery.ps1') -Raw
foreach ($requiredToken in @(
        "SupportsShouldProcess = `$true",
        'ExpectedManifestSha256',
        'BackendImage',
        'WebImage',
        'Assert-BunkFyLocalSensitivePath',
        'Assert-BunkFyLocalSensitiveTree',
        "schemaVersion -notin @(4, 5)",
        '-AllowBackupPointProtectedLedger',
        '-RemoveFailedTarget',
        'BUNKFY_RELEASE_ID',
        '-ExpectedReleaseId',
        'verify-deployed-public-edge.ps1',
        'verify-deployed-admin-boundary.ps1',
        'Get-BunkFyStateTreeFingerprint',
        '$script:BunkFyPreviewArchiveUtilityImage',
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
        'postgres:17.5-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa',
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
        'Assert-BunkFyLocalSensitivePath',
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
        'IncludeRetention',
        'verify-deployed-retention.ps1',
        'CompletionNotBeforeUtc',
        'retention-child-proof-passed',
        'retentionEvidencePath',
        'WorkspaceBinding Required',
        'WorkspaceBinding Forbidden',
        "`$evidence.PSObject.Properties['workspaceId']",
        'preview-engineering-country-policy-activated',
        'reservationsInventoryEvidencePath',
        "`$cleanup['reservationsInventoryFixture'] = 'room-retired'",
        'IncludeAdapterHost',
        'AdapterHostBackendImage',
        'rehearse-preview-adapter-host.ps1',
        'adapter-host-upsert-and-cancellation-proofs-passed',
        'adapterHostUpsertEvidencePath',
        'adapterHostCancellationEvidencePath',
        "`$cleanup['adapterHostRuntime'] = 'removed'",
        "`$cleanup['adapterHostFixture'] = 'room-retired'",
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
$propertyProcessingActivationCalls = [regex]::Matches(
    $previewOnboardingRehearsal,
    '(?m)^\s*\[void\]\(Enable-BunkFyPreviewEngineeringPropertyProcessing\s*`?$').Count
if ($propertyProcessingActivationCalls -ne 1) {
    throw 'Preview onboarding must activate shared room-backed property processing exactly once.'
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
& (Join-Path $PSScriptRoot 'test-preview-browser-onboarding-rehearsal.ps1')
& (Join-Path $PSScriptRoot 'test-preview-workspace-access-estate.ps1')
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
        'confirmed = $true',
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

$previewAdapterHostRehearsal = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'operations\rehearse-preview-adapter-host.ps1') -Raw
foreach ($requiredToken in @(
        "SupportsShouldProcess = `$true",
        'BackendImage must be an exact lowercase repository@sha256:<digest> reference.',
        "DOTNET_ENVIRONMENT = 'Production'",
        "AdapterHost__CoordinationMode = 'server-lease'",
        "AdapterHost__ProductionAdmission__Runtime = 'Container'",
        "AdapterHost__ProductionAdmission__StatusEndpointExposure = 'Disabled'",
        "AdapterHost__IngressTokenEnvironmentVariable = ''",
        "AdapterHost__IngressTokenFilePath = '/run/bunkfy-adapter/ingress-token'",
        '/remote-leases/claim',
        '-ExpectedStatus 401',
        'Verify Preview adapter ingress is enabled and independently authenticated',
        '$startInfo.RedirectStandardInput = $true',
        "'--read-only'",
        "'--cap-drop', 'ALL'",
        "'--security-opt', 'no-new-privileges:true'",
        "'--publish', '127.0.0.1::8088'",
        'verify-deployed-adapter-host.ps1',
        'Waiting for the deployed AdapterHost to ingest the synthetic source record...',
        "operation = 'upsert'",
        "operation = 'cancel'",
        '/disable',
        '/revoke',
        'Remove-AdapterVolume',
        "evidenceKind -cne 'bunkfy-deployed-adapter-host-probe'",
        'BUNKFY_SMOKE_INGESTION_OPERATOR_TOKEN')) {
    if (-not $previewAdapterHostRehearsal.Contains($requiredToken, [StringComparison]::Ordinal)) {
        throw "Preview AdapterHost rehearsal policy is missing '$requiredToken'."
    }
}
foreach ($forbiddenToken in @(
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck',
        "'--privileged'",
        "'--network', 'host'",
        "AdapterHost__IngressTokenEnvironmentVariable = 'BUNKFY")) {
    if ($previewAdapterHostRehearsal.Contains($forbiddenToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Preview AdapterHost rehearsal contains forbidden token '$forbiddenToken'."
    }
}
& (Join-Path $PSScriptRoot 'test-preview-adapter-host-rehearsal.ps1')
Write-Host 'BunkFy Preview AdapterHost rehearsal policy is valid.'

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
        'CompletionNotBeforeUtc',
        'Test-ExpectedSchedulesCompletedAfter',
        "'next-occurrence-after-baseline'",
        "'completed-after-lower-bound'",
        '/api/retention/schedules?page=',
        "DataClassKey = 'raw-source-evidence'",
        "DataClassKey = 'sensitive-reservation-history'",
        'cross-workspace-retention-denied',
        'automatic-retention-occurrence-observed',
        "evidenceKind = 'bunkfy-deployed-retention-probe'",
        'schemaVersion = 2',
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
        'Assert-BunkFyRetentionAdmissionEvidence',
        "'completed-after-lower-bound'",
        'Retention schedule evidence predates its completion lower bound.',
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
