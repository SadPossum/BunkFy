Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$commonPath = Join-Path $PSScriptRoot 'operations/preview-workspace-access-estate.common.ps1'
$operatorPath = Join-Path $PSScriptRoot 'operations/rehearse-preview-workspace-access-estate.ps1'
$composePath = Join-Path $root 'deploy/preview/compose.yaml'

foreach ($path in @($commonPath, $operatorPath, $composePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Workspace access estate fixture is missing '$path'."
    }
}

. (Join-Path $PSScriptRoot 'operations/local-sensitive-state.common.ps1')
. $commonPath

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $rejected = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "$Description was not rejected."
    }
}

function New-CatalogFixture {
    param(
        [string] $Status = 'active',
        [int] $Page = 1,
        [int] $PageSize = 2,
        [bool] $HasMore = $false
    )

    return [ordered]@{
        items = @(
            [ordered]@{
                organizationId = '11111111-1111-4111-8111-111111111111'
                scopeId = 'workspace-one'
                name = 'Workspace One'
                slug = 'workspace-one'
                status = $Status
                activeOwnerCount = 1
                version = 3
                createdAtUtc = '2026-08-12T00:00:00+00:00'
                lastChangedAtUtc = '2026-08-12T00:01:00+00:00'
            })
        page = $Page
        pageSize = $PageSize
        hasMore = $HasMore
    } | ConvertTo-Json -Depth 6
}

function New-StatusFixture {
    param(
        [int] $DriftedSeeds = 0,
        [int] $LegacyMembers = 0,
        [int] $MarkerMembers = 2,
        [bool] $RequiresBackfill = $false
    )

    return [ordered]@{
        seedVersion = 4
        expectedSeedProfileCount = 4
        activeSeedProfileCount = 4
        driftedSeedProfileCount = $DriftedSeeds
        archivedSeedProfileCount = 0
        legacyMemberCount = $LegacyMembers
        markerMemberCount = $MarkerMembers
        requiresBackfill = $RequiresBackfill
    } | ConvertTo-Json
}

$page = ConvertFrom-BunkFyOrganizationCatalogPage `
    -Json (New-CatalogFixture) `
    -ExpectedPage 1 `
    -ExpectedPageSize 2
if ($page.Page -ne 1 -or $page.PageSize -ne 2 -or $page.HasMore -or
    $page.Items.Count -ne 1 -or
    $page.Items[0].Fingerprint -cnotmatch '^[0-9a-f]{64}$') {
    throw 'Organizations catalog fixture did not preserve its closed typed shape.'
}
$forwardHash = Get-BunkFyWorkspaceAccessCatalogFingerprint -Items $page.Items
$reverseHash = Get-BunkFyWorkspaceAccessCatalogFingerprint -Items @($page.Items | Sort-Object -Descending Fingerprint)
if ($forwardHash -cne $reverseHash -or $forwardHash -cnotmatch '^[0-9a-f]{64}$') {
    throw 'Organizations catalog fingerprint is not deterministic.'
}

Assert-Rejected `
    -Description 'Unknown organization status' `
    -Action {
        ConvertFrom-BunkFyOrganizationCatalogPage `
            -Json (New-CatalogFixture -Status 'unknown') `
            -ExpectedPage 1 `
            -ExpectedPageSize 2
    }
Assert-Rejected `
    -Description 'Inconsistent catalog hasMore' `
    -Action {
        ConvertFrom-BunkFyOrganizationCatalogPage `
            -Json (New-CatalogFixture -HasMore $true) `
            -ExpectedPage 1 `
            -ExpectedPageSize 2
    }
Assert-Rejected `
    -Description 'Legacy row-array catalog JSON' `
    -Action {
        ConvertFrom-BunkFyOrganizationCatalogPage `
            -Json '[]' `
            -ExpectedPage 1 `
            -ExpectedPageSize 2
    }

$converged = ConvertFrom-BunkFyWorkspaceAccessStatus -Json (New-StatusFixture)
if (-not (Test-BunkFyWorkspaceAccessStatusConverged -Status $converged)) {
    throw 'Converged workspace access fixture was not recognized.'
}
$drifted = ConvertFrom-BunkFyWorkspaceAccessStatus -Json (
    New-StatusFixture -DriftedSeeds 1 -LegacyMembers 2 -MarkerMembers 3 -RequiresBackfill $true)
if (Test-BunkFyWorkspaceAccessStatusConverged -Status $drifted) {
    throw 'Drifted workspace access fixture was accepted as converged.'
}
Assert-Rejected `
    -Description 'Inconsistent workspace access backfill state' `
    -Action {
        ConvertFrom-BunkFyWorkspaceAccessStatus -Json (
            New-StatusFixture -DriftedSeeds 1 -RequiresBackfill $false)
    }

$bootstrap = ConvertFrom-BunkFyWorkspaceAccessBootstrapResult -Json (
    [ordered]@{
        seedVersion = 4
        seedProfileCount = 4
        migratedMemberCount = 2
    } | ConvertTo-Json)
$after = ConvertFrom-BunkFyWorkspaceAccessStatus -Json (
    New-StatusFixture -MarkerMembers 5)
Assert-BunkFyWorkspaceAccessBootstrapTransition `
    -Before $drifted `
    -Bootstrap $bootstrap `
    -After $after
Assert-Rejected `
    -Description 'Incomplete bootstrap result' `
    -Action {
        $wrongBootstrap = ConvertFrom-BunkFyWorkspaceAccessBootstrapResult -Json (
            [ordered]@{
                seedVersion = 4
                seedProfileCount = 4
                migratedMemberCount = 1
            } | ConvertTo-Json)
        Assert-BunkFyWorkspaceAccessBootstrapTransition `
            -Before $drifted `
            -Bootstrap $wrongBootstrap `
            -After $after
    }

$retainedJson = (ConvertTo-BunkFyWorkspaceAccessStatusEvidence -Status $after |
    ConvertTo-Json -Depth 4)
if ($retainedJson.Contains('workspace-one', [StringComparison]::Ordinal)) {
    throw 'Workspace access status evidence retained a raw scope id.'
}

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $operatorPath,
    [ref]$tokens,
    [ref]$parseErrors) | Out-Null
if (@($parseErrors).Count -ne 0) {
    throw 'Workspace access estate operator has invalid PowerShell syntax.'
}
$operator = Get-Content -LiteralPath $operatorPath -Raw
foreach ($required in @(
        'SupportsShouldProcess = $true',
        'Assert-BunkFyPublicApiReleaseIdentity',
        'Get-BunkFyWorkspaceAccessRuntimeImage',
        "'--rm'",
        "'--no-deps'",
        "'-T'",
        'Remove-BunkFyWorkspaceAccessTransientContainer',
        'ConvertFrom-BunkFyOrganizationCatalogPage',
        'ConvertFrom-BunkFyWorkspaceAccessStatus',
        'ConvertFrom-BunkFyWorkspaceAccessBootstrapResult',
        'Write-BunkFyPrivateJsonEvidence',
        'adminCliMatchesRunningApi',
        'actorFingerprintSha256',
        'non-converged-status-only')) {
    if (-not $operator.Contains($required, [StringComparison]::Ordinal)) {
        throw "Workspace access estate operator is missing guard '$required'."
    }
}
foreach ($forbidden in @(
        'Invoke-Sqlcmd',
        'NpgsqlConnection',
        'psql ',
        '/api/admin/',
        'DangerousAcceptAnyServerCertificateValidator',
        'ServerCertificateCustomValidationCallback',
        '-SkipCertificateCheck')) {
    if ($operator.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Workspace access estate operator contains forbidden token '$forbidden'."
    }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-workspace-access-estate-' + [Guid]::NewGuid().ToString('N'))
try {
    New-BunkFyLocalSensitiveDirectory `
        -Path $fixtureRoot `
        -Description 'Workspace access estate fixture directory'
    $environmentPath = Join-Path $fixtureRoot '.env'
    Write-BunkFyLocalSensitiveTextFile `
        -Path $environmentPath `
        -Content "fixture=true`n" `
        -Description 'Workspace access estate fixture environment'
    $whatIfDirectory = Join-Path $fixtureRoot 'what-if-output'
    & $operatorPath `
        -PublicOrigin 'https://preview.example.test' `
        -ExpectedReleaseId 'preview-workspace-access-fixture' `
        -EnvironmentPath $environmentPath `
        -ComposePath $composePath `
        -OutputPath (Join-Path $whatIfDirectory 'evidence.json') `
        -Apply `
        -WhatIf | Out-Null
    if (Test-Path -LiteralPath $whatIfDirectory) {
        throw 'Workspace access estate WhatIf guard was not side-effect free.'
    }
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'BunkFy Preview workspace access estate fixture passed.'
