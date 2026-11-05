Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-ingestion-connection-lifecycle.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-ingestion-lifecycle-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$fixture = [pscustomobject]@{
    ReleaseId = 'release-ingestion-lifecycle-fixture-001'
    AdmissionEvidenceReference = 'admission:11111111111111111111111111111111'
    WorkspaceId = '11111111-1111-4111-8111-111111111111'
    PropertyId = '22222222-2222-4222-8222-222222222222'
    MembershipId = '33333333-3333-4333-8333-333333333333'
    SubjectId = '44444444-4444-4444-8444-444444444444'
    AdapterType = 'fixture.remote-adapter'
    ProtocolVersion = 7
    ConfigurationSchemaVersion = 3
    OperatorToken = 'fixture-ingestion-lifecycle-operator-token-do-not-retain'
    DeniedToken = 'fixture-ingestion-lifecycle-nonmember-token-do-not-retain'
    AdapterToken = 'fixture.ingress.credential-token-do-not-retain'
}

function Start-BunkFyIngestionLifecycleFixtureServer {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'credential-replay-token-drift')]
        [string] $Mode
    )

    $nonce = [Guid]::NewGuid().ToString('N')
    $readyPath = Join-Path $fixtureRoot "ready-$Mode-$nonce.txt"
    $capturePath = Join-Path $fixtureRoot "capture-$Mode-$nonce.json"
    $job = Start-Job -ScriptBlock {
        param($ReadyPath, $CapturePath, $Mode, $Fixture)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        function Write-FixtureResponse {
            param(
                [Parameter(Mandatory = $true)][IO.Stream] $Stream,
                [Parameter(Mandatory = $true)][int] $Status,
                [Parameter(Mandatory = $true)][string] $Reason,
                [Parameter(Mandatory = $true)][object] $Body
            )

            $json = if ($Body -is [string]) {
                [string]$Body
            }
            else {
                $Body | ConvertTo-Json -Depth 20 -Compress
            }
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
            $headers = @(
                "HTTP/1.1 $Status $Reason",
                'Connection: close',
                'Content-Type: application/json; charset=utf-8',
                "Content-Length: $($bytes.Length)",
                '',
                '')
            $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers -join "`r`n")
            $Stream.Write($headerBytes, 0, $headerBytes.Length)
            $Stream.Write($bytes, 0, $bytes.Length)
            $Stream.Flush()
        }

        function Write-FixtureProblem {
            param(
                [Parameter(Mandatory = $true)][IO.Stream] $Stream,
                [Parameter(Mandatory = $true)][string] $Code,
                [int] $Status = 409,
                [string] $Reason = 'Conflict'
            )

            Write-FixtureResponse `
                -Stream $Stream `
                -Status $Status `
                -Reason $Reason `
                -Body ([ordered]@{
                    type = 'about:blank'
                    title = $Code
                    status = $Status
                })
        }

        function Test-FixtureEnum {
            param(
                [AllowNull()][object] $Value,
                [Parameter(Mandatory = $true)][int] $NumericValue,
                [Parameter(Mandatory = $true)][string] $Name
            )

            $text = [string]$Value
            return $text -ceq [string]$NumericValue -or
                $text.Equals($Name, [StringComparison]::OrdinalIgnoreCase)
        }

        function Get-FixtureFingerprint {
            param([Parameter(Mandatory = $true)][object] $Body)

            return $Body | ConvertTo-Json -Depth 20 -Compress
        }

        function Add-FixtureOperationId {
            param([AllowNull()][string] $OperationId)

            if (-not [string]::IsNullOrWhiteSpace($OperationId) -and
                $OperationId -notin $script:operationIds) {
                $script:operationIds.Add($OperationId) | Out-Null
            }
        }

        function Write-Capture {
            $capture = [ordered]@{
                connectionId = $script:connectionId
                connectionStatus = $script:connectionStatus
                connectionVersion = $script:connectionVersion
                configurationReference = $script:configurationReference
                secretReference = $script:secretReference
                credentialId = $script:credentialId
                credentialStatus = $script:credentialStatus
                credentialVersion = $script:credentialVersion
                credentialLabel = $script:credentialLabel
                sourceSystem = $script:sourceSystem
                runId = $script:runId
                leaseId = $script:leaseId
                claimId = $script:claimId
                workerId = $script:workerId
                runStatus = $script:runStatus
                activeLease = $script:activeLease
                replayDriftEmitted = $script:replayDriftEmitted
                policyProjectionMisses = $script:policyProjectionMisses
                operationIds = @($script:operationIds)
                requestCount = $script:requestCount
                serverError = $script:serverError
            }
            [IO.File]::WriteAllText(
                $CapturePath,
                ($capture | ConvertTo-Json -Depth 8 -Compress),
                [Text.UTF8Encoding]::new($false))
        }

        function New-ConnectionReceipt {
            return [ordered]@{
                connectionId = $script:connectionId
                status = $script:connectionStatus
                version = $script:connectionVersion
            }
        }

        function New-ConnectionDetails {
            return [ordered]@{
                connectionId = $script:connectionId
                propertyId = $Fixture.PropertyId
                adapterType = $Fixture.AdapterType
                executionMode = 4
                pollingIntervalSeconds = $null
                pollingScheduleMaxAttempts = $null
                pollingScheduleConfiguredAtUtc = $null
                conflictPolicy = $script:conflictPolicy
                configurationReference = $script:configurationReference
                hasSecretReference = -not [string]::IsNullOrWhiteSpace($script:secretReference)
                checkpoint = $null
                status = $script:connectionStatus
                version = $script:connectionVersion
                createdAtUtc = '2026-08-13T00:00:00.1000000+00:00'
                updatedAtUtc = '2026-08-13T00:00:00.9000000+00:00'
            }
        }

        function New-ConnectionDirectory {
            $items = @()
            if ($null -ne $script:connectionId) {
                $items = @([ordered]@{
                    connectionId = $script:connectionId
                    adapterType = $Fixture.AdapterType
                    executionMode = 4
                    pollingIntervalSeconds = $null
                    conflictPolicy = $script:conflictPolicy
                    status = $script:connectionStatus
                })
            }
            return [ordered]@{
                connections = $items
                page = 1
                pageSize = 100
                hasMore = $false
            }
        }

        function New-ConnectionHealth {
            $operationalState = if ($script:connectionStatus -eq 2) {
                1
            }
            elseif ($null -ne $script:runId) {
                switch ($script:runStatus) {
                    1 { 3 }
                    2 { 4 }
                    5 { 7 }
                    default { 2 }
                }
            }
            else {
                2
            }
            return [ordered]@{
                connectionId = $script:connectionId
                propertyId = $Fixture.PropertyId
                adapterType = $Fixture.AdapterType
                connectionStatus = $script:connectionStatus
                executionMode = 4
                capabilityStatus = 1
                protocolVersion = $Fixture.ProtocolVersion
                configurationSchemaVersion = $Fixture.ConfigurationSchemaVersion
                pollingIntervalSeconds = $null
                pollingScheduleMaxAttempts = $null
                pollingScheduleConfiguredAtUtc = $null
                nextRunExpectedAtUtc = $null
                runExpected = $script:connectionStatus -eq 1
                operationalState = $operationalState
                latestRunId = $script:runId
                latestRunStatus = $script:runStatus
                latestRunStartedAtUtc = if ($null -ne $script:runId) { '2026-08-13T00:00:00.6000000+00:00' } else { $null }
                latestRunCompletedAtUtc = if ($script:runStatus -in @(2, 5)) { '2026-08-13T00:00:00.7000000+00:00' } else { $null }
                latestRunErrorCode = $null
                lastSuccessfulRunAtUtc = if ($script:runStatus -eq 2) { '2026-08-13T00:00:00.7000000+00:00' } else { $null }
                lastObservationReceivedAtUtc = $null
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
                evaluatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            }
        }

        function New-CredentialItem {
            return [ordered]@{
                credentialId = $script:credentialId
                slot = 1
                label = $script:credentialLabel
                status = $script:credentialStatus
                expiresAtUtc = $script:credentialExpiresAtUtc
                lastAuthenticatedAtUtc = $script:lastAuthenticatedAtUtc
                version = $script:credentialVersion
            }
        }

        function New-CredentialDetails {
            return [ordered]@{
                credentialId = $script:credentialId
                connectionId = $script:connectionId
                slot = 1
                label = $script:credentialLabel
                status = $script:credentialStatus
                expiresAtUtc = $script:credentialExpiresAtUtc
                createdBy = "user:$($Fixture.SubjectId)"
                createdAtUtc = '2026-08-13T00:00:00.5000000+00:00'
                revokedBy = if ($script:credentialStatus -eq 2) { "user:$($Fixture.SubjectId)" } else { $null }
                revokedAtUtc = if ($script:credentialStatus -eq 2) { '2026-08-13T00:00:00.8000000+00:00' } else { $null }
                lastAuthenticatedAtUtc = $script:lastAuthenticatedAtUtc
                version = $script:credentialVersion
                adapterType = $Fixture.AdapterType
                adapterProtocolVersion = $Fixture.ProtocolVersion
                configurationSchemaVersion = $Fixture.ConfigurationSchemaVersion
                sourceSystem = $script:sourceSystem
            }
        }

        function New-RunDetails {
            return [ordered]@{
                runId = $script:runId
                connectionId = $script:connectionId
                propertyId = $Fixture.PropertyId
                executionKind = 2
                taskRunId = $null
                taskAttempt = $null
                remoteLeaseId = $script:leaseId
                remoteClaimId = $script:claimId
                remoteLeaseEpoch = 1
                remoteWorkerId = $script:workerId
                remoteLeaseExpiresAtUtc = '2026-08-13T00:02:00.6000000+00:00'
                startingCheckpoint = $null
                acceptedCheckpoint = $null
                status = $script:runStatus
                observedCount = 0
                acceptedCount = 0
                rejectedCount = 0
                errorCode = $null
                version = if ($script:runStatus -eq 1) { 1 } else { 2 }
                startedAtUtc = '2026-08-13T00:00:00.6000000+00:00'
                completedAtUtc = if ($script:runStatus -in @(2, 5)) { '2026-08-13T00:00:00.7000000+00:00' } else { $null }
            }
        }

        function Test-OperatorRequest {
            param([Parameter(Mandatory = $true)][Collections.Hashtable] $Headers)

            return [string]$Headers['authorization'] -ceq "Bearer $($Fixture.OperatorToken)"
        }

        function Test-AdapterRequest {
            param([Parameter(Mandatory = $true)][Collections.Hashtable] $Headers)

            return [string]$Headers['authorization'] -ceq "BunkFy-Adapter $($Fixture.AdapterToken)" -and
                $script:credentialStatus -eq 1 -and
                $script:connectionStatus -eq 1
        }

        $script:connectionId = $null
        $script:connectionStatus = 0
        $script:connectionVersion = 0L
        $script:conflictPolicy = 0
        $script:configurationReference = $null
        $script:secretReference = $null
        $script:credentialId = $null
        $script:credentialStatus = 0
        $script:credentialVersion = 0L
        $script:credentialLabel = $null
        $script:credentialExpiresAtUtc = $null
        $script:sourceSystem = $null
        $script:lastAuthenticatedAtUtc = $null
        $script:runId = $null
        $script:leaseId = $null
        $script:claimId = $null
        $script:workerId = $null
        $script:runStatus = $null
        $script:activeLease = $false
        $script:replayDriftEmitted = $false
        $script:policyProjectionReady = $false
        $script:policyProjectionMisses = 0
        $script:operations = @{}
        $script:operationIds = [Collections.Generic.List[string]]::new()
        $script:requestCount = 0
        $script:serverError = $null
        $script:shutdownRequested = $false

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText(
                $ReadyPath,
                [string]$port,
                [Text.UTF8Encoding]::new($false))
            Write-Capture

            while (-not $script:shutdownRequested) {
                $tcp = $listener.AcceptTcpClient()
                try {
                    $stream = $tcp.GetStream()
                    $reader = [IO.StreamReader]::new(
                        $stream,
                        [Text.UTF8Encoding]::new($false),
                        $false,
                        4096,
                        $true)
                    try {
                        $requestLine = $reader.ReadLine()
                        if ([string]::IsNullOrWhiteSpace($requestLine)) {
                            continue
                        }
                        $parts = $requestLine.Split(' ')
                        if ($parts.Count -lt 2) {
                            throw "Invalid fixture request line '$requestLine'."
                        }
                        $method = $parts[0]
                        $target = $parts[1]
                        $path = ($target -split '\?')[0]
                        $headers = @{}
                        while (($line = $reader.ReadLine()) -ne '') {
                            $separator = $line.IndexOf(':')
                            if ($separator -gt 0) {
                                $headers[$line.Substring(0, $separator).Trim().ToLowerInvariant()] =
                                    $line.Substring($separator + 1).Trim()
                            }
                        }
                        $contentLength = if ($headers.ContainsKey('content-length')) {
                            [int]$headers['content-length']
                        }
                        else {
                            0
                        }
                        $bodyText = ''
                        if ($contentLength -gt 0) {
                            $buffer = [char[]]::new($contentLength)
                            $offset = 0
                            while ($offset -lt $contentLength) {
                                $read = $reader.Read($buffer, $offset, $contentLength - $offset)
                                if ($read -le 0) {
                                    throw 'Fixture request body ended early.'
                                }
                                $offset += $read
                            }
                            $bodyText = [string]::new($buffer)
                        }
                        $body = if ([string]::IsNullOrWhiteSpace($bodyText)) {
                            $null
                        }
                        else {
                            $bodyText | ConvertFrom-Json -Depth 20
                        }
                        $script:requestCount++

                        if ($method -eq 'GET' -and $path -ceq '/fixture-shutdown') {
                            $script:shutdownRequested = $true
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                status = 'stopping'
                            })
                            continue
                        }

                        if ($method -eq 'GET' -and $path -ceq '/api/smoke') {
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                application = 'BunkFy'
                                releaseId = $Fixture.ReleaseId
                                admissionEvidenceReference = $Fixture.AdmissionEvidenceReference
                                service = 'BunkFy.Host.Api'
                                status = 'ok'
                                timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                            })
                            continue
                        }

                        if ($path -like '/api/ingestion/adapter-ingress/connections/*') {
                            if (-not (Test-AdapterRequest -Headers $headers)) {
                                Write-FixtureProblem -Stream $stream -Code 'Unauthorized' -Status 401 -Reason 'Unauthorized'
                                continue
                            }

                            if ($method -eq 'POST' -and $path -like '*/remote-leases/claim') {
                                if ([Guid]$body.claimId -eq [Guid]::Empty -or
                                    [Guid]$body.workerId -eq [Guid]::Empty -or
                                    [string]$body.adapterType -cne $Fixture.AdapterType -or
                                    [int]$body.protocolVersion -ne $Fixture.ProtocolVersion -or
                                    [int]$body.configurationSchemaVersion -ne $Fixture.ConfigurationSchemaVersion) {
                                    Write-FixtureProblem -Stream $stream -Code 'Ingestion.RemoteLeaseDescriptorMismatch'
                                    continue
                                }
                                $script:runId = [Guid]::NewGuid().ToString('D')
                                $script:leaseId = [Guid]::NewGuid().ToString('D')
                                $script:claimId = [string]$body.claimId
                                $script:workerId = [string]$body.workerId
                                $script:runStatus = 1
                                $script:activeLease = $true
                                $script:connectionVersion++
                                $script:lastAuthenticatedAtUtc = '2026-08-13T00:00:00.6000000+00:00'
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    assignment = [ordered]@{
                                        runId = $script:runId
                                        leaseId = $script:leaseId
                                        connectionId = $script:connectionId
                                        scopeId = $Fixture.WorkspaceId
                                        propertyId = $Fixture.PropertyId
                                        adapterType = $Fixture.AdapterType
                                        executionMode = 1
                                        assignedAtUtc = '2026-08-13T00:00:00.6000000+00:00'
                                        leaseExpiresAtUtc = '2026-08-13T00:02:00.6000000+00:00'
                                        checkpoint = $null
                                    }
                                    leaseEpoch = 1
                                    renewAfterSeconds = 40
                                })
                                continue
                            }

                            if ($method -eq 'POST' -and $path -like '*/remote-leases/complete') {
                                if (-not $script:activeLease -or
                                    [Guid]$body.lease.runId -ne [Guid]$script:runId -or
                                    [Guid]$body.lease.leaseId -ne [Guid]$script:leaseId -or
                                    [Guid]$body.lease.workerId -ne [Guid]$script:workerId -or
                                    [long]$body.lease.leaseEpoch -ne 1) {
                                    Write-FixtureProblem -Stream $stream -Code 'Ingestion.RemoteLeaseMismatch'
                                    continue
                                }
                                $outcome = [int]$body.outcome
                                $script:runStatus = if ($outcome -eq 1) { 2 } else { 5 }
                                $script:activeLease = $false
                                $script:connectionVersion++
                                $script:lastAuthenticatedAtUtc = '2026-08-13T00:00:00.7000000+00:00'
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    runId = $script:runId
                                    leaseId = $script:leaseId
                                    leaseEpoch = 1
                                    outcome = $outcome
                                    acceptedCheckpoint = $null
                                    completedAtUtc = '2026-08-13T00:00:00.7000000+00:00'
                                })
                                continue
                            }

                            Write-FixtureProblem -Stream $stream -Code 'Fixture.RouteNotFound' -Status 404 -Reason 'Not Found'
                            continue
                        }

                        $authorization = [string]$headers['authorization']
                        if ($authorization -ceq "Bearer $($Fixture.DeniedToken)" -and
                            $path -match '/api/ingestion/properties/.+/connections') {
                            Write-FixtureProblem -Stream $stream -Code 'Forbidden' -Status 403 -Reason 'Forbidden'
                            continue
                        }
                        if (-not (Test-OperatorRequest -Headers $headers)) {
                            Write-FixtureProblem -Stream $stream -Code 'Unauthorized' -Status 401 -Reason 'Unauthorized'
                            continue
                        }

                        if ($method -eq 'GET' -and $path -ceq '/api/organizations') {
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                items = @([ordered]@{
                                    organization = [ordered]@{
                                        organizationId = $Fixture.WorkspaceId
                                        scopeId = $Fixture.WorkspaceId
                                        name = 'Fixture workspace'
                                        slug = 'fixture-workspace'
                                    }
                                    membership = [ordered]@{
                                        membershipId = $Fixture.MembershipId
                                        subjectId = $Fixture.SubjectId
                                        role = 'owner'
                                        status = 'active'
                                        version = 1
                                    }
                                })
                                page = 1
                                pageSize = 100
                                hasMore = $false
                            })
                            continue
                        }

                        if ($method -eq 'GET' -and $path -ceq "/api/properties/$($Fixture.PropertyId)") {
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                propertyId = $Fixture.PropertyId
                                name = 'Fixture property'
                                code = 'fixture-property'
                                timeZoneId = 'UTC'
                                status = 1
                                processingStatus = 2
                                version = 2
                                createdAtUtc = '2026-08-13T00:00:00.0000000+00:00'
                                lastChangedAtUtc = '2026-08-13T00:00:00.0000000+00:00'
                                retiredAtUtc = $null
                            })
                            continue
                        }

                        if ($method -eq 'GET' -and $path -ceq "/api/properties/$($Fixture.PropertyId)/processing") {
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                propertyId = $Fixture.PropertyId
                                configuredStatus = 2
                                effectiveStatus = 2
                                reasonCode = 'Properties.CountryPolicy.Allowed'
                                propertyVersion = 2
                                governancePolicy = [ordered]@{
                                    operatingCountryCode = 'ZZ'
                                    policyId = 'fixture-policy-do-not-retain'
                                    policyVersion = 1
                                    dataRegionId = 'fixture-region-do-not-retain'
                                    transferProfileId = 'fixture-transfer-do-not-retain'
                                    retentionPolicyId = 'fixture-retention-do-not-retain'
                                    retentionPolicyVersion = 1
                                    contentSha256 = ('a' * 64)
                                    acknowledgements = @()
                                }
                            })
                            continue
                        }

                        if ($method -eq 'GET' -and $path -ceq "/api/ingestion/properties/$($Fixture.PropertyId)/adapter-types") {
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                adapterTypes = @([ordered]@{
                                    adapterType = $Fixture.AdapterType
                                    protocolVersion = $Fixture.ProtocolVersion
                                    configurationSchemaVersion = $Fixture.ConfigurationSchemaVersion
                                    executionModes = @(1, 4)
                                    minimumPollingIntervalSeconds = 60
                                    recommendedPollingIntervalSeconds = 300
                                })
                            })
                            continue
                        }

                        $connectionsBase = "/api/ingestion/properties/$($Fixture.PropertyId)/connections"
                        if ($method -eq 'POST' -and $path -ceq $connectionsBase) {
                            if (-not $script:policyProjectionReady) {
                                $script:policyProjectionReady = $true
                                $script:policyProjectionMisses++
                                Write-FixtureProblem `
                                    -Stream $stream `
                                    -Code 'Ingestion.CountryPolicyDenied.MissingBinding'
                                continue
                            }
                            $operationId = ([Guid]$body.operationId).ToString('D')
                            Add-FixtureOperationId -OperationId $operationId
                            $fingerprint = Get-FixtureFingerprint -Body $body
                            if ($script:operations.ContainsKey($operationId)) {
                                $record = $script:operations[$operationId]
                                if ($record.Kind -cne 'connection-create' -or $record.Fingerprint -cne $fingerprint) {
                                    Write-FixtureProblem -Stream $stream -Code 'Ingestion.ConnectionManagementOperationConflict'
                                }
                                else {
                                    Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionReceipt)
                                }
                                continue
                            }
                            $script:connectionId = $operationId
                            $script:connectionStatus = 1
                            $script:connectionVersion = 1
                            $script:conflictPolicy = [int]$body.conflictPolicy
                            $script:configurationReference = [string]$body.configurationReference
                            $script:secretReference = $null
                            $script:operations[$operationId] = [pscustomobject]@{
                                Kind = 'connection-create'
                                Fingerprint = $fingerprint
                            }
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionReceipt)
                            continue
                        }

                        if ($method -eq 'GET' -and $path -ceq $connectionsBase) {
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionDirectory)
                            continue
                        }

                        if ($null -ne $script:connectionId) {
                            $connectionPath = "$connectionsBase/$($script:connectionId)"
                            if ($method -eq 'GET' -and $path -ceq $connectionPath) {
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionDetails)
                                continue
                            }
                            if ($method -eq 'GET' -and $path -ceq "$connectionPath/health") {
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionHealth)
                                continue
                            }
                            if ($method -eq 'PUT' -and $path -ceq $connectionPath) {
                                $operationId = ([Guid]$body.operationId).ToString('D')
                                Add-FixtureOperationId -OperationId $operationId
                                $fingerprint = Get-FixtureFingerprint -Body $body
                                if ($script:operations.ContainsKey($operationId)) {
                                    $record = $script:operations[$operationId]
                                    if ($record.Kind -cne 'connection-update' -or $record.Fingerprint -cne $fingerprint) {
                                        Write-FixtureProblem -Stream $stream -Code 'Ingestion.ConnectionManagementOperationConflict'
                                    }
                                    else {
                                        Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionReceipt)
                                    }
                                    continue
                                }
                                if ([long]$body.expectedVersion -ne $script:connectionVersion) {
                                    Write-FixtureProblem -Stream $stream -Code 'Ingestion.VersionConflict'
                                    continue
                                }
                                if ([bool]$body.clearSecretReference -and
                                    $null -ne $body.secretReference) {
                                    Write-FixtureProblem `
                                        -Stream $stream `
                                        -Code 'Ingestion.SecretReferenceUpdateInvalid' `
                                        -Status 400 `
                                        -Reason 'Bad Request'
                                    continue
                                }
                                $script:conflictPolicy = [int]$body.conflictPolicy
                                $script:configurationReference = [string]$body.configurationReference
                                if ([bool]$body.clearSecretReference) {
                                    $script:secretReference = $null
                                }
                                elseif ($null -ne $body.secretReference) {
                                    $script:secretReference = [string]$body.secretReference
                                }
                                $script:connectionVersion++
                                $script:operations[$operationId] = [pscustomobject]@{
                                    Kind = 'connection-update'
                                    Fingerprint = $fingerprint
                                }
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionReceipt)
                                continue
                            }

                            if ($method -eq 'POST' -and $path -match '/(enable|disable)$') {
                                $control = if ($path.EndsWith('/enable', [StringComparison]::Ordinal)) { 'enable' } else { 'disable' }
                                $operationId = ([Guid]$body.operationId).ToString('D')
                                Add-FixtureOperationId -OperationId $operationId
                                $fingerprint = Get-FixtureFingerprint -Body $body
                                $kind = "connection-$control"
                                if ($script:operations.ContainsKey($operationId)) {
                                    $record = $script:operations[$operationId]
                                    if ($record.Kind -cne $kind -or $record.Fingerprint -cne $fingerprint) {
                                        Write-FixtureProblem -Stream $stream -Code 'Ingestion.ConnectionManagementOperationConflict'
                                    }
                                    else {
                                        Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionReceipt)
                                    }
                                    continue
                                }
                                if ([long]$body.expectedVersion -ne $script:connectionVersion) {
                                    Write-FixtureProblem -Stream $stream -Code 'Ingestion.VersionConflict'
                                    continue
                                }
                                $script:connectionStatus = if ($control -ceq 'enable') { 1 } else { 2 }
                                $script:connectionVersion++
                                $script:operations[$operationId] = [pscustomobject]@{
                                    Kind = $kind
                                    Fingerprint = $fingerprint
                                }
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionReceipt)
                                continue
                            }

                            $credentialsPath = "$connectionPath/credentials"
                            if ($method -eq 'POST' -and $path -ceq $credentialsPath) {
                                $operationId = ([Guid]$body.operationId).ToString('D')
                                Add-FixtureOperationId -OperationId $operationId
                                $fingerprint = Get-FixtureFingerprint -Body $body
                                if ($script:operations.ContainsKey($operationId)) {
                                    $record = $script:operations[$operationId]
                                    if ($record.Kind -cne 'credential-create' -or $record.Fingerprint -cne $fingerprint) {
                                        Write-FixtureProblem -Stream $stream -Code 'Ingestion.ConnectionManagementOperationConflict'
                                    }
                                    else {
                                        $replayToken = if ($Mode -ceq 'credential-replay-token-drift') {
                                            $script:replayDriftEmitted = $true
                                            $Fixture.AdapterToken
                                        }
                                        else {
                                            $null
                                        }
                                        Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                            credential = New-CredentialDetails
                                            outcome = 2
                                            token = $replayToken
                                        })
                                    }
                                    continue
                                }
                                $script:credentialId = $operationId
                                $script:credentialStatus = 1
                                $script:credentialVersion = 1
                                $script:credentialLabel = [string]$body.label
                                $script:credentialExpiresAtUtc = [string]$body.expiresAtUtc
                                $script:sourceSystem = [string]$body.sourceSystem
                                $script:operations[$operationId] = [pscustomobject]@{
                                    Kind = 'credential-create'
                                    Fingerprint = $fingerprint
                                }
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    credential = New-CredentialDetails
                                    outcome = 1
                                    token = $Fixture.AdapterToken
                                })
                                continue
                            }

                            if ($method -eq 'GET' -and $path -ceq $credentialsPath) {
                                $items = if ($null -eq $script:credentialId) { @() } else { @(New-CredentialItem) }
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    credentials = $items
                                    page = 1
                                    pageSize = 100
                                    hasMore = $false
                                })
                                continue
                            }

                            if ($null -ne $script:credentialId -and
                                $method -eq 'POST' -and
                                $path -ceq "$credentialsPath/$($script:credentialId)/revoke") {
                                $operationId = ([Guid]$body.operationId).ToString('D')
                                Add-FixtureOperationId -OperationId $operationId
                                $fingerprint = Get-FixtureFingerprint -Body $body
                                if ($script:operations.ContainsKey($operationId)) {
                                    $record = $script:operations[$operationId]
                                    if ($record.Kind -cne 'credential-revoke' -or $record.Fingerprint -cne $fingerprint) {
                                        Write-FixtureProblem -Stream $stream -Code 'Ingestion.ConnectionManagementOperationConflict'
                                    }
                                    else {
                                        Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                            credentialId = $script:credentialId
                                            connectionId = $script:connectionId
                                            status = $script:credentialStatus
                                            version = $script:credentialVersion
                                        })
                                    }
                                    continue
                                }
                                if ([long]$body.expectedVersion -ne $script:credentialVersion) {
                                    Write-FixtureProblem -Stream $stream -Code 'Ingestion.VersionConflict'
                                    continue
                                }
                                $script:credentialStatus = 2
                                $script:credentialVersion++
                                $script:operations[$operationId] = [pscustomobject]@{
                                    Kind = 'credential-revoke'
                                    Fingerprint = $fingerprint
                                }
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    credentialId = $script:credentialId
                                    connectionId = $script:connectionId
                                    status = $script:credentialStatus
                                    version = $script:credentialVersion
                                })
                                continue
                            }
                        }

                        if ($null -ne $script:runId -and
                            $method -eq 'GET' -and
                            $path -ceq "/api/ingestion/properties/$($Fixture.PropertyId)/runs/$($script:runId)") {
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-RunDetails)
                            continue
                        }

                        Write-FixtureProblem -Stream $stream -Code 'Fixture.RouteNotFound' -Status 404 -Reason 'Not Found'
                    }
                    catch {
                        $script:serverError = $_.Exception.Message
                        try {
                            Write-FixtureProblem -Stream $stream -Code 'Fixture.ServerError' -Status 500 -Reason 'Internal Server Error'
                        }
                        catch {
                        }
                    }
                    finally {
                        Write-Capture
                        $reader.Dispose()
                    }
                }
                finally {
                    $tcp.Dispose()
                }
            }
        }
        finally {
            Write-Capture
            $listener.Stop()
        }
    } -ArgumentList $readyPath, $capturePath, $Mode, $fixture

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        if ($job.State -in @('Failed', 'Completed', 'Stopped')) {
            $details = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue | Out-String
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            throw "The Ingestion lifecycle fixture server stopped before readiness. $details"
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            throw 'The Ingestion lifecycle fixture server did not become ready.'
        }
        Start-Sleep -Milliseconds 50
    }

    $port = [int](Get-Content -LiteralPath $readyPath -Raw)
    return [pscustomobject]@{
        Job = $job
        Origin = [Uri]"http://127.0.0.1:$port"
        CapturePath = $capturePath
    }
}

function Stop-BunkFyIngestionLifecycleFixtureServer {
    param([AllowNull()][object] $Server)

    if ($null -eq $Server) {
        return
    }
    $shutdownClient = [Net.Http.HttpClient]::new()
    $shutdownClient.Timeout = [TimeSpan]::FromSeconds(2)
    try {
        [void]$shutdownClient.GetAsync(
            [Uri]::new($Server.Origin, '/fixture-shutdown')).GetAwaiter().GetResult()
    }
    catch {
    }
    finally {
        $shutdownClient.Dispose()
    }
    [void](Wait-Job -Job $Server.Job -Timeout 5 -ErrorAction SilentlyContinue)
    if ($Server.Job.State -notin @('Completed', 'Failed', 'Stopped')) {
        Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
    }
    [void](Receive-Job -Job $Server.Job -ErrorAction SilentlyContinue)
    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
}

function Invoke-BunkFyIngestionLifecycleFixtureProbe {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'credential-replay-token-drift')]
        [string] $Mode,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $server = Start-BunkFyIngestionLifecycleFixtureServer -Mode $Mode
    $probeError = $null
    try {
        $operatorToken = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        $deniedToken = ConvertTo-SecureString $fixture.DeniedToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin $server.Origin `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -OperatorAccessToken $operatorToken `
            -DeniedAccessToken $deniedToken `
            -RequestTimeoutSeconds 5 `
            -ConvergenceTimeoutSeconds 10 `
            -PollIntervalMilliseconds 250 `
            -OutputPath $OutputPath `
            -AllowLoopbackHttp `
            -Force `
            -Confirm:$false
    }
    catch {
        $probeError = $_
    }
    finally {
        Start-Sleep -Milliseconds 100
        Stop-BunkFyIngestionLifecycleFixtureServer -Server $server
    }

    $capture = if (Test-Path -LiteralPath $server.CapturePath -PathType Leaf) {
        Get-Content -LiteralPath $server.CapturePath -Raw | ConvertFrom-Json -Depth 8
    }
    else {
        $null
    }
    if ($null -ne $probeError) {
        $probeError.Exception.Data['FixtureCapture'] = $capture
        throw $probeError
    }
    return $capture
}

try {
    $validOutput = Join-Path $fixtureRoot 'valid-evidence.json'
    $capture = Invoke-BunkFyIngestionLifecycleFixtureProbe -Mode valid -OutputPath $validOutput
    if ($null -eq $capture -or
        -not [string]::IsNullOrWhiteSpace([string]$capture.serverError) -or
        [int]$capture.connectionStatus -ne 2 -or
        [long]$capture.connectionVersion -ne 8 -or
        $null -ne $capture.secretReference -or
        [int]$capture.credentialStatus -ne 2 -or
        [long]$capture.credentialVersion -ne 2 -or
        [int]$capture.runStatus -ne 2 -or
        [bool]$capture.activeLease -or
        [int]$capture.policyProjectionMisses -ne 1 -or
        [bool]$capture.replayDriftEmitted) {
        throw 'The valid Ingestion lifecycle fixture did not reach the expected terminal state.'
    }

    $evidence = Get-Content -LiteralPath $validOutput -Raw | ConvertFrom-Json -Depth 12
    if ($evidence.schemaVersion -ne 2 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-ingestion-connection-lifecycle-probe' -or
        $evidence.result -cne 'passed' -or
        $evidence.releaseId -cne $fixture.ReleaseId -or
        $evidence.admissionEvidenceReference -cne $fixture.AdmissionEvidenceReference -or
        $evidence.workflow.executionMode -cne 'remote-polling' -or
        [int]$evidence.workflow.protocolVersion -ne $fixture.ProtocolVersion -or
        [int]$evidence.workflow.configurationSchemaVersion -ne $fixture.ConfigurationSchemaVersion -or
        $evidence.workflow.connectionFinalStatus -cne 'disabled' -or
        -not [bool]$evidence.workflow.connectionVersionAdvanced -or
        $evidence.workflow.secretReferenceLifecycle -cne 'set-then-cleared' -or
        $evidence.workflow.credentialFinalStatus -cne 'revoked' -or
        -not [bool]$evidence.workflow.credentialVersionAdvanced -or
        $evidence.workflow.credentialIssuance -cne 'one-time-nonredisclosing' -or
        $evidence.workflow.independentAuthentication -cne 'issued-accepted-then-revoked-denied' -or
        $evidence.workflow.runFinalStatus -cne 'succeeded' -or
        [int]$evidence.workflow.runObservedCount -ne 0 -or
        [bool]$evidence.workflow.activeLease -or
        $evidence.cleanup.connectionDisposition -cne 'synthetic-disabled-retained' -or
        $evidence.cleanup.credentialDisposition -cne 'synthetic-revoked-retained' -or
        $evidence.cleanup.runDisposition -cne 'synthetic-succeeded-empty-retained' -or
        -not [bool]$evidence.cleanup.parentPropertyLifecycleOwnedByCaller -or
        @($evidence.checks).Count -ne 32 -or
        @($evidence.limitations).Count -ne 4) {
        throw 'The valid Ingestion lifecycle fixture produced invalid evidence.'
    }

    $evidenceText = Get-Content -LiteralPath $validOutput -Raw
    $sensitiveValues = [Collections.Generic.List[string]]::new()
    foreach ($value in @(
            $fixture.WorkspaceId,
            $fixture.PropertyId,
            $fixture.MembershipId,
            $fixture.SubjectId,
            $fixture.AdapterType,
            $fixture.OperatorToken,
            $fixture.DeniedToken,
            $fixture.AdapterToken,
            [string]$capture.connectionId,
            [string]$capture.configurationReference,
            [string]$capture.credentialId,
            [string]$capture.credentialLabel,
            [string]$capture.sourceSystem,
            [string]$capture.runId,
            [string]$capture.leaseId,
            [string]$capture.claimId,
            [string]$capture.workerId,
            'fixture-policy-do-not-retain',
            'fixture-region-do-not-retain',
            'fixture-transfer-do-not-retain',
            'fixture-retention-do-not-retain',
            'Authorization',
            'X-Tenant-Id')) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $sensitiveValues.Add($value) | Out-Null
        }
    }
    foreach ($operationId in @($capture.operationIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$operationId)) {
            $sensitiveValues.Add([string]$operationId) | Out-Null
        }
    }
    foreach ($sensitive in $sensitiveValues) {
        if ($evidenceText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Ingestion lifecycle evidence retained scoped, adapter, credential, operation, or policy data.'
        }
    }

    if (-not $IsWindows) {
        $mode = [IO.File]::GetUnixFileMode($validOutput)
        $expectedMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        if ($mode -ne $expectedMode) {
            throw "Ingestion lifecycle evidence mode '$mode' is not private 0600."
        }
    }

    $driftOutput = Join-Path $fixtureRoot 'credential-replay-token-drift-evidence.json'
    $driftRejected = $false
    $driftCapture = $null
    try {
        [void](Invoke-BunkFyIngestionLifecycleFixtureProbe `
                -Mode credential-replay-token-drift `
                -OutputPath $driftOutput)
    }
    catch {
        $driftRejected = $_.Exception.Message.Contains(
            'redisclosed',
            [StringComparison]::OrdinalIgnoreCase)
        $driftCapture = $_.Exception.Data['FixtureCapture']
    }
    if (-not $driftRejected -or
        (Test-Path -LiteralPath $driftOutput) -or
        $null -eq $driftCapture -or
        -not [bool]$driftCapture.replayDriftEmitted -or
        [int]$driftCapture.connectionStatus -ne 2 -or
        [int]$driftCapture.credentialStatus -ne 2 -or
        [bool]$driftCapture.activeLease) {
        throw 'The Ingestion lifecycle probe accepted credential replay drift, wrote passing evidence, or failed terminal cleanup.'
    }

    $insecureOriginRejected = $false
    try {
        $operatorToken = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        $deniedToken = ConvertTo-SecureString $fixture.DeniedToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://ingestion.example.test:8080') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -OperatorAccessToken $operatorToken `
            -DeniedAccessToken $deniedToken `
            -OutputPath (Join-Path $fixtureRoot 'insecure-origin.json') `
            -Confirm:$false
    }
    catch {
        $insecureOriginRejected = $_.Exception.Message.Contains(
            'must use HTTPS',
            [StringComparison]::Ordinal)
    }
    if (-not $insecureOriginRejected) {
        throw 'The Ingestion lifecycle probe accepted insecure non-loopback HTTP.'
    }

    Write-Host 'BunkFy deployed Ingestion connection lifecycle fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
