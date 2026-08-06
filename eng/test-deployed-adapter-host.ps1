Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-adapter-host.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-adapter-host-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$externalId = 'deployment-adapter-host-record-20260806'
$externalIdBytes = [Text.UTF8Encoding]::new($false).GetBytes($externalId)
$externalIdHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($externalIdBytes)).ToLowerInvariant()
$fixture = [pscustomobject]@{
    ReleaseId = 'release-fixture-001'
    WorkspaceId = '11111111-1111-4111-8111-111111111111'
    PropertyId = '22222222-2222-4222-8222-222222222222'
    ConnectionId = '33333333-3333-4333-8333-333333333333'
    WorkerId = '44444444-4444-4444-8444-444444444444'
    WrongWorkerId = '55555555-5555-4555-8555-555555555555'
    OldRunId = '66666666-6666-4666-8666-666666666666'
    RunId = '77777777-7777-4777-8777-777777777777'
    LeaseId = '88888888-8888-4888-8888-888888888888'
    ClaimId = '99999999-9999-4999-8999-999999999999'
    ReceiptId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    OperationId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    RawPayloadFileId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    CredentialId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    AdapterType = 'fake.http'
    SourceRecordType = 'reservation.v1'
    ExternalId = $externalId
    ExternalIdHash = $externalIdHash
    OperatorToken = 'fixture-ingestion-operator-token-do-not-retain'
    BaselineCheckpoint = 'checkpoint-sensitive-40'
    CurrentCheckpoint = 'checkpoint-sensitive-41'
}

function Start-BunkFyAdapterHostFixtureServer {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid-loopback', 'valid-disabled', 'wrong-worker', 'rejected-receipt')]
        [string] $Mode
    )

    $readyPath = Join-Path $fixtureRoot ("ready-$Mode-$([Guid]::NewGuid().ToString('N')).txt")
    $job = Start-Job -ScriptBlock {
        param($ReadyPath, $Mode, $Fixture)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        function Write-FixtureResponse {
            param(
                [Parameter(Mandatory = $true)][IO.Stream] $Stream,
                [Parameter(Mandatory = $true)][int] $Status,
                [Parameter(Mandatory = $true)][string] $Reason,
                [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Body
            )

            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Body)
            $headers = @(
                "HTTP/1.1 $Status $Reason",
                'Connection: close',
                'Content-Type: application/json; charset=utf-8',
                "Content-Length: $($bytes.Length)",
                '',
                '')
            $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers -join "`r`n")
            $Stream.Write($headerBytes, 0, $headerBytes.Length)
            if ($bytes.Length -gt 0) {
                $Stream.Write($bytes, 0, $bytes.Length)
            }
            $Stream.Flush()
        }

        function New-Connection {
            param([Parameter(Mandatory = $true)][bool] $Advanced)

            return [ordered]@{
                connectionId = $Fixture.ConnectionId
                propertyId = $Fixture.PropertyId
                adapterType = $Fixture.AdapterType
                executionMode = 4
                pollingIntervalSeconds = $null
                pollingScheduleMaxAttempts = $null
                pollingScheduleConfiguredAtUtc = $null
                conflictPolicy = 1
                configurationReference = 'fixture://configuration'
                hasSecretReference = $false
                checkpoint = if ($Advanced) {
                    $Fixture.CurrentCheckpoint
                }
                else {
                    $Fixture.BaselineCheckpoint
                }
                status = 1
                version = if ($Advanced) { 4 } else { 2 }
                createdAtUtc = '2026-08-06T08:00:00Z'
                updatedAtUtc = if ($Advanced) { '2026-08-06T10:00:00Z' } else { $null }
            }
        }

        function New-ConnectionHealth {
            param([Parameter(Mandatory = $true)][bool] $Advanced)

            return [ordered]@{
                connectionId = $Fixture.ConnectionId
                propertyId = $Fixture.PropertyId
                adapterType = $Fixture.AdapterType
                connectionStatus = 1
                executionMode = 4
                capabilityStatus = 1
                protocolVersion = 1
                configurationSchemaVersion = 1
                pollingIntervalSeconds = $null
                pollingScheduleMaxAttempts = $null
                pollingScheduleConfiguredAtUtc = $null
                nextRunExpectedAtUtc = $null
                runExpected = $false
                operationalState = 4
                latestRunId = if ($Advanced) { $Fixture.RunId } else { $Fixture.OldRunId }
                latestRunStatus = 2
                latestRunStartedAtUtc = if ($Advanced) {
                    '2026-08-06T10:00:00Z'
                }
                else {
                    '2026-08-06T09:00:00Z'
                }
                latestRunCompletedAtUtc = if ($Advanced) {
                    '2026-08-06T10:00:02Z'
                }
                else {
                    '2026-08-06T09:00:02Z'
                }
                latestRunErrorCode = $null
                lastSuccessfulRunAtUtc = if ($Advanced) {
                    '2026-08-06T10:00:02Z'
                }
                else {
                    '2026-08-06T09:00:02Z'
                }
                lastObservationReceivedAtUtc = if ($Advanced) {
                    '2026-08-06T10:00:01Z'
                }
                else {
                    $null
                }
                pendingReceiptCount = 0
                rejectedReceiptCount = 0
                expiredRawPayloadCount = 0
                protectedRawPayloadCount = 0
                heldExpiredRawPayloadCount = 0
                purgingRawPayloadCount = 0
                dueSensitiveHistoryCount = 0
                heldDueSensitiveHistoryCount = 0
                redactedSensitiveHistoryCount = 0
                activeLegalHoldCount = 0
                evaluatedAtUtc = '2026-08-06T10:00:03Z'
            }
        }

        function New-RunList {
            param([Parameter(Mandatory = $true)][bool] $Advanced)

            $runs = [Collections.Generic.List[object]]::new()
            if ($Advanced) {
                $runs.Add([ordered]@{
                        runId = $Fixture.RunId
                        connectionId = $Fixture.ConnectionId
                        status = 2
                        observedCount = 1
                        acceptedCount = 1
                        rejectedCount = 0
                        errorCode = $null
                        startedAtUtc = '2026-08-06T10:00:00Z'
                        completedAtUtc = '2026-08-06T10:00:02Z'
                    })
            }
            $runs.Add([ordered]@{
                    runId = $Fixture.OldRunId
                    connectionId = $Fixture.ConnectionId
                    status = 2
                    observedCount = 0
                    acceptedCount = 0
                    rejectedCount = 0
                    errorCode = $null
                    startedAtUtc = '2026-08-06T09:00:00Z'
                    completedAtUtc = '2026-08-06T09:00:02Z'
                })
            return [ordered]@{
                runs = @($runs)
                page = 1
                pageSize = 100
                hasMore = $false
            }
        }

        function New-RunDetail {
            $workerId = if ($Mode -ceq 'wrong-worker') {
                $Fixture.WrongWorkerId
            }
            else {
                $Fixture.WorkerId
            }
            return [ordered]@{
                runId = $Fixture.RunId
                connectionId = $Fixture.ConnectionId
                propertyId = $Fixture.PropertyId
                executionKind = 2
                taskRunId = $null
                taskAttempt = $null
                remoteLeaseId = $Fixture.LeaseId
                remoteClaimId = $Fixture.ClaimId
                remoteLeaseEpoch = 4
                remoteWorkerId = $workerId
                remoteLeaseExpiresAtUtc = '2026-08-06T10:02:00Z'
                startingCheckpoint = $Fixture.BaselineCheckpoint
                acceptedCheckpoint = $Fixture.CurrentCheckpoint
                status = 2
                observedCount = 1
                acceptedCount = 1
                rejectedCount = 0
                errorCode = $null
                version = 3
                startedAtUtc = '2026-08-06T10:00:00Z'
                completedAtUtc = '2026-08-06T10:00:02Z'
            }
        }

        function New-ReceiptList {
            return [ordered]@{
                receipts = @([ordered]@{
                        receiptId = $Fixture.ReceiptId
                        connectionId = $Fixture.ConnectionId
                        sourceRecordType = $Fixture.SourceRecordType
                        externalId = $Fixture.ExternalId
                        parserType = $null
                        parserVersion = $null
                        status = 2
                        receivedAtUtc = '2026-08-06T10:00:01Z'
                    })
                page = 1
                pageSize = 100
                hasMore = $false
            }
        }

        function New-ReceiptDetail {
            param([Parameter(Mandatory = $true)][bool] $Terminal)

            return [ordered]@{
                receiptId = $Fixture.ReceiptId
                propertyId = $Fixture.PropertyId
                connectionId = $Fixture.ConnectionId
                runId = $Fixture.RunId
                operationId = $Fixture.OperationId
                sourceRecordType = $Fixture.SourceRecordType
                externalId = $Fixture.ExternalId
                sourceRevision = '1'
                contentHash = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
                rawPayloadFileId = $Fixture.RawPayloadFileId
                rawPayloadStatus = 1
                rawPayloadRetainUntilUtc = '2026-09-05T10:00:01Z'
                rawPayloadPurgedAtUtc = $null
                activeReprocessingAttemptId = $null
                reprocessingReservationExpiresAtUtc = $null
                sourceReceiptId = $null
                reprocessingAttemptId = $null
                parserType = $null
                parserVersion = $null
                parserOutputIndex = $null
                sourceUpdatedAtUtc = '2026-08-06T09:59:00Z'
                observedAtUtc = '2026-08-06T10:00:00Z'
                status = if (-not $Terminal) {
                    1
                }
                elseif ($Mode -ceq 'rejected-receipt') {
                    3
                }
                else {
                    2
                }
                rejectionReason = if ($Terminal -and $Mode -ceq 'rejected-receipt') {
                    'fixture-rejected'
                }
                else {
                    $null
                }
                receivedAtUtc = '2026-08-06T10:00:01Z'
                processedAtUtc = if ($Terminal) { '2026-08-06T10:00:03Z' } else { $null }
                ingressCredentialId = $Fixture.CredentialId
                adapterType = $Fixture.AdapterType
                adapterProtocolVersion = 1
                configurationSchemaVersion = 1
                sourceSystem = 'deployment.fixture'
                customerOwner = 'operations'
            }
        }

        function New-AdapterHostStatus {
            return [ordered]@{
                adapterType = $Fixture.AdapterType
                connectionId = $Fixture.ConnectionId
                state = 3
                ready = $true
                hasCheckpoint = $true
                lastCycleStartedAtUtc = '2026-08-06T10:00:00Z'
                lastCycleCompletedAtUtc = '2026-08-06T10:00:02Z'
                lastOutcome = 1
                lastErrorCode = $null
                nextCycleAtUtc = '2026-08-06T10:05:02Z'
                consecutiveFailures = 0
            }
        }

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)

            $runListCount = 0
            $connectionReadCount = 0
            $healthReadCount = 0
            $receiptDetailCount = 0
            $statusReadCount = 0
            $requestCount = 0
            $done = $false
            $workflowComplete = $false
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            while (-not $done -and
                $requestCount -lt 40 -and
                [DateTimeOffset]::UtcNow -lt $inactivityDeadline) {
                if (-not $listener.Pending()) {
                    Start-Sleep -Milliseconds 25
                    continue
                }

                $client = $listener.AcceptTcpClient()
                try {
                    $client.ReceiveTimeout = 5000
                    $client.SendTimeout = 5000
                    $stream = $client.GetStream()
                    $reader = [IO.StreamReader]::new(
                        $stream,
                        [Text.UTF8Encoding]::new($false),
                        $false,
                        4096,
                        $true)
                    try {
                        $requestLine = $reader.ReadLine()
                        if ([string]::IsNullOrWhiteSpace($requestLine)) {
                            throw 'Fixture received an empty request line.'
                        }
                        $parts = $requestLine.Split(' ')
                        $method = $parts[0]
                        $path = $parts[1]
                        $headers = @{}
                        while ($true) {
                            $line = $reader.ReadLine()
                            if ([string]::IsNullOrEmpty($line)) {
                                break
                            }
                            $separator = $line.IndexOf(':')
                            if ($separator -gt 0) {
                                $headers[$line.Substring(0, $separator).Trim()] =
                                    $line.Substring($separator + 1).Trim()
                            }
                        }
                    }
                    finally {
                        $reader.Dispose()
                    }

                    if ($method -cne 'GET') {
                        throw "Fixture received unexpected method '$method'."
                    }
                    $isAuthenticatedApi =
                        $path.StartsWith('/api/', [StringComparison]::Ordinal) -and
                        $path -cne '/api/smoke'
                    if ($isAuthenticatedApi) {
                        if ([string]$headers['Authorization'] -cne "Bearer $($Fixture.OperatorToken)" -or
                            [string]$headers['X-Tenant-Id'] -cne $Fixture.WorkspaceId) {
                            throw 'Fixture API request used the wrong token or tenant scope.'
                        }
                    }
                    elseif ($headers.ContainsKey('Authorization') -or
                        $headers.ContainsKey('X-Tenant-Id')) {
                        throw 'AdapterHost health/status request carried API credentials or tenant scope.'
                    }

                    $requestCount++
                    $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
                    $status = 200
                    $reason = 'OK'
                    $response = $null
                    if ($path -ceq '/api/smoke') {
                        $response = [ordered]@{
                            application = 'BunkFy'
                            service = 'BunkFy.Host.Api'
                            status = 'ok'
                            releaseId = $Fixture.ReleaseId
                            timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                        }
                        if ($workflowComplete) {
                            $done = $true
                        }
                    }
                    elseif ($path -ceq '/health/live') {
                        $response = @{ status = 'live' }
                    }
                    elseif ($path -ceq '/health/ready') {
                        $response = @{ status = 'ready' }
                    }
                    elseif ($path -ceq '/status') {
                        $statusReadCount++
                        if ($Mode -ceq 'valid-disabled') {
                            $status = 404
                            $reason = 'Not Found'
                            $response = @{ title = 'not found' }
                        }
                        else {
                            $response = New-AdapterHostStatus
                        }
                        if ($statusReadCount -ge 2) {
                            $workflowComplete = $true
                        }
                    }
                    elseif ($path -ceq "/api/ingestion/properties/$($Fixture.PropertyId)/connections/$($Fixture.ConnectionId)") {
                        $connectionReadCount++
                        $response = New-Connection -Advanced ($connectionReadCount -gt 1)
                    }
                    elseif ($path -ceq "/api/ingestion/properties/$($Fixture.PropertyId)/connections/$($Fixture.ConnectionId)/health") {
                        $healthReadCount++
                        $response = New-ConnectionHealth -Advanced ($healthReadCount -gt 1)
                    }
                    elseif ($path -ceq "/api/ingestion/properties/$($Fixture.PropertyId)/runs?connectionId=$($Fixture.ConnectionId)&page=1&pageSize=100") {
                        $runListCount++
                        $response = New-RunList -Advanced ($runListCount -gt 1)
                    }
                    elseif ($path -ceq "/api/ingestion/properties/$($Fixture.PropertyId)/receipts?connectionId=$($Fixture.ConnectionId)&runId=$($Fixture.RunId)&page=1&pageSize=100") {
                        $response = New-ReceiptList
                    }
                    elseif ($path -ceq "/api/ingestion/properties/$($Fixture.PropertyId)/runs/$($Fixture.RunId)") {
                        $response = New-RunDetail
                        if ($Mode -ceq 'wrong-worker') {
                            $done = $true
                        }
                    }
                    elseif ($path -ceq "/api/ingestion/properties/$($Fixture.PropertyId)/receipts/$($Fixture.ReceiptId)") {
                        $receiptDetailCount++
                        $response = New-ReceiptDetail -Terminal ($receiptDetailCount -gt 1)
                    }
                    else {
                        throw "Fixture received unexpected request '$path'."
                    }

                    $body = $response | ConvertTo-Json -Depth 16 -Compress
                    Write-FixtureResponse `
                        -Stream $stream `
                        -Status $status `
                        -Reason $reason `
                        -Body $body
                }
                finally {
                    $client.Dispose()
                }
            }

            if (-not $done) {
                throw "Fixture stopped before the expected terminal request after $requestCount requests."
            }
        }
        finally {
            $listener.Stop()
        }
    } -ArgumentList $readyPath, $Mode, $fixture

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath) -and
        [DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
    }
    if (-not (Test-Path -LiteralPath $readyPath)) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw "The $Mode AdapterHost fixture did not become ready."
    }
    $port = [int](Get-Content -LiteralPath $readyPath -Raw)
    return [pscustomobject]@{
        Job = $job
        Origin = [Uri]"http://127.0.0.1:$port"
    }
}

function Complete-BunkFyAdapterHostFixtureServer {
    param([Parameter(Mandatory = $true)][object] $Server)

    try {
        $completed = Wait-Job -Job $Server.Job -Timeout 15
        if ($null -eq $completed) {
            throw 'The AdapterHost fixture server did not terminate after the probe.'
        }
        $output = @(Receive-Job -Job $Server.Job -ErrorAction Stop)
        if ($Server.Job.State -ne 'Completed') {
            throw "The AdapterHost fixture ended in state '$($Server.Job.State)': $($output -join [Environment]::NewLine)"
        }
    }
    finally {
        Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    }
}

function Stop-BunkFyAdapterHostFixtureServer {
    param([AllowNull()][object] $Server)

    if ($null -eq $Server) {
        return
    }
    Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
}

function Invoke-BunkFyAdapterHostFixtureProbe {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid-loopback', 'valid-disabled', 'wrong-worker', 'rejected-receipt')]
        [string] $Mode,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $server = $null
    try {
        $server = Start-BunkFyAdapterHostFixtureServer -Mode $Mode
        $token = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        $statusExposure = if ($Mode -ceq 'valid-disabled') { 'Disabled' } else { 'LoopbackOnly' }
        & $probeScript `
            -PublicOrigin $server.Origin `
            -ExpectedReleaseId $fixture.ReleaseId `
            -AdapterHostOrigin $server.Origin `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -ConnectionId $fixture.ConnectionId `
            -ExpectedAdapterType $fixture.AdapterType `
            -ExpectedWorkerId $fixture.WorkerId `
            -ExpectedExternalIdSha256 $fixture.ExternalIdHash `
            -ExpectedSourceRecordType $fixture.SourceRecordType `
            -StatusEndpointExposure $statusExposure `
            -OperatorAccessToken $token `
            -RequestTimeoutSeconds 5 `
            -CycleTimeoutSeconds 30 `
            -ReceiptConvergenceTimeoutSeconds 10 `
            -PollIntervalMilliseconds 500 `
            -OutputPath $OutputPath `
            -AllowLoopbackPublicHttp
        Complete-BunkFyAdapterHostFixtureServer -Server $server
        $server = $null
    }
    finally {
        Stop-BunkFyAdapterHostFixtureServer -Server $server
    }
}

try {
    foreach ($mode in @('valid-loopback', 'valid-disabled')) {
        $outputPath = Join-Path $fixtureRoot "$mode-evidence.json"
        Invoke-BunkFyAdapterHostFixtureProbe -Mode $mode -OutputPath $outputPath
        $evidence = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -Depth 12
        $expectedExposure = if ($mode -ceq 'valid-disabled') { 'Disabled' } else { 'LoopbackOnly' }
        if ($evidence.schemaVersion -ne 1 -or
            $evidence.evidenceKind -cne 'bunkfy-deployed-adapter-host-probe' -or
            $evidence.result -cne 'passed' -or
            $evidence.releaseId -cne $fixture.ReleaseId -or
            @($evidence.checks).Count -ne 8 -or
            [Guid]$evidence.run.runId -ne [Guid]$fixture.RunId -or
            [Guid]$evidence.receipt.receiptId -ne [Guid]$fixture.ReceiptId -or
            [string]$evidence.statusEndpointExposure -cne $expectedExposure) {
            throw "The $mode AdapterHost fixture produced invalid evidence."
        }
        $evidenceText = Get-Content -LiteralPath $outputPath -Raw
        foreach ($sensitive in @(
                $fixture.OperatorToken,
                $fixture.ExternalId,
                $fixture.ExternalIdHash,
                $fixture.BaselineCheckpoint,
                $fixture.CurrentCheckpoint,
                'fixture://configuration')) {
            if ($evidenceText.Contains($sensitive, [StringComparison]::Ordinal)) {
                throw 'AdapterHost evidence retained a credential, source identity, checkpoint, or material reference.'
            }
        }
    }

    $invalidOutput = Join-Path $fixtureRoot 'wrong-worker-evidence.json'
    $wrongWorkerRejected = $false
    try {
        Invoke-BunkFyAdapterHostFixtureProbe -Mode wrong-worker -OutputPath $invalidOutput
    }
    catch {
        $wrongWorkerRejected = $_.Exception.Message.Contains(
            'complete terminal remote-lease proof',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $wrongWorkerRejected -or (Test-Path -LiteralPath $invalidOutput)) {
        throw 'The AdapterHost probe accepted the wrong remote worker or wrote passing evidence.'
    }

    $rejectedReceiptOutput = Join-Path $fixtureRoot 'rejected-receipt-evidence.json'
    $rejectedReceiptRejected = $false
    try {
        Invoke-BunkFyAdapterHostFixtureProbe `
            -Mode rejected-receipt `
            -OutputPath $rejectedReceiptOutput
    }
    catch {
        $rejectedReceiptRejected = $_.Exception.Message.Contains(
            'durable AdapterHost provenance',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $rejectedReceiptRejected -or (Test-Path -LiteralPath $rejectedReceiptOutput)) {
        throw 'The AdapterHost probe accepted a rejected synthetic receipt or wrote passing evidence.'
    }

    $insecureOriginRejected = $false
    try {
        $token = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://127.0.0.1:65530') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -AdapterHostOrigin ([Uri]'http://adapter.example.test:8088') `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -ConnectionId $fixture.ConnectionId `
            -ExpectedAdapterType $fixture.AdapterType `
            -ExpectedWorkerId $fixture.WorkerId `
            -ExpectedExternalIdSha256 $fixture.ExternalIdHash `
            -ExpectedSourceRecordType $fixture.SourceRecordType `
            -StatusEndpointExposure Disabled `
            -OperatorAccessToken $token `
            -OutputPath (Join-Path $fixtureRoot 'insecure-origin.json') `
            -AllowLoopbackPublicHttp
    }
    catch {
        $insecureOriginRejected = $_.Exception.Message.Contains(
            'HTTPS, or HTTP on loopback',
            [StringComparison]::Ordinal)
    }
    if (-not $insecureOriginRejected) {
        throw 'The AdapterHost probe accepted insecure non-loopback HTTP.'
    }

    $remoteLoopbackStatusRejected = $false
    try {
        $token = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://127.0.0.1:65530') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -AdapterHostOrigin ([Uri]'https://adapter.example.test') `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -ConnectionId $fixture.ConnectionId `
            -ExpectedAdapterType $fixture.AdapterType `
            -ExpectedWorkerId $fixture.WorkerId `
            -ExpectedExternalIdSha256 $fixture.ExternalIdHash `
            -ExpectedSourceRecordType $fixture.SourceRecordType `
            -StatusEndpointExposure LoopbackOnly `
            -OperatorAccessToken $token `
            -OutputPath (Join-Path $fixtureRoot 'remote-loopback-status.json') `
            -AllowLoopbackPublicHttp
    }
    catch {
        $remoteLoopbackStatusRejected = $_.Exception.Message.Contains(
            'through a loopback AdapterHost origin',
            [StringComparison]::Ordinal)
    }
    if (-not $remoteLoopbackStatusRejected) {
        throw 'The AdapterHost probe accepted remote LoopbackOnly status exposure.'
    }

    Write-Host 'BunkFy deployed AdapterHost fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
