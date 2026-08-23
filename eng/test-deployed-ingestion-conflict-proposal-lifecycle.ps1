Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-ingestion-conflict-proposal-lifecycle.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-ingestion-proposal-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$fixture = [pscustomobject]@{
    ReleaseId = 'release-ingestion-proposal-fixture-001'
    AdmissionEvidenceReference = 'admission:11111111111111111111111111111111'
    WorkspaceId = '11111111-1111-4111-8111-111111111111'
    PropertyId = '22222222-2222-4222-8222-222222222222'
    InventoryUnitId = '33333333-3333-4333-8333-333333333333'
    MembershipId = '44444444-4444-4444-8444-444444444444'
    SubjectId = '55555555-5555-4555-8555-555555555555'
    AdapterType = 'fixture.push-adapter'
    ProtocolVersion = 7
    ConfigurationSchemaVersion = 3
    OperatorToken = 'fixture-ingestion-proposal-operator-token-do-not-retain'
    DeniedToken = 'fixture-ingestion-proposal-nonmember-token-do-not-retain'
    AdapterToken = 'fixture.ingestion.proposal.credential-token-do-not-retain'
}

function Start-BunkFyIngestionProposalFixtureServer {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'supersession-drift')]
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
                $Body | ConvertTo-Json -Depth 24 -Compress
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
                executionMode = 3
                conflictPolicy = 2
                configurationReference = $script:configurationReference
                hasSecretReference = $false
                status = $script:connectionStatus
                version = $script:connectionVersion
                createdAtUtc = '2026-08-13T00:00:00.1000000+00:00'
                updatedAtUtc = '2026-08-13T00:00:00.9000000+00:00'
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
                createdAtUtc = '2026-08-13T00:00:00.2000000+00:00'
                revokedBy = if ($script:credentialStatus -eq 2) { "user:$($Fixture.SubjectId)" } else { $null }
                revokedAtUtc = if ($script:credentialStatus -eq 2) { '2026-08-13T00:00:00.9000000+00:00' } else { $null }
                lastAuthenticatedAtUtc = $script:lastAuthenticatedAtUtc
                version = $script:credentialVersion
                adapterType = $Fixture.AdapterType
                adapterProtocolVersion = $Fixture.ProtocolVersion
                configurationSchemaVersion = $Fixture.ConfigurationSchemaVersion
                sourceSystem = $script:sourceSystem
            }
        }

        function New-ReservationDetails {
            return [ordered]@{
                reservationId = $script:reservationId
                propertyId = $Fixture.PropertyId
                status = $script:reservationStatus
                primaryGuestName = $script:reservationGuestName
                email = $null
                phone = $null
                guestCount = 1
                notes = $script:reservationNotes
                arrival = '2027-10-20'
                departure = '2027-10-22'
                expectedArrivalTime = '15:00:00'
                expectedDepartureTime = '11:00:00'
                detailsRevision = $script:reservationDetailsRevision
                lastDetailsChangeOrigin = $script:reservationOrigin
                version = $script:reservationVersion
            }
        }

        function New-ProposalDetails {
            param([Parameter(Mandatory = $true)][object] $Proposal)

            return [ordered]@{
                proposalId = $Proposal.ProposalId
                connectionId = $script:connectionId
                receiptId = $Proposal.ReceiptId
                reservationId = $script:reservationId
                status = $Proposal.Status
                version = $Proposal.Version
                baseReservationDetailsRevision = 2
                reasonCode = 'reservation-details-revision-conflict'
                proposedChangesJson = $Proposal.GuestName
                decisionActor = $Proposal.DecisionActor
                decisionReason = $Proposal.DecisionReason
                sensitiveDataRetainUntilUtc = $Proposal.SensitiveDataRetainUntilUtc
                productOperationId = $Proposal.ProductOperationId
                createdAtUtc = $Proposal.CreatedAtUtc
                decidedAtUtc = $Proposal.DecidedAtUtc
            }
        }

        function Add-Proposal {
            param(
                [Parameter(Mandatory = $true)][string] $ReceiptId,
                [Parameter(Mandatory = $true)][string] $GuestName
            )

            $proposalId = [Guid]::NewGuid().ToString('D')
            $proposal = [pscustomobject]@{
                ProposalId = $proposalId
                ReceiptId = $ReceiptId
                GuestName = $GuestName
                Status = 1
                Version = 1L
                DecisionActor = $null
                DecisionReason = $null
                SensitiveDataRetainUntilUtc = $null
                ProductOperationId = $null
                CreatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                DecidedAtUtc = $null
                DecisionKind = $null
                DecisionRequestVersion = $null
                DecisionReservationRevision = $null
            }
            $script:proposals[$proposalId] = $proposal
            $script:proposalOrder.Add($proposalId) | Out-Null
            return $proposal
        }

        function Get-ProposalStatusCounts {
            $counts = [ordered]@{
                pending = 0
                applied = 0
                rejected = 0
                superseded = 0
            }
            foreach ($proposalId in $script:proposalOrder) {
                switch ([int]$script:proposals[$proposalId].Status) {
                    1 { $counts.pending++ }
                    3 { $counts.applied++ }
                    4 { $counts.rejected++ }
                    5 { $counts.superseded++ }
                }
            }
            return $counts
        }

        function Write-Capture {
            $proposalCounts = Get-ProposalStatusCounts
            $capture = [ordered]@{
                connectionId = $script:connectionId
                connectionStatus = $script:connectionStatus
                connectionVersion = $script:connectionVersion
                configurationReference = $script:configurationReference
                credentialId = $script:credentialId
                credentialStatus = $script:credentialStatus
                credentialVersion = $script:credentialVersion
                credentialLabel = $script:credentialLabel
                sourceSystem = $script:sourceSystem
                reservationId = $script:reservationId
                reservationStatus = $script:reservationStatus
                reservationDetailsRevision = $script:reservationDetailsRevision
                reservationGuestName = $script:reservationGuestName
                proposalTotal = $script:proposalOrder.Count
                proposalPending = $proposalCounts.pending
                proposalApplied = $proposalCounts.applied
                proposalRejected = $proposalCounts.rejected
                proposalSuperseded = $proposalCounts.superseded
                supersessionDriftEmitted = $script:supersessionDriftEmitted
                policyProjectionMisses = $script:policyProjectionMisses
                requestCount = $script:requestCount
                serverError = $script:serverError
            }
            [IO.File]::WriteAllText(
                $CapturePath,
                ($capture | ConvertTo-Json -Depth 8 -Compress),
                [Text.UTF8Encoding]::new($false))
        }

        function Add-HistoryRevision {
            param(
                [Parameter(Mandatory = $true)][long] $Revision,
                [Parameter(Mandatory = $true)][int] $Origin
            )

            $script:history.Add([ordered]@{
                    fromRevision = $Revision - 1
                    toRevision = $Revision
                    origin = $Origin
                    changedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                }) | Out-Null
        }

        function Process-Observation {
            param([Parameter(Mandatory = $true)][object] $Body)

            $records = @($Body.records)
            if ($records.Count -ne 1) {
                throw 'Fixture observations must contain exactly one record.'
            }
            $record = $records[0]
            $operationId = ([Guid]$record.operationId).ToString('D')
            if ($script:observationReceipts.ContainsKey($operationId)) {
                return [ordered]@{
                    operationId = $operationId
                    receiptId = $script:observationReceipts[$operationId]
                    disposition = 2
                }
            }

            $payloadBytes = [Convert]::FromBase64String([string]$record.payload)
            try {
                $payload = [Text.UTF8Encoding]::new($false).GetString($payloadBytes) |
                    ConvertFrom-Json -Depth 12
            }
            finally {
                [Array]::Clear($payloadBytes, 0, $payloadBytes.Length)
            }
            $receiptId = [Guid]::NewGuid().ToString('D')
            $script:observationReceipts[$operationId] = $receiptId
            $script:receipts[$receiptId] = [pscustomobject]@{
                ReceiptId = $receiptId
                Status = 2
                RejectionReason = $null
            }
            $script:lastAuthenticatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')

            $sequence = [long]$payload.sourceSequence
            if ($sequence -eq 1) {
                $script:reservationId = [Guid]::NewGuid().ToString('D')
                $script:reservationStatus = 2
                $script:reservationDetailsRevision = 1L
                $script:reservationOrigin = 2
                $script:reservationGuestName = [string]$payload.primaryGuestName
                $script:reservationNotes = $null
                $script:reservationVersion = 1L
                Add-HistoryRevision -Revision 1 -Origin 2
            }
            elseif ($sequence -eq 2) {
                $script:reservationDetailsRevision = 2L
                $script:reservationOrigin = 2
                $script:reservationGuestName = [string]$payload.primaryGuestName
                $script:reservationVersion++
                Add-HistoryRevision -Revision 2 -Origin 2
            }
            elseif ($sequence -eq 3) {
                [void](Add-Proposal -ReceiptId $receiptId -GuestName ([string]$payload.primaryGuestName))
            }
            elseif ($sequence -eq 4) {
                $pending = @($script:proposalOrder | ForEach-Object { $script:proposals[$_] } | Where-Object {
                        [int]$_.Status -eq 1
                    })
                if ($Mode -ceq 'valid') {
                    foreach ($proposal in $pending) {
                        $proposal.Status = 5
                        $proposal.Version++
                        $proposal.DecisionActor = 'system'
                        $proposal.DecisionReason = 'A newer source observation replaced this proposal.'
                        $proposal.SensitiveDataRetainUntilUtc = [DateTimeOffset]::UtcNow.AddDays(30).ToString('O')
                        $proposal.DecidedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                    }
                }
                else {
                    $script:supersessionDriftEmitted = $true
                }
                [void](Add-Proposal -ReceiptId $receiptId -GuestName ([string]$payload.primaryGuestName))
            }
            elseif ($sequence -eq 5) {
                [void](Add-Proposal -ReceiptId $receiptId -GuestName ([string]$payload.primaryGuestName))
            }
            elseif ($sequence -eq 6) {
                $script:reservationStatus = 5
                $script:reservationVersion++
            }

            return [ordered]@{
                operationId = $operationId
                receiptId = $receiptId
                disposition = 1
            }
        }

        $script:connectionId = $null
        $script:connectionStatus = 0
        $script:connectionVersion = 0L
        $script:configurationReference = $null
        $script:credentialId = $null
        $script:credentialStatus = 0
        $script:credentialVersion = 0L
        $script:credentialLabel = $null
        $script:credentialExpiresAtUtc = $null
        $script:sourceSystem = $null
        $script:lastAuthenticatedAtUtc = $null
        $script:reservationId = $null
        $script:reservationStatus = 0
        $script:reservationDetailsRevision = 0L
        $script:reservationOrigin = 0
        $script:reservationGuestName = $null
        $script:reservationNotes = $null
        $script:reservationVersion = 0L
        $script:proposals = @{}
        $script:proposalOrder = [Collections.Generic.List[string]]::new()
        $script:receipts = @{}
        $script:observationReceipts = @{}
        $script:history = [Collections.Generic.List[object]]::new()
        $script:policyProjectionReady = $false
        $script:policyProjectionMisses = 0
        $script:supersessionDriftEmitted = $false
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
                            $bodyText | ConvertFrom-Json -Depth 24
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
                            if ($method -eq 'POST' -and $path -like '*/observations') {
                                $result = Process-Observation -Body $body
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    results = @($result)
                                })
                                continue
                            }
                            Write-FixtureProblem -Stream $stream -Code 'Fixture.RouteNotFound' -Status 404 -Reason 'Not Found'
                            continue
                        }

                        $authorization = [string]$headers['authorization']
                        if ($authorization -ceq "Bearer $($Fixture.DeniedToken)" -and
                            $path -match '/api/ingestion/properties/.+/proposals') {
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
                                    executionModes = @(3)
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
                            if ($null -eq $script:connectionId) {
                                $script:connectionId = ([Guid]$body.operationId).ToString('D')
                                $script:connectionStatus = 1
                                $script:connectionVersion = 1L
                                $script:configurationReference = [string]$body.configurationReference
                            }
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionReceipt)
                            continue
                        }

                        if ($null -ne $script:connectionId) {
                            $connectionPath = "$connectionsBase/$($script:connectionId)"
                            if ($method -eq 'GET' -and $path -ceq $connectionPath) {
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionDetails)
                                continue
                            }
                            if ($method -eq 'POST' -and $path -ceq "$connectionPath/disable") {
                                if ([long]$body.expectedVersion -ne $script:connectionVersion) {
                                    Write-FixtureProblem -Stream $stream -Code 'Ingestion.VersionConflict'
                                    continue
                                }
                                $script:connectionStatus = 2
                                $script:connectionVersion++
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ConnectionReceipt)
                                continue
                            }

                            $credentialsPath = "$connectionPath/credentials"
                            if ($method -eq 'POST' -and $path -ceq $credentialsPath) {
                                if ($null -eq $script:credentialId) {
                                    $script:credentialId = ([Guid]$body.operationId).ToString('D')
                                    $script:credentialStatus = 1
                                    $script:credentialVersion = 1L
                                    $script:credentialLabel = [string]$body.label
                                    $script:credentialExpiresAtUtc = [string]$body.expiresAtUtc
                                    $script:sourceSystem = [string]$body.sourceSystem
                                }
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    credential = New-CredentialDetails
                                    outcome = 1
                                    token = $Fixture.AdapterToken
                                })
                                continue
                            }
                            if ($method -eq 'GET' -and $path -ceq $credentialsPath) {
                                $credentials = if ($null -eq $script:credentialId) { @() } else { @(New-CredentialItem) }
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    credentials = $credentials
                                    page = 1
                                    pageSize = 100
                                    hasMore = $false
                                })
                                continue
                            }
                            if ($null -ne $script:credentialId -and
                                $method -eq 'POST' -and
                                $path -ceq "$credentialsPath/$($script:credentialId)/revoke") {
                                if ([long]$body.expectedVersion -ne $script:credentialVersion) {
                                    Write-FixtureProblem -Stream $stream -Code 'Ingestion.VersionConflict'
                                    continue
                                }
                                $script:credentialStatus = 2
                                $script:credentialVersion++
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    credentialId = $script:credentialId
                                    connectionId = $script:connectionId
                                    status = $script:credentialStatus
                                    version = $script:credentialVersion
                                })
                                continue
                            }
                        }

                        if ($method -eq 'GET' -and
                            $path -like "/api/ingestion/properties/$($Fixture.PropertyId)/receipts/*") {
                            $receiptId = $path.Substring($path.LastIndexOf('/') + 1)
                            if (-not $script:receipts.ContainsKey($receiptId)) {
                                Write-FixtureProblem -Stream $stream -Code 'Ingestion.ReceiptNotFound' -Status 404 -Reason 'Not Found'
                                continue
                            }
                            $receipt = $script:receipts[$receiptId]
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                receiptId = $receipt.ReceiptId
                                status = $receipt.Status
                                rejectionReason = $receipt.RejectionReason
                            })
                            continue
                        }

                        $reservationsBase = "/api/reservations/properties/$($Fixture.PropertyId)"
                        if ($method -eq 'GET' -and $path -ceq $reservationsBase) {
                            $reservations = if ($null -eq $script:reservationId) {
                                @()
                            }
                            else {
                                @([ordered]@{
                                    reservationId = $script:reservationId
                                    primaryGuestName = $script:reservationGuestName
                                    status = $script:reservationStatus
                                })
                            }
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                reservations = $reservations
                                page = 1
                                pageSize = 10
                                hasMore = $false
                            })
                            continue
                        }

                        if ($null -ne $script:reservationId) {
                            $reservationPath = "$reservationsBase/$($script:reservationId)"
                            if ($method -eq 'GET' -and $path -ceq $reservationPath) {
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ReservationDetails)
                                continue
                            }
                            if ($method -eq 'PUT' -and $path -ceq "$reservationPath/guest-details") {
                                if ([long]$body.expectedDetailsRevision -ne $script:reservationDetailsRevision) {
                                    Write-FixtureProblem -Stream $stream -Code 'Reservations.DetailsRevisionConflict'
                                    continue
                                }
                                $script:reservationDetailsRevision++
                                $script:reservationVersion++
                                $script:reservationOrigin = 1
                                $script:reservationGuestName = [string]$body.primaryGuestName
                                $script:reservationNotes = [string]$body.notes
                                Add-HistoryRevision -Revision $script:reservationDetailsRevision -Origin 1
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    reservationId = $script:reservationId
                                    detailsRevision = $script:reservationDetailsRevision
                                    version = $script:reservationVersion
                                })
                                continue
                            }
                            if ($method -eq 'GET' -and $path -ceq "$reservationPath/details-history") {
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    items = @($script:history)
                                    page = 1
                                    pageSize = 100
                                    hasMore = $false
                                })
                                continue
                            }
                            if ($method -eq 'POST' -and $path -ceq "$reservationPath/cancel") {
                                if ([long]$body.expectedVersion -ne $script:reservationVersion) {
                                    Write-FixtureProblem -Stream $stream -Code 'Reservations.VersionConflict'
                                    continue
                                }
                                $script:reservationStatus = 5
                                $script:reservationVersion++
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                    reservationId = $script:reservationId
                                    status = $script:reservationStatus
                                    version = $script:reservationVersion
                                })
                                continue
                            }
                        }

                        $proposalsBase = "/api/ingestion/properties/$($Fixture.PropertyId)/proposals"
                        if ($method -eq 'GET' -and $path -ceq $proposalsBase) {
                            $items = @($script:proposalOrder | ForEach-Object {
                                    New-ProposalDetails -Proposal $script:proposals[$_]
                                })
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body ([ordered]@{
                                proposals = $items
                                page = 1
                                pageSize = 100
                                hasMore = $false
                            })
                            continue
                        }

                        if ($path -like "$proposalsBase/*") {
                            $segments = $path.Split('/', [StringSplitOptions]::RemoveEmptyEntries)
                            $proposalId = $segments[5]
                            if (-not $script:proposals.ContainsKey($proposalId)) {
                                Write-FixtureProblem -Stream $stream -Code 'Ingestion.ProposalNotFound' -Status 404 -Reason 'Not Found'
                                continue
                            }
                            $proposal = $script:proposals[$proposalId]
                            if ($method -eq 'GET' -and $segments.Count -eq 6) {
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ProposalDetails -Proposal $proposal)
                                continue
                            }
                            if ($method -eq 'POST' -and $segments.Count -eq 7 -and $segments[6] -ceq 'reject') {
                                $reason = [string]$body.reason
                                $expectedVersion = [long]$body.expectedProposalVersion
                                if ($proposal.Status -eq 4 -and
                                    $proposal.DecisionKind -ceq 'reject' -and
                                    $proposal.DecisionRequestVersion -eq $expectedVersion -and
                                    $proposal.DecisionReason -ceq $reason) {
                                    Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ProposalDetails -Proposal $proposal)
                                    continue
                                }
                                if ($proposal.Status -ne 1 -or $proposal.Version -ne $expectedVersion) {
                                    Write-FixtureProblem -Stream $stream -Code 'Ingestion.ProposalDecisionConflict'
                                    continue
                                }
                                $proposal.Status = 4
                                $proposal.Version++
                                $proposal.DecisionActor = "user:$($Fixture.SubjectId)"
                                $proposal.DecisionReason = $reason
                                $proposal.DecidedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                                $proposal.DecisionKind = 'reject'
                                $proposal.DecisionRequestVersion = $expectedVersion
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ProposalDetails -Proposal $proposal)
                                continue
                            }
                            if ($method -eq 'POST' -and $segments.Count -eq 7 -and $segments[6] -ceq 'accept') {
                                $expectedVersion = [long]$body.expectedProposalVersion
                                $expectedReservationRevision = [long]$body.expectedReservationDetailsRevision
                                if ($proposal.Status -eq 3 -and
                                    $proposal.DecisionKind -ceq 'accept' -and
                                    $proposal.DecisionRequestVersion -eq $expectedVersion -and
                                    $proposal.DecisionReservationRevision -eq $expectedReservationRevision) {
                                    Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body (New-ProposalDetails -Proposal $proposal)
                                    continue
                                }
                                if ($proposal.Status -ne 1 -or
                                    $proposal.Version -ne $expectedVersion -or
                                    $script:reservationDetailsRevision -ne $expectedReservationRevision) {
                                    Write-FixtureProblem -Stream $stream -Code 'Ingestion.ProposalDecisionConflict'
                                    continue
                                }
                                $operationId = [Guid]::NewGuid().ToString('D')
                                $proposal.Status = 3
                                $proposal.Version += 2
                                $proposal.DecisionActor = "user:$($Fixture.SubjectId)"
                                $proposal.DecisionReason = $null
                                $proposal.DecidedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                                $proposal.DecisionKind = 'accept'
                                $proposal.DecisionRequestVersion = $expectedVersion
                                $proposal.DecisionReservationRevision = $expectedReservationRevision
                                $proposal.ProductOperationId = $operationId
                                $script:reservationDetailsRevision++
                                $script:reservationVersion++
                                $script:reservationOrigin = 2
                                $script:reservationGuestName = $proposal.GuestName
                                Add-HistoryRevision -Revision $script:reservationDetailsRevision -Origin 2
                                $started = New-ProposalDetails -Proposal $proposal
                                $started.status = 2
                                $started.version = $proposal.Version - 1
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason 'OK' -Body $started
                                continue
                            }
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
            throw "The Ingestion proposal fixture server stopped before readiness. $details"
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            throw 'The Ingestion proposal fixture server did not become ready.'
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

function Stop-BunkFyIngestionProposalFixtureServer {
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

function Invoke-BunkFyIngestionProposalFixtureProbe {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'supersession-drift')]
        [string] $Mode,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $server = Start-BunkFyIngestionProposalFixtureServer -Mode $Mode
    $probeError = $null
    try {
        $operatorToken = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        $deniedToken = ConvertTo-SecureString $fixture.DeniedToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin $server.Origin `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -InventoryUnitId $fixture.InventoryUnitId `
            -Arrival ([DateTime]'2027-10-20') `
            -Departure ([DateTime]'2027-10-22') `
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
        Stop-BunkFyIngestionProposalFixtureServer -Server $server
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
    $capture = Invoke-BunkFyIngestionProposalFixtureProbe -Mode valid -OutputPath $validOutput
    if ($null -eq $capture -or
        -not [string]::IsNullOrWhiteSpace([string]$capture.serverError) -or
        [int]$capture.connectionStatus -ne 2 -or
        [long]$capture.connectionVersion -ne 2 -or
        [int]$capture.credentialStatus -ne 2 -or
        [long]$capture.credentialVersion -ne 2 -or
        [int]$capture.reservationStatus -ne 5 -or
        [long]$capture.reservationDetailsRevision -ne 4 -or
        [int]$capture.proposalTotal -ne 3 -or
        [int]$capture.proposalPending -ne 0 -or
        [int]$capture.proposalSuperseded -ne 1 -or
        [int]$capture.proposalRejected -ne 1 -or
        [int]$capture.proposalApplied -ne 1 -or
        [int]$capture.policyProjectionMisses -ne 1 -or
        [bool]$capture.supersessionDriftEmitted) {
        throw 'The valid Ingestion proposal fixture did not reach the expected terminal state.'
    }

    $evidence = Get-Content -LiteralPath $validOutput -Raw | ConvertFrom-Json -Depth 12
    if ($evidence.schemaVersion -ne 2 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-ingestion-conflict-proposal-lifecycle-probe' -or
        $evidence.result -cne 'passed' -or
        $evidence.releaseId -cne $fixture.ReleaseId -or
        $evidence.admissionEvidenceReference -cne $fixture.AdmissionEvidenceReference -or
        $evidence.adapterContract.executionMode -cne 'push' -or
        [long]$evidence.authorityRevisions.initialAdapter -ne 1 -or
        [long]$evidence.authorityRevisions.automaticAdapter -ne 2 -or
        [long]$evidence.authorityRevisions.staff -ne 3 -or
        [long]$evidence.authorityRevisions.acceptedAdapter -ne 4 -or
        [int]$evidence.proposalSummary.total -ne 3 -or
        [int]$evidence.proposalSummary.superseded -ne 1 -or
        [int]$evidence.proposalSummary.rejected -ne 1 -or
        [int]$evidence.proposalSummary.applied -ne 1 -or
        [int]$evidence.proposalSummary.pending -ne 0 -or
        $evidence.cleanup.reservation -cne 'cancelled' -or
        $evidence.cleanup.credential -cne 'revoked' -or
        $evidence.cleanup.connection -cne 'disabled' -or
        @($evidence.checks).Count -ne 26 -or
        @($evidence.limitations).Count -ne 5) {
        throw 'The valid Ingestion proposal fixture produced invalid evidence.'
    }

    $evidenceText = Get-Content -LiteralPath $validOutput -Raw
    foreach ($sensitive in @(
            $fixture.WorkspaceId,
            $fixture.PropertyId,
            $fixture.InventoryUnitId,
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
            [string]$capture.reservationId,
            [string]$capture.reservationGuestName,
            'fixture-policy-do-not-retain',
            'fixture-region-do-not-retain',
            'fixture-transfer-do-not-retain',
            'fixture-retention-do-not-retain',
            'Authorization',
            'X-Tenant-Id')) {
        if (-not [string]::IsNullOrWhiteSpace($sensitive) -and
            $evidenceText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Ingestion proposal evidence retained scoped, adapter, reservation, credential, or policy data.'
        }
    }

    if (-not $IsWindows) {
        $mode = [IO.File]::GetUnixFileMode($validOutput)
        $expectedMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        if ($mode -ne $expectedMode) {
            throw "Ingestion proposal evidence mode '$mode' is not private 0600."
        }
    }

    $driftOutput = Join-Path $fixtureRoot 'supersession-drift-evidence.json'
    $driftRejected = $false
    $driftCapture = $null
    try {
        [void](Invoke-BunkFyIngestionProposalFixtureProbe `
                -Mode supersession-drift `
                -OutputPath $driftOutput)
    }
    catch {
        $driftRejected = $_.Exception.Message.Contains(
            'proposal set did not converge',
            [StringComparison]::OrdinalIgnoreCase)
        $driftCapture = $_.Exception.Data['FixtureCapture']
    }
    if (-not $driftRejected -or
        (Test-Path -LiteralPath $driftOutput) -or
        $null -eq $driftCapture -or
        -not [bool]$driftCapture.supersessionDriftEmitted -or
        [int]$driftCapture.connectionStatus -ne 2 -or
        [int]$driftCapture.credentialStatus -ne 2 -or
        [int]$driftCapture.reservationStatus -ne 5 -or
        [int]$driftCapture.proposalPending -ne 0) {
        throw 'The Ingestion proposal probe accepted supersession drift, wrote passing evidence, or failed terminal cleanup.'
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
            -InventoryUnitId $fixture.InventoryUnitId `
            -Arrival ([DateTime]'2027-10-20') `
            -Departure ([DateTime]'2027-10-22') `
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
        throw 'The Ingestion proposal lifecycle probe accepted insecure non-loopback HTTP.'
    }

    Write-Host 'BunkFy deployed Ingestion conflict and proposal lifecycle fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
