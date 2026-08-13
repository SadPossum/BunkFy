Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-reservations-inventory.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-reservations-inventory-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$fixture = [pscustomobject]@{
    ReleaseId = 'release-fixture-001'
    WorkspaceId = '11111111-1111-4111-8111-111111111111'
    PropertyId = '22222222-2222-4222-8222-222222222222'
    InventoryUnitId = '33333333-3333-4333-8333-333333333333'
    RoomId = '44444444-4444-4444-8444-444444444444'
    AllocationId = '55555555-5555-4555-8555-555555555555'
    MembershipId = '66666666-6666-4666-8666-666666666666'
    SubjectId = '77777777-7777-4777-8777-777777777777'
    OperatorToken = 'fixture-reservation-operator-token-do-not-retain'
    Arrival = '2026-08-10'
    Departure = '2026-08-12'
    GuestLabel = 'BunkFy deployment verification'
}

function Start-BunkFyReservationsInventoryFixtureServer {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'replay-drift')]
        [string] $Mode
    )

    $nonce = [Guid]::NewGuid().ToString('N')
    $readyPath = Join-Path $fixtureRoot "ready-$Mode-$nonce.txt"
    $capturePath = Join-Path $fixtureRoot "reservation-$Mode-$nonce.txt"
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
                $Body | ConvertTo-Json -Depth 12 -Compress
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

        function New-MembershipPage {
            return [ordered]@{
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
            }
        }

        function New-AvailabilityResponse {
            param(
                [Parameter(Mandatory = $true)][bool] $Available,
                [Parameter(Mandatory = $true)][bool] $Allocated
            )

            $allocationIds = [Collections.Generic.List[string]]::new()
            if ($Allocated) {
                [void]$allocationIds.Add($Fixture.AllocationId)
            }

            return [ordered]@{
                propertyId = $Fixture.PropertyId
                arrival = $Fixture.Arrival
                departure = $Fixture.Departure
                units = @([ordered]@{
                        unit = [ordered]@{
                            inventoryUnitId = $Fixture.InventoryUnitId
                            propertyId = $Fixture.PropertyId
                            roomId = $Fixture.RoomId
                            bedId = $null
                            kind = 2
                            label = 'Fixture room'
                            isSellable = $true
                            isTopologyActive = $true
                        }
                        isAvailable = $Available
                        activeBlockIds = [object[]]::new(0)
                        activeAllocationIds = $allocationIds
                    })
            }
        }

        function New-ReservationReceipt {
            param([switch] $Drift)

            return [ordered]@{
                reservationId = $script:reservationId
                propertyId = $Fixture.PropertyId
                status = $script:status
                detailsRevision = $script:detailsRevision
                version = if ($Drift) { $script:version + 1 } else { $script:version }
            }
        }

        function New-ReservationDetails {
            return [ordered]@{
                reservationId = $script:reservationId
                propertyId = $Fixture.PropertyId
                status = $script:status
                detailsRevision = $script:detailsRevision
                version = $script:version
            }
        }

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)

            $script:reservationId = $null
            $script:status = 0
            $script:version = 0L
            $script:detailsRevision = 1L
            $script:pendingCreateOperationId = $null
            $createCount = 0
            $lifecycleOperations = @{}
            $done = $false
            $requestCount = 0
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            while (-not $done -and
                $requestCount -lt 24 -and
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

                        $bodyText = ''
                        $contentLength = if ($headers.ContainsKey('Content-Length')) {
                            [int]$headers['Content-Length']
                        }
                        else {
                            0
                        }
                        if ($contentLength -gt 0) {
                            $buffer = [char[]]::new($contentLength)
                            $offset = 0
                            while ($offset -lt $contentLength) {
                                $read = $reader.Read(
                                    $buffer,
                                    $offset,
                                    $contentLength - $offset)
                                if ($read -le 0) {
                                    throw 'Fixture request body ended before Content-Length.'
                                }
                                $offset += $read
                            }
                            $bodyText = [string]::new($buffer)
                        }
                    }
                    finally {
                        $reader.Dispose()
                    }

                    $requestCount++
                    $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
                    if ($method -ceq 'GET' -and $path -ceq '/api/smoke') {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                                application = 'BunkFy'
                                service = 'BunkFy.Host.Api'
                                status = 'ok'
                                releaseId = $Fixture.ReleaseId
                                timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                            })
                        if ($script:status -eq 10) {
                            $done = $true
                        }
                        continue
                    }

                    if ([string]$headers['Authorization'] -cne
                        "Bearer $($Fixture.OperatorToken)") {
                        throw 'Fixture request used the wrong bearer token.'
                    }
                    $availabilityPath = "/api/inventory/properties/$($Fixture.PropertyId)/availability?arrival=$($Fixture.Arrival)&departure=$($Fixture.Departure)"
                    if ($method -ceq 'GET' -and
                        $path -ceq $availabilityPath -and
                        [string]$headers['X-Tenant-Id'] -cne $Fixture.WorkspaceId) {
                        Write-FixtureResponse `
                            -Stream $stream `
                            -Status 403 `
                            -Reason Forbidden `
                            -Body ([ordered]@{
                                type = 'about:blank'
                                title = 'Authorization denied'
                                status = 403
                            })
                        continue
                    }
                    $expectedTenant = if ($path.StartsWith('/api/organizations?', [StringComparison]::Ordinal)) {
                        'global'
                    }
                    else {
                        $Fixture.WorkspaceId
                    }
                    if ([string]$headers['X-Tenant-Id'] -cne $expectedTenant) {
                        throw "Fixture request used the wrong tenant for '$path'."
                    }

                    if ($method -ceq 'GET' -and
                        $path -ceq '/api/organizations?page=1&pageSize=100') {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-MembershipPage)
                        continue
                    }
                    if ($method -ceq 'GET' -and
                        $path -ceq "/api/properties/$($Fixture.PropertyId)") {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                                propertyId = $Fixture.PropertyId
                                name = 'Fixture property'
                            })
                        continue
                    }

                    if ($method -ceq 'GET' -and $path -ceq $availabilityPath) {
                        $allocated = $script:status -in @(1, 2, 6, 9)
                        $available = $script:status -in @(0, 5, 10)
                        Write-FixtureResponse `
                            -Stream $stream `
                            -Status 200 `
                            -Reason OK `
                            -Body (New-AvailabilityResponse `
                                -Available $available `
                                -Allocated $allocated)
                        continue
                    }

                    $collectionPath = "/api/reservations/properties/$($Fixture.PropertyId)"
                    if ($method -ceq 'POST' -and $path -ceq $collectionPath) {
                        $request = $bodyText | ConvertFrom-Json -Depth 12
                        if ([Guid]$request.operationId -eq [Guid]::Empty -or
                            [string]$request.arrival -cne $Fixture.Arrival -or
                            [string]$request.departure -cne $Fixture.Departure -or
                            @($request.inventoryUnitIds).Count -ne 1 -or
                            [Guid]$request.inventoryUnitIds[0] -ne [Guid]$Fixture.InventoryUnitId -or
                            [string]$request.primaryGuestName -cne $Fixture.GuestLabel -or
                            [int]$request.guestCount -ne 1 -or
                            [int]$request.sourceKind -ne 1 -or
                            $null -ne $request.email -or
                            $null -ne $request.phone -or
                            $null -ne $request.notes -or
                            $null -ne $request.sourceSystem -or
                            $null -ne $request.sourceReference -or
                            $null -ne $request.expectedArrivalTime -or
                            $null -ne $request.expectedDepartureTime) {
                            throw 'Fixture received an unsafe or unexpected Reservation create request.'
                        }

                        if ($null -eq $script:pendingCreateOperationId) {
                            $script:pendingCreateOperationId = ([Guid]$request.operationId).ToString('D')
                            Write-FixtureResponse `
                                -Stream $stream `
                                -Status 409 `
                                -Reason Conflict `
                                -Body ([ordered]@{
                                    type = 'about:blank'
                                    title = 'Reservations.CountryPolicyDenied.MissingBinding'
                                    status = 409
                                })
                            continue
                        }
                        if ([Guid]$request.operationId -ne [Guid]$script:pendingCreateOperationId) {
                            throw 'Reservation projection-convergence retry used a different operation id.'
                        }

                        $createCount++
                        if ($createCount -eq 1) {
                            $script:reservationId = ([Guid]$request.operationId).ToString('D')
                            [IO.File]::WriteAllText($CapturePath, $script:reservationId)
                            $script:status = 1
                            $script:version = 1
                        }
                        elseif ([Guid]$request.operationId -ne [Guid]$script:reservationId) {
                            throw 'Reservation create retry used a different operation id.'
                        }

                        Write-FixtureResponse `
                            -Stream $stream `
                            -Status 200 `
                            -Reason OK `
                            -Body (New-ReservationReceipt `
                                -Drift:($Mode -ceq 'replay-drift' -and $createCount -eq 2))
                        continue
                    }

                    $reservationPath = "$collectionPath/$script:reservationId"
                    if ($method -ceq 'GET' -and $path -ceq $reservationPath) {
                        if ($script:status -eq 1) {
                            $script:status = 2
                            $script:version++
                        }
                        elseif ($script:status -eq 4) {
                            $script:status = 5
                            $script:version++
                            $done = $true
                        }
                        elseif ($script:status -eq 9) {
                            $script:status = 10
                            $script:version++
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-ReservationDetails)
                        continue
                    }

                    if ($method -ceq 'POST' -and $path.StartsWith("$reservationPath/", [StringComparison]::Ordinal)) {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $action = $path.Substring($reservationPath.Length + 1)
                        $operationId = [Guid]$request.operationId
                        if ($operationId -eq [Guid]::Empty) {
                            throw "Fixture received an empty operationId for '$action'."
                        }

                        $businessDateProperty = $request.PSObject.Properties['businessDate']
                        $businessDate = if ($null -eq $businessDateProperty -or
                            $null -eq $businessDateProperty.Value) {
                            ''
                        }
                        else {
                            [string]$businessDateProperty.Value
                        }
                        $fingerprint = "$action|$([long]$request.expectedVersion)|$businessDate"
                        $operationKey = $operationId.ToString('D')
                        if ($lifecycleOperations.ContainsKey($operationKey)) {
                            if ([string]$lifecycleOperations[$operationKey] -cne $fingerprint) {
                                throw "Fixture received changed lifecycle input for operationId '$operationKey'."
                            }

                            Write-FixtureResponse `
                                -Stream $stream `
                                -Status 200 `
                                -Reason OK `
                                -Body (New-ReservationReceipt)
                            continue
                        }

                        if ([long]$request.expectedVersion -ne $script:version) {
                            throw "Fixture received stale expectedVersion for '$action'."
                        }
                        switch ($action) {
                            'check-in' {
                                if ($script:status -ne 2 -or
                                    [string]$request.businessDate -cne $Fixture.Arrival) {
                                    throw 'Fixture received invalid check-in.'
                                }
                                $script:status = 6
                                $script:version++
                            }
                            'check-out' {
                                if ($script:status -ne 6 -or
                                    [string]$request.businessDate -cne $Fixture.Arrival) {
                                    throw 'Fixture received invalid checkout.'
                                }
                                $script:status = 9
                                $script:version++
                            }
                            'cancel' {
                                if ($script:status -notin @(1, 2)) {
                                    throw 'Fixture received invalid cancellation.'
                                }
                                $script:status = 4
                                $script:version++
                            }
                            default {
                                throw "Fixture received unexpected Reservation action '$action'."
                            }
                        }
                        $lifecycleOperations[$operationKey] = $fingerprint
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-ReservationReceipt)
                        continue
                    }

                    throw "Fixture received unexpected request '$method $path'."
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
    } -ArgumentList $readyPath, $capturePath, $Mode, $fixture

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath) -and
        [DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
    }
    if (-not (Test-Path -LiteralPath $readyPath)) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw "The $Mode Reservations and Inventory fixture did not become ready."
    }
    $port = [int](Get-Content -LiteralPath $readyPath -Raw)
    return [pscustomobject]@{
        Job = $job
        Origin = [Uri]"http://127.0.0.1:$port"
        CapturePath = $capturePath
    }
}

function Complete-BunkFyReservationsInventoryFixtureServer {
    param([Parameter(Mandatory = $true)][object] $Server)

    try {
        $completed = Wait-Job -Job $Server.Job -Timeout 15
        if ($null -eq $completed) {
            throw 'The Reservations and Inventory fixture server did not terminate after the probe.'
        }
        $output = @(Receive-Job -Job $Server.Job -ErrorAction Stop)
        if ($Server.Job.State -ne 'Completed') {
            throw "The Reservations and Inventory fixture ended in state '$($Server.Job.State)': $($output -join [Environment]::NewLine)"
        }
    }
    finally {
        Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    }
}

function Stop-BunkFyReservationsInventoryFixtureServer {
    param([AllowNull()][object] $Server)

    if ($null -eq $Server) {
        return
    }
    Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
}

function Invoke-BunkFyReservationsInventoryFixtureProbe {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'replay-drift')]
        [string] $Mode,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $server = $null
    try {
        $server = Start-BunkFyReservationsInventoryFixtureServer -Mode $Mode
        $token = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        $probeError = $null
        try {
            & $probeScript `
                -PublicOrigin $server.Origin `
                -ExpectedReleaseId $fixture.ReleaseId `
                -WorkspaceId $fixture.WorkspaceId `
                -PropertyId $fixture.PropertyId `
                -InventoryUnitId $fixture.InventoryUnitId `
                -Arrival $fixture.Arrival `
                -Departure $fixture.Departure `
                -OperatorAccessToken $token `
                -RequestTimeoutSeconds 5 `
                -ConvergenceTimeoutSeconds 15 `
                -PollIntervalMilliseconds 250 `
                -OutputPath $OutputPath `
                -AllowLoopbackHttp `
                -Confirm:$false
        }
        catch {
            $probeError = $_
        }
        Complete-BunkFyReservationsInventoryFixtureServer -Server $server
        $server = $null
        if ($null -ne $probeError) {
            throw $probeError
        }
    }
    finally {
        Stop-BunkFyReservationsInventoryFixtureServer -Server $server
    }
}

function Assert-BunkFyExactPropertyNames {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    if ($actual.Count -ne $expectedSorted.Count -or
        (Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actual)) {
        throw "$Context has an invalid property set."
    }
}

try {
    $validOutput = Join-Path $fixtureRoot 'valid-evidence.json'
    $server = $null
    try {
        $server = Start-BunkFyReservationsInventoryFixtureServer -Mode valid
        $token = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin $server.Origin `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -InventoryUnitId $fixture.InventoryUnitId `
            -Arrival $fixture.Arrival `
            -Departure $fixture.Departure `
            -OperatorAccessToken $token `
            -RequestTimeoutSeconds 5 `
            -ConvergenceTimeoutSeconds 15 `
            -PollIntervalMilliseconds 250 `
            -OutputPath $validOutput `
            -AllowLoopbackHttp `
            -Confirm:$false
        Complete-BunkFyReservationsInventoryFixtureServer -Server $server
        $reservationId = Get-Content -LiteralPath $server.CapturePath -Raw
        $server = $null
    }
    finally {
        Stop-BunkFyReservationsInventoryFixtureServer -Server $server
    }

    $evidence = Get-Content -LiteralPath $validOutput -Raw |
        ConvertFrom-Json -Depth 12
    if ($evidence.schemaVersion -ne 2 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-reservations-inventory-probe' -or
        $evidence.result -cne 'passed' -or
        $evidence.releaseId -cne $fixture.ReleaseId -or
        $evidence.transport -cne 'loopback-http-preview' -or
        @($evidence.checks).Count -ne 12 -or
        [string]$evidence.workflow.bookingSource -cne 'direct' -or
        [string]$evidence.workflow.allocationLifecycle -cne
            'available-confirmed-released' -or
        [string]$evidence.workflow.occupancyLifecycle -cne
            'confirmed-checked-in-checked-out' -or
        [string]$evidence.workflow.createReplay -cne 'stable-current' -or
        [string]$evidence.workflow.checkInReplay -cne 'stable-current' -or
        [string]$evidence.workflow.checkOutReplay -cne 'stable-current' -or
        $evidence.workflow.durableGuestRecordCreated -isnot [bool] -or
        [bool]$evidence.workflow.durableGuestRecordCreated -or
        [string]$evidence.cleanup.reservationDisposition -cne
            'synthetic-checked-out-retained' -or
        [string]$evidence.cleanup.selectedInventoryUnit -cne 'available' -or
        [int]$evidence.cleanup.activeAllocationCount -ne 0 -or
        $evidence.cleanup.topologyMutated -isnot [bool] -or
        [bool]$evidence.cleanup.topologyMutated -or
        @($evidence.limitations).Count -ne 4) {
        throw 'The valid Reservations and Inventory fixture produced invalid evidence.'
    }
    Assert-BunkFyExactPropertyNames `
        -Value $evidence `
        -Expected @(
            'schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin',
            'releaseId', 'transport', 'result', 'workflow', 'cleanup',
            'checks', 'limitations') `
        -Context 'Reservations and Inventory evidence'
    Assert-BunkFyExactPropertyNames `
        -Value $evidence.workflow `
        -Expected @(
            'bookingSource', 'allocationLifecycle', 'occupancyLifecycle',
            'createReplay', 'checkInReplay', 'checkOutReplay',
            'durableGuestRecordCreated') `
        -Context 'Reservations and Inventory workflow evidence'
    Assert-BunkFyExactPropertyNames `
        -Value $evidence.cleanup `
        -Expected @(
            'reservationDisposition', 'selectedInventoryUnit',
            'activeAllocationCount', 'topologyMutated') `
        -Context 'Reservations and Inventory cleanup evidence'
    $expectedChecks = @(
        'cross-workspace-inventory-read-denied',
        'scoped-operator-and-property-preflight',
        'inventory-available-before-create',
        'reservation-allocation-confirmed',
        'reservation-create-replay-stable',
        'allocated-inventory-unavailable',
        'reservation-check-in-recorded',
        'reservation-check-in-replay-stable',
        'reservation-checkout-converged',
        'reservation-checkout-replay-current',
        'inventory-released-after-checkout',
        'release-identity-continuous')
    $actualChecks = @($evidence.checks | ForEach-Object { [string]$_.name })
    if (Compare-Object -ReferenceObject $expectedChecks -DifferenceObject $actualChecks) {
        throw 'The Reservations and Inventory fixture produced an invalid check set.'
    }
    $evidenceText = Get-Content -LiteralPath $validOutput -Raw
    foreach ($sensitive in @(
            $fixture.WorkspaceId,
            $fixture.PropertyId,
            $fixture.InventoryUnitId,
            $fixture.RoomId,
            $fixture.AllocationId,
            $fixture.MembershipId,
            $fixture.SubjectId,
            $fixture.OperatorToken,
            $fixture.GuestLabel,
            $reservationId,
            'Fixture workspace',
            'Fixture property',
            'Fixture room',
            'Authorization',
            'X-Tenant-Id')) {
        if ($evidenceText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Reservations and Inventory evidence retained scoped, personal, or credential data.'
        }
    }
    foreach ($stayDate in @($fixture.Arrival, $fixture.Departure)) {
        $jsonDateLiteral = '"' + $stayDate + '"'
        if ($evidenceText.Contains($jsonDateLiteral, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Reservations and Inventory evidence retained a stay date.'
        }
    }
    if ($evidenceText -match
        '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b') {
        throw 'Reservations and Inventory evidence retained an identifier.'
    }
    if (-not $IsWindows) {
        $mode = (& stat -c '%a' -- $validOutput).Trim()
        if ($LASTEXITCODE -ne 0 -or $mode -cne '600') {
            throw "Reservations and Inventory evidence mode is '$mode' instead of '600'."
        }
    }

    $overwriteRejected = $false
    try {
        $token = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://127.0.0.1:65530') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -InventoryUnitId $fixture.InventoryUnitId `
            -Arrival $fixture.Arrival `
            -Departure $fixture.Departure `
            -OperatorAccessToken $token `
            -OutputPath $validOutput `
            -AllowLoopbackHttp `
            -Confirm:$false
    }
    catch {
        $overwriteRejected = $_.Exception.Message.Contains(
            'already exists',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $overwriteRejected) {
        throw 'The Reservations and Inventory probe overwrote or contacted the network for existing evidence.'
    }

    $driftOutput = Join-Path $fixtureRoot 'replay-drift-evidence.json'
    $driftRejected = $false
    try {
        Invoke-BunkFyReservationsInventoryFixtureProbe `
            -Mode replay-drift `
            -OutputPath $driftOutput
    }
    catch {
        $driftRejected = $_.Exception.Message.Contains(
            'exact Reservation create replay',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $driftRejected -or (Test-Path -LiteralPath $driftOutput)) {
        throw 'The Reservations and Inventory probe accepted replay drift or wrote passing evidence.'
    }

    $releaseMismatchOutput = Join-Path $fixtureRoot 'release-mismatch-evidence.json'
    $releaseMismatchServer = $null
    $releaseMismatchRejected = $false
    try {
        $releaseMismatchServer = Start-BunkFyReservationsInventoryFixtureServer -Mode valid
        $token = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin $releaseMismatchServer.Origin `
            -ExpectedReleaseId 'release-fixture-other' `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -InventoryUnitId $fixture.InventoryUnitId `
            -Arrival $fixture.Arrival `
            -Departure $fixture.Departure `
            -OperatorAccessToken $token `
            -RequestTimeoutSeconds 5 `
            -ConvergenceTimeoutSeconds 15 `
            -PollIntervalMilliseconds 250 `
            -OutputPath $releaseMismatchOutput `
            -AllowLoopbackHttp `
            -Confirm:$false
    }
    catch {
        $releaseMismatchRejected = $_.Exception.Message.Contains(
            'does not match',
            [StringComparison]::OrdinalIgnoreCase)
    }
    finally {
        Stop-BunkFyReservationsInventoryFixtureServer -Server $releaseMismatchServer
    }
    if (-not $releaseMismatchRejected -or
        (Test-Path -LiteralPath $releaseMismatchOutput)) {
        throw 'The Reservations and Inventory probe accepted a different deployed release or wrote passing evidence.'
    }

    $insecureOriginRejected = $false
    try {
        $token = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://reservations.example.test:8080') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -InventoryUnitId $fixture.InventoryUnitId `
            -Arrival $fixture.Arrival `
            -Departure $fixture.Departure `
            -OperatorAccessToken $token `
            -OutputPath (Join-Path $fixtureRoot 'insecure-origin.json') `
            -Confirm:$false
    }
    catch {
        $insecureOriginRejected = $_.Exception.Message.Contains(
            'must use HTTPS',
            [StringComparison]::Ordinal)
    }
    if (-not $insecureOriginRejected) {
        throw 'The Reservations and Inventory probe accepted insecure non-loopback HTTP.'
    }

    Write-Host 'BunkFy deployed Reservations and Inventory fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
