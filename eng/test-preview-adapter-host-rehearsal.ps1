Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'operations\rehearse-preview-adapter-host.ps1'
$composePath = Join-Path $PSScriptRoot '..\deploy\preview\compose.yaml'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-preview-adapter-host-policy-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)
$previousToken = [Environment]::GetEnvironmentVariable(
    'BUNKFY_SMOKE_INGESTION_OPERATOR_TOKEN')

$arguments = @{
    PublicOrigin = [Uri]'http://127.0.0.1:8080'
    ExpectedReleaseId = 'preview-adapter-fixture'
    WorkspaceId = [Guid]'11111111-1111-4111-8111-111111111111'
    PropertyId = [Guid]'22222222-2222-4222-8222-222222222222'
    InventoryUnitId = [Guid]'33333333-3333-4333-8333-333333333333'
    BackendImage = '127.0.0.1:5000/bunkfy/backend@sha256:' + ('a' * 64)
    BackendSourceCommitSha = 'b' * 40
    UpsertEvidencePath = Join-Path $fixtureRoot 'upsert.json'
    CancellationEvidencePath = Join-Path $fixtureRoot 'cancellation.json'
    AllowLoopbackPublicHttp = $true
    WhatIf = $true
}

try {
    [Environment]::SetEnvironmentVariable(
        'BUNKFY_SMOKE_INGESTION_OPERATOR_TOKEN',
        'preview-adapter-fixture-token')

    & $scriptPath @arguments | Out-Null
    if ((Test-Path -LiteralPath $arguments['UpsertEvidencePath']) -or
        (Test-Path -LiteralPath $arguments['CancellationEvidencePath'])) {
        throw 'Preview AdapterHost rehearsal WhatIf created retained evidence.'
    }

    $tagOnlyRejected = $false
    try {
        $invalid = $arguments.Clone()
        $invalid['BackendImage'] = 'bunkfy/backend:preview'
        & $scriptPath @invalid | Out-Null
    }
    catch {
        $tagOnlyRejected = $_.Exception.Message -ceq
            'BackendImage must be an exact lowercase repository@sha256:<digest> reference.'
    }
    if (-not $tagOnlyRejected) {
        throw 'Preview AdapterHost rehearsal accepted a mutable image tag.'
    }

    $duplicateEvidenceRejected = $false
    try {
        $invalid = $arguments.Clone()
        $invalid['CancellationEvidencePath'] = $invalid['UpsertEvidencePath']
        & $scriptPath @invalid | Out-Null
    }
    catch {
        $duplicateEvidenceRejected = $_.Exception.Message -ceq
            'Upsert and cancellation evidence paths must be distinct.'
    }
    if (-not $duplicateEvidenceRejected) {
        throw 'Preview AdapterHost rehearsal accepted one path for two evidence records.'
    }

    $composeLines = @(Get-Content -LiteralPath $composePath)
    if (@($composeLines | Where-Object {
                $_.Trim() -ceq 'Ingestion__AdapterIngress__Enabled: "true"'
            }).Count -ne 1) {
        throw 'Preview Compose must enable adapter ingress on exactly one service.'
    }

    $scriptContent = Get-Content -LiteralPath $scriptPath -Raw
    $preflightPathIndex = $scriptContent.IndexOf(
        '/remote-leases/claim',
        [StringComparison]::Ordinal)
    $preflightStatusIndex = $scriptContent.IndexOf(
        "-Operation 'Verify Preview adapter ingress is enabled and independently authenticated'",
        [StringComparison]::Ordinal)
    $connectionCreateIndex = $scriptContent.IndexOf(
        "-Operation 'Create the Preview AdapterHost connection'",
        [StringComparison]::Ordinal)
    if ($preflightPathIndex -lt 0 -or
        $preflightStatusIndex -lt $preflightPathIndex -or
        $connectionCreateIndex -lt $preflightStatusIndex) {
        throw 'Preview AdapterHost ingress activation must be verified before connection creation.'
    }
}
finally {
    [Environment]::SetEnvironmentVariable(
        'BUNKFY_SMOKE_INGESTION_OPERATOR_TOKEN',
        $previousToken)
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'BunkFy Preview AdapterHost rehearsal fixture passed.'
