param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][Uri] $AdapterHostOrigin,
    [Parameter(Mandatory = $true)][Guid] $WorkspaceId,
    [Parameter(Mandatory = $true)][Guid] $PropertyId,
    [Parameter(Mandatory = $true)][Guid] $ConnectionId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9][a-z0-9._-]{0,127}$')][string] $ExpectedAdapterType,
    [Parameter(Mandatory = $true)][Guid] $ExpectedWorkerId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string] $ExpectedExternalIdSha256,
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{0,127}$')][string] $ExpectedSourceRecordType,
    [Parameter(Mandatory = $true)][ValidateSet('Disabled', 'LoopbackOnly')][string] $StatusEndpointExposure,
    [Security.SecureString] $OperatorAccessToken,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [ValidateRange(30, 1800)][int] $CycleTimeoutSeconds = 300,
    [ValidateRange(10, 300)][int] $ReceiptConvergenceTimeoutSeconds = 90,
    [ValidateRange(500, 10000)][int] $PollIntervalMilliseconds = 2000,
    [string] $OutputPath,
    [switch] $AllowLoopbackPublicHttp,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'deployed-public-edge.common.ps1')
. (Join-Path $PSScriptRoot 'deployed-authenticated-smoke.common.ps1')

$observedAdmissionEvidenceReference = $null
$public = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackPublicHttp

function Assert-AdapterHostOrigin {
    param([Parameter(Mandatory = $true)][Uri] $Origin)

    if (-not $Origin.IsAbsoluteUri -or
        -not [string]::IsNullOrEmpty($Origin.UserInfo) -or
        -not [string]::IsNullOrEmpty($Origin.Query) -or
        -not [string]::IsNullOrEmpty($Origin.Fragment) -or
        ($Origin.AbsolutePath -notin @('', '/'))) {
        throw 'AdapterHostOrigin must be an absolute HTTP(S) origin without user information, path, query, or fragment.'
    }
    if ($Origin.Scheme -ne 'https' -and
        ($Origin.Scheme -ne 'http' -or -not $Origin.IsLoopback)) {
        throw 'AdapterHostOrigin must use HTTPS, or HTTP on loopback.'
    }

    return [Uri]$Origin.GetLeftPart([UriPartial]::Authority)
}

$adapterHost = Assert-AdapterHostOrigin -Origin $AdapterHostOrigin
$StatusEndpointExposure = if ($StatusEndpointExposure -ieq 'LoopbackOnly') {
    'LoopbackOnly'
}
else {
    'Disabled'
}
if ($StatusEndpointExposure -ceq 'LoopbackOnly' -and -not $adapterHost.IsLoopback) {
    throw 'LoopbackOnly status exposure must be verified through a loopback AdapterHost origin.'
}
$requiredIdentities = [ordered]@{
    WorkspaceId = $WorkspaceId
    PropertyId = $PropertyId
    ConnectionId = $ConnectionId
    ExpectedWorkerId = $ExpectedWorkerId
}
foreach ($identity in $requiredIdentities.GetEnumerator()) {
    if ([Guid]$identity.Value -eq [Guid]::Empty) {
        throw "$($identity.Key) must not be an empty GUID."
    }
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/adapter-host-$stamp.json"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) {
    $item = Get-Item -LiteralPath $OutputPath -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The output path is not a regular file: '$OutputPath'."
    }
    if (-not $Force) {
        throw "The output file already exists: '$OutputPath'. Use -Force to replace it."
    }
}

$operatorToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $OperatorAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_INGESTION_OPERATOR_TOKEN' `
    -Prompt 'Ingestion operator access token'
if ([string]::IsNullOrWhiteSpace($operatorToken)) {
    throw 'The Ingestion operator access token is required.'
}

$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$handler.AutomaticDecompression =
    [Net.DecompressionMethods]::GZip -bor
    [Net.DecompressionMethods]::Deflate -bor
    [Net.DecompressionMethods]::Brotli
$client = [Net.Http.HttpClient]::new($handler, $true)
$client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Deployed-AdapterHost-Probe/1')
$script:AdapterHostMaximumBodyBytes = 32KB
$checks = [Collections.Generic.List[object]]::new()
$targetRun = $null
$targetReceipt = $null
$baselineCheckpoint = $null
$currentCheckpoint = $null

function Invoke-SmokeApi {
    param([Parameter(Mandatory = $true)][string] $Path)

    return Invoke-BunkFyAuthenticatedJsonRequest `
        -Client $client `
        -Origin $public `
        -Path $Path `
        -Method GET `
        -TenantId $WorkspaceId.ToString('D') `
        -AccessToken $operatorToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body $null
}

function Read-SmokeJson {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    return ConvertFrom-BunkFyAuthenticatedJsonResponse `
        -Response $Response `
        -ExpectedStatus $ExpectedStatus `
        -Operation $Operation
}

function Invoke-AdapterHostRequest {
    param([Parameter(Mandatory = $true)][ValidatePattern('^/')][string] $Path)

    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Get,
        [Uri]::new($adapterHost, $Path))
    $cancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($RequestTimeoutSeconds))
    try {
        [void]$request.Headers.Accept.ParseAdd('application/json')
        $response = $client.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token).GetAwaiter().GetResult()
        try {
            $contentLength = $response.Content.Headers.ContentLength
            if ($null -ne $contentLength -and
                $contentLength -gt $script:AdapterHostMaximumBodyBytes) {
                throw "AdapterHost response exceeds $script:AdapterHostMaximumBodyBytes bytes."
            }
            $stream = $response.Content.ReadAsStreamAsync(
                $cancellation.Token).GetAwaiter().GetResult()
            try {
                $buffer = [byte[]]::new(4096)
                $body = [IO.MemoryStream]::new()
                try {
                    while (($read = $stream.ReadAsync(
                                $buffer,
                                0,
                                $buffer.Length,
                                $cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
                        if ($body.Length + $read -gt $script:AdapterHostMaximumBodyBytes) {
                            throw "AdapterHost response exceeds $script:AdapterHostMaximumBodyBytes bytes."
                        }
                        $body.Write($buffer, 0, $read)
                    }
                    $bodyBytes = $body.ToArray()
                }
                finally {
                    $body.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Body = $bodyBytes
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch [OperationCanceledException] {
        throw "AdapterHost request to '$Path' exceeded the $RequestTimeoutSeconds-second timeout."
    }
    finally {
        $cancellation.Dispose()
        $request.Dispose()
    }
}

function Read-AdapterHostJson {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ($Response.StatusCode -ne $ExpectedStatus) {
        throw "$Operation returned HTTP $($Response.StatusCode); expected HTTP $ExpectedStatus."
    }
    if ($Response.Body.Length -eq 0) {
        throw "$Operation returned an empty body."
    }
    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($Response.Body)
        return $json | ConvertFrom-Json -Depth 12
    }
    catch {
        throw "$Operation returned an invalid JSON response."
    }
}

function Assert-AdapterHostHealth {
    $liveResponse = Invoke-AdapterHostRequest -Path '/health/live'
    $live = Read-AdapterHostJson `
        -Response $liveResponse `
        -ExpectedStatus 200 `
        -Operation 'AdapterHost liveness'
    $readyResponse = Invoke-AdapterHostRequest -Path '/health/ready'
    $ready = Read-AdapterHostJson `
        -Response $readyResponse `
        -ExpectedStatus 200 `
        -Operation 'AdapterHost readiness'
    if (@($live.PSObject.Properties.Name).Count -ne 1 -or
        @($ready.PSObject.Properties.Name).Count -ne 1 -or
        $live.PSObject.Properties.Name -cnotcontains 'status' -or
        $ready.PSObject.Properties.Name -cnotcontains 'status' -or
        [string]$live.status -cne 'live' -or
        [string]$ready.status -cne 'ready') {
        throw 'AdapterHost health responses contain an unexpected state.'
    }
    foreach ($sensitive in @(
            $WorkspaceId.ToString('D'),
            $PropertyId.ToString('D'),
            $ConnectionId.ToString('D'),
            $ExpectedWorkerId.ToString('D'),
            $ExpectedExternalIdSha256)) {
        $liveText = [Text.UTF8Encoding]::new($false).GetString($liveResponse.Body)
        $readyText = [Text.UTF8Encoding]::new($false).GetString($readyResponse.Body)
        if ($liveText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase) -or
            $readyText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'AdapterHost health exposed operational identity.'
        }
    }
}

function Get-AdapterHostStatus {
    $response = Invoke-AdapterHostRequest -Path '/status'
    if ($StatusEndpointExposure -ceq 'Disabled') {
        if ($response.StatusCode -ne 404) {
            throw "Disabled AdapterHost status returned HTTP $($response.StatusCode); expected HTTP 404."
        }
        $bodyText = [Text.UTF8Encoding]::new($false).GetString($response.Body)
        foreach ($sensitive in @(
                $WorkspaceId.ToString('D'),
                $PropertyId.ToString('D'),
                $ConnectionId.ToString('D'),
                $ExpectedWorkerId.ToString('D'),
                $ExpectedExternalIdSha256,
                [string]$baselineCheckpoint,
                [string]$currentCheckpoint) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
            if ($bodyText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Disabled AdapterHost status exposed operational identity.'
            }
        }
        return $null
    }

    $status = Read-AdapterHostJson `
        -Response $response `
        -ExpectedStatus 200 `
        -Operation 'AdapterHost status'
    if ([string]$status.adapterType -cne $ExpectedAdapterType -or
        [Guid]$status.connectionId -ne $ConnectionId -or
        -not [bool]$status.ready -or
        [int]$status.state -notin @(1, 2, 3)) {
        throw 'AdapterHost status does not match the expected ready process identity.'
    }
    $bodyText = [Text.UTF8Encoding]::new($false).GetString($response.Body)
    foreach ($sensitive in @(
            $WorkspaceId.ToString('D'),
            $PropertyId.ToString('D'),
            $ExpectedWorkerId.ToString('D'),
            $ExpectedExternalIdSha256,
            [string]$baselineCheckpoint,
            [string]$currentCheckpoint) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        if ($bodyText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'AdapterHost status exposed tenant, property, worker, source, or checkpoint identity.'
        }
    }
    return $status
}

function Get-SmokeConnection {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($ConnectionId.ToString('D'))") `
        -ExpectedStatus 200 `
        -Operation 'Read adapter connection'
}

function Get-SmokeConnectionHealth {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($ConnectionId.ToString('D'))/health") `
        -ExpectedStatus 200 `
        -Operation 'Read adapter connection health'
}

function Get-SmokeRuns {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/runs?connectionId=$($ConnectionId.ToString('D'))&page=1&pageSize=100") `
        -ExpectedStatus 200 `
        -Operation 'List adapter runs'
}

function Get-SmokeRun {
    param([Parameter(Mandatory = $true)][Guid] $RunId)

    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/runs/$($RunId.ToString('D'))") `
        -ExpectedStatus 200 `
        -Operation "Read adapter run '$RunId'"
}

function Get-SmokeRunReceipts {
    param([Parameter(Mandatory = $true)][Guid] $RunId)

    $receipts = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $response = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/receipts?connectionId=$($ConnectionId.ToString('D'))&runId=$($RunId.ToString('D'))&page=$page&pageSize=100") `
            -ExpectedStatus 200 `
            -Operation "List receipts for run '$RunId'"
        foreach ($receipt in @($response.receipts)) {
            $receipts.Add($receipt)
        }
        $page++
        if ($page -gt 100) {
            throw "Receipt lookup for run '$RunId' exceeded 100 pages."
        }
    } while ([bool]$response.hasMore)

    return $receipts.ToArray()
}

function Get-SmokeReceipt {
    param([Parameter(Mandatory = $true)][Guid] $ReceiptId)

    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/receipts/$($ReceiptId.ToString('D'))") `
        -ExpectedStatus 200 `
        -Operation "Read adapter receipt '$ReceiptId'"
}

function Get-ExternalIdSha256 {
    param([Parameter(Mandatory = $true)][string] $ExternalId)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($ExternalId)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    return $hash.ToLowerInvariant()
}

function Wait-SmokeTargetRun {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.HashSet[Guid]] $BaselineRunIds,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.HashSet[Guid]] $BaselineRunningRunIds
    )

    $checkedTerminalRuns = [Collections.Generic.HashSet[Guid]]::new()
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($CycleTimeoutSeconds)
    Write-Host 'Waiting for the deployed AdapterHost to ingest the synthetic source record...'
    do {
        $runs = Get-SmokeRuns
        foreach ($candidate in @($runs.runs)) {
            $runId = [Guid]$candidate.runId
            $eligible = -not $BaselineRunIds.Contains($runId) -or
                $BaselineRunningRunIds.Contains($runId)
            if (-not $eligible -or
                [int]$candidate.status -notin @(2, 3) -or
                [int]$candidate.acceptedCount -lt 1 -or
                $checkedTerminalRuns.Contains($runId)) {
                continue
            }

            $receipts = @(Get-SmokeRunReceipts -RunId $runId)
            $matches = @($receipts | Where-Object {
                    (Get-ExternalIdSha256 -ExternalId ([string]$_.externalId)) -ceq $ExpectedExternalIdSha256 -and
                    ([string]::IsNullOrWhiteSpace($ExpectedSourceRecordType) -or
                        [string]$_.sourceRecordType -ceq $ExpectedSourceRecordType)
                })
            if ($matches.Count -gt 1) {
                throw 'The synthetic source identity resolved to more than one receipt in a run.'
            }
            if ($matches.Count -eq 1) {
                return [pscustomobject]@{
                    RunId = $runId
                    ReceiptId = [Guid]$matches[0].receiptId
                }
            }
            if ($receipts.Count -ge [int]$candidate.acceptedCount) {
                [void]$checkedTerminalRuns.Add($runId)
            }
        }

        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw 'No terminal remote AdapterHost run accepted the expected synthetic source record before the timeout.'
}

function Wait-SmokeTerminalReceipt {
    param([Parameter(Mandatory = $true)][Guid] $ReceiptId)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ReceiptConvergenceTimeoutSeconds)
    do {
        $receipt = Get-SmokeReceipt -ReceiptId $ReceiptId
        if ([int]$receipt.status -in @(2, 3)) {
            return $receipt
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "Receipt '$ReceiptId' did not reach a terminal processing state before the timeout."
}

try {
    $releaseIdBefore = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $public `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -ObservedAdmissionEvidenceReference ([ref]$observedAdmissionEvidenceReference)
    Assert-AdapterHostHealth
    $hostStatusBefore = Get-AdapterHostStatus
    $checks.Add([ordered]@{ name = 'adapter-host-ready-and-exposure-correct'; status = 'passed' })

    $connectionBefore = Get-SmokeConnection
    $healthBefore = Get-SmokeConnectionHealth
    if ([Guid]$connectionBefore.connectionId -ne $ConnectionId -or
        [Guid]$connectionBefore.propertyId -ne $PropertyId -or
        [string]$connectionBefore.adapterType -cne $ExpectedAdapterType -or
        [int]$connectionBefore.executionMode -ne 4 -or
        [int]$connectionBefore.status -ne 1 -or
        [Guid]$healthBefore.connectionId -ne $ConnectionId -or
        [Guid]$healthBefore.propertyId -ne $PropertyId -or
        [string]$healthBefore.adapterType -cne $ExpectedAdapterType -or
        [int]$healthBefore.executionMode -ne 4 -or
        [int]$healthBefore.capabilityStatus -ne 1 -or
        [int]$healthBefore.protocolVersion -lt 1 -or
        [int]$healthBefore.configurationSchemaVersion -lt 1) {
        throw 'The target connection is not an enabled, available RemotePolling connection for the expected adapter.'
    }
    $baselineCheckpoint = [string]$connectionBefore.checkpoint
    $checks.Add([ordered]@{ name = 'remote-polling-connection-preflight'; status = 'passed' })

    $baselineRuns = Get-SmokeRuns
    $baselineRunIds = [Collections.Generic.HashSet[Guid]]::new()
    $baselineRunningRunIds = [Collections.Generic.HashSet[Guid]]::new()
    foreach ($run in @($baselineRuns.runs)) {
        $runId = [Guid]$run.runId
        [void]$baselineRunIds.Add($runId)
        if ([int]$run.status -eq 1) {
            [void]$baselineRunningRunIds.Add($runId)
        }
    }

    $target = Wait-SmokeTargetRun `
        -BaselineRunIds $baselineRunIds `
        -BaselineRunningRunIds $baselineRunningRunIds
    $targetRun = Get-SmokeRun -RunId $target.RunId
    if ([Guid]$targetRun.runId -ne $target.RunId -or
        [Guid]$targetRun.connectionId -ne $ConnectionId -or
        [Guid]$targetRun.propertyId -ne $PropertyId -or
        [int]$targetRun.executionKind -ne 2 -or
        $null -ne $targetRun.taskRunId -or
        [Guid]$targetRun.remoteLeaseId -eq [Guid]::Empty -or
        [Guid]$targetRun.remoteClaimId -eq [Guid]::Empty -or
        [long]$targetRun.remoteLeaseEpoch -lt 1 -or
        [Guid]$targetRun.remoteWorkerId -ne $ExpectedWorkerId -or
        $null -eq $targetRun.remoteLeaseExpiresAtUtc -or
        [int]$targetRun.status -notin @(2, 3) -or
        [int]$targetRun.acceptedCount -lt 1 -or
        [int]$targetRun.observedCount -ne
            ([int]$targetRun.acceptedCount + [int]$targetRun.rejectedCount) -or
        $null -eq $targetRun.completedAtUtc) {
        throw 'The target run does not carry a complete terminal remote-lease proof.'
    }
    if ([int]$targetRun.status -eq 2 -and
        -not [string]::IsNullOrWhiteSpace([string]$targetRun.errorCode)) {
        throw 'A successful remote AdapterHost run retained an error code.'
    }
    $checks.Add([ordered]@{ name = 'remote-lease-run-proof-complete'; status = 'passed' })

    $targetReceipt = Wait-SmokeTerminalReceipt -ReceiptId $target.ReceiptId
    if ([Guid]$targetReceipt.receiptId -ne $target.ReceiptId -or
        [Guid]$targetReceipt.propertyId -ne $PropertyId -or
        [Guid]$targetReceipt.connectionId -ne $ConnectionId -or
        [Guid]$targetReceipt.runId -ne $target.RunId -or
        [Guid]$targetReceipt.operationId -eq [Guid]::Empty -or
        [Guid]$targetReceipt.rawPayloadFileId -eq [Guid]::Empty -or
        [int]$targetReceipt.rawPayloadStatus -ne 1 -or
        [Guid]$targetReceipt.ingressCredentialId -eq [Guid]::Empty -or
        [string]$targetReceipt.adapterType -cne $ExpectedAdapterType -or
        [int]$targetReceipt.adapterProtocolVersion -ne [int]$healthBefore.protocolVersion -or
        [int]$targetReceipt.configurationSchemaVersion -ne
            [int]$healthBefore.configurationSchemaVersion -or
        (Get-ExternalIdSha256 -ExternalId ([string]$targetReceipt.externalId)) -cne
            $ExpectedExternalIdSha256 -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedSourceRecordType) -and
            [string]$targetReceipt.sourceRecordType -cne $ExpectedSourceRecordType) -or
        [string]$targetReceipt.contentHash -cnotmatch '^[0-9a-f]{64}$' -or
        [int]$targetReceipt.status -ne 2 -or
        -not [string]::IsNullOrWhiteSpace([string]$targetReceipt.rejectionReason) -or
        $null -eq $targetReceipt.processedAtUtc) {
        throw 'The target receipt does not preserve durable AdapterHost provenance and source correlation.'
    }
    $checks.Add([ordered]@{ name = 'durable-receipt-provenance-correlated'; status = 'passed' })

    $acceptedCheckpoint = [string]$targetRun.acceptedCheckpoint
    if ([string]::IsNullOrWhiteSpace($acceptedCheckpoint) -or
        (-not [string]::IsNullOrWhiteSpace($baselineCheckpoint) -and
            $acceptedCheckpoint -ceq $baselineCheckpoint)) {
        throw 'The target AdapterHost run did not advance the server-owned checkpoint.'
    }

    $connectionAfter = Get-SmokeConnection
    $currentCheckpoint = [string]$connectionAfter.checkpoint
    if ([Guid]$connectionAfter.connectionId -ne $ConnectionId -or
        [Guid]$connectionAfter.propertyId -ne $PropertyId -or
        [string]$connectionAfter.adapterType -cne $ExpectedAdapterType -or
        [int]$connectionAfter.executionMode -ne 4 -or
        [int]$connectionAfter.status -ne 1 -or
        [string]::IsNullOrWhiteSpace($currentCheckpoint) -or
        (-not [string]::IsNullOrWhiteSpace($baselineCheckpoint) -and
            $currentCheckpoint -ceq $baselineCheckpoint)) {
        throw 'The connection did not retain an advanced server checkpoint.'
    }
    $checks.Add([ordered]@{ name = 'server-checkpoint-advanced'; status = 'passed' })

    $healthAfter = Get-SmokeConnectionHealth
    if ([Guid]$healthAfter.connectionId -ne $ConnectionId -or
        [Guid]$healthAfter.propertyId -ne $PropertyId -or
        [string]$healthAfter.adapterType -cne $ExpectedAdapterType -or
        [int]$healthAfter.connectionStatus -ne 1 -or
        [int]$healthAfter.executionMode -ne 4 -or
        [int]$healthAfter.capabilityStatus -ne 1 -or
        [int]$healthAfter.protocolVersion -ne [int]$healthBefore.protocolVersion -or
        [int]$healthAfter.configurationSchemaVersion -ne
            [int]$healthBefore.configurationSchemaVersion -or
        [int]$healthAfter.operationalState -notin @(4, 5, 8) -or
        $null -eq $healthAfter.lastObservationReceivedAtUtc -or
        [DateTimeOffset]$healthAfter.lastObservationReceivedAtUtc -lt
            [DateTimeOffset]$targetReceipt.receivedAtUtc) {
        throw 'Connection health did not converge to the observed remote AdapterHost activity.'
    }
    $checks.Add([ordered]@{ name = 'connection-health-converged'; status = 'passed' })

    Assert-AdapterHostHealth
    $hostStatusAfter = Get-AdapterHostStatus
    if ($StatusEndpointExposure -ceq 'LoopbackOnly' -and
        (-not [bool]$hostStatusAfter.hasCheckpoint -or
            [int]$hostStatusAfter.consecutiveFailures -ne 0 -or
            [int]$hostStatusAfter.lastOutcome -notin @(1, 2) -or
            $null -eq $hostStatusAfter.lastCycleCompletedAtUtc)) {
        throw 'AdapterHost status did not converge to a successful checkpointed cycle.'
    }
    $checks.Add([ordered]@{ name = 'adapter-host-post-cycle-healthy'; status = 'passed' })
    $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $public `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -ObservedAdmissionEvidenceReference ([ref]$observedAdmissionEvidenceReference)
    if ($observedReleaseId -cne $releaseIdBefore) {
        throw 'The public API release identity changed during AdapterHost verification.'
    }
    $checks.Add([ordered]@{ name = 'release-identity-continuous'; status = 'passed' })
}
finally {
    $client.Dispose()
    $operatorToken = $null
    $baselineCheckpoint = $null
    $currentCheckpoint = $null
}

$evidence = [ordered]@{
    schemaVersion = 2
    evidenceKind = 'bunkfy-deployed-adapter-host-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    publicOrigin = $public.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    admissionEvidenceReference = $observedAdmissionEvidenceReference
    adapterHostOrigin = $adapterHost.GetLeftPart([UriPartial]::Authority)
    publicTransport = if ($public.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-fixture' }
    adapterHostTransport = if ($adapterHost.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http' }
    result = 'passed'
    workspaceId = $WorkspaceId.ToString('D')
    propertyId = $PropertyId.ToString('D')
    connectionId = $ConnectionId.ToString('D')
    adapterType = $ExpectedAdapterType
    workerId = $ExpectedWorkerId.ToString('D')
    statusEndpointExposure = $StatusEndpointExposure
    run = [ordered]@{
        runId = ([Guid]$targetRun.runId).ToString('D')
        status = [int]$targetRun.status
        observedCount = [int]$targetRun.observedCount
        acceptedCount = [int]$targetRun.acceptedCount
        rejectedCount = [int]$targetRun.rejectedCount
        startedAtUtc = ([DateTimeOffset]$targetRun.startedAtUtc).ToString('O')
        completedAtUtc = ([DateTimeOffset]$targetRun.completedAtUtc).ToString('O')
    }
    receipt = [ordered]@{
        receiptId = ([Guid]$targetReceipt.receiptId).ToString('D')
        status = [int]$targetReceipt.status
        receivedAtUtc = ([DateTimeOffset]$targetReceipt.receivedAtUtc).ToString('O')
        processedAtUtc = if ($null -eq $targetReceipt.processedAtUtc) {
            $null
        }
        else {
            ([DateTimeOffset]$targetReceipt.processedAtUtc).ToString('O')
        }
    }
    checks = @($checks)
    limitations = @(
        'synthetic-provider-record-injection-not-performed-by-probe',
        'credential-rotation-and-process-restart-not-exercised',
        'production-admission-log-and-orchestrator-topology-not-observed',
        'raw-payload-content-not-read'
    )
}

$parent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $parent -Force)
}
Write-BunkFyPrivateJsonEvidence `
    -Path $OutputPath `
    -Value $evidence `
    -Overwrite:$Force

Write-Host "BunkFy deployed AdapterHost passed $($checks.Count) checks."
Write-Host "Evidence: $OutputPath"
