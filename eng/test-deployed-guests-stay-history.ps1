Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-guests-stay-history.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-guests-stay-history-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$fixture = [pscustomobject]@{
    ReleaseId = 'release-guests-fixture-001'
    WorkspaceId = '11111111-1111-4111-8111-111111111111'
    PropertyId = '22222222-2222-4222-8222-222222222222'
    InventoryUnitId = '33333333-3333-4333-8333-333333333333'
    RoomId = '44444444-4444-4444-8444-444444444444'
    AllocationId = '55555555-5555-4555-8555-555555555555'
    MembershipId = '66666666-6666-4666-8666-666666666666'
    SubjectId = '77777777-7777-4777-8777-777777777777'
    OperatorToken = 'fixture-guests-operator-token-do-not-retain'
    DeniedToken = 'fixture-guests-nonmember-token-do-not-retain'
    Arrival = '2026-09-10'
    Departure = '2026-09-12'
}

function Start-BunkFyGuestsStayHistoryFixtureServer {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'archive-replay-drift')]
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

        function Write-FixtureProblem {
            param(
                [Parameter(Mandatory = $true)][IO.Stream] $Stream,
                [Parameter(Mandatory = $true)][string] $Code
            )

            Write-FixtureResponse `
                -Stream $Stream `
                -Status 409 `
                -Reason Conflict `
                -Body ([ordered]@{
                    type = 'about:blank'
                    title = $Code
                    status = 409
                })
        }

        function Write-Capture {
            $capture = [ordered]@{
                guestId = $script:guestId
                reservationId = $script:reservationId
                initialGuestLabel = $script:initialGuestLabel
                updatedGuestLabel = $script:updatedGuestLabel
            }
            [IO.File]::WriteAllText(
                $CapturePath,
                ($capture | ConvertTo-Json -Compress),
                [Text.UTF8Encoding]::new($false))
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
            $allocated = $script:reservationStatus -in @(1, 2, 6, 9)
            $allocationIds = [Collections.Generic.List[string]]::new()
            if ($allocated) {
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
                        isAvailable = -not $allocated
                        activeBlockIds = [object[]]::new(0)
                        activeAllocationIds = $allocationIds
                    })
            }
        }

        function New-GuestReceipt {
            param([switch] $ArchiveReplayDrift)

            return [ordered]@{
                guestId = $script:guestId
                status = $script:guestStatus
                version = if ($ArchiveReplayDrift) {
                    $script:guestVersion + 1
                }
                else {
                    $script:guestVersion
                }
                lastChangedAtUtc = $script:guestChangedAtUtc
            }
        }

        function New-GuestDetail {
            return [ordered]@{
                guestId = $script:guestId
                originPropertyId = $Fixture.PropertyId
                displayName = $script:currentGuestLabel
                legalName = $null
                email = $null
                phone = $null
                dateOfBirth = $null
                nationalityCountryCode = $null
                preferredLanguageTag = $null
                notes = $null
                status = $script:guestStatus
                version = $script:guestVersion
                createdBy = "user:$($Fixture.SubjectId)"
                createdAtUtc = '2026-08-12T00:00:00.1234567+00:00'
                lastChangedBy = "user:$($Fixture.SubjectId)"
                lastChangedAtUtc = $script:guestChangedAtUtc
                archivedAtUtc = if ($script:guestStatus -eq 2) {
                    '2026-08-12T00:00:02.1234567+00:00'
                }
                else {
                    $null
                }
            }
        }

        function New-GuestDirectory {
            param([Parameter(Mandatory = $true)][int] $RequestedStatus)

            $guests = [Collections.Generic.List[object]]::new()
            if ($script:guestStatus -eq $RequestedStatus) {
                $guests.Add([ordered]@{
                        guestId = $script:guestId
                        displayName = $script:currentGuestLabel
                        legalName = $null
                        email = $null
                        phone = $null
                        nationalityCountryCode = $null
                        preferredLanguageTag = $null
                        status = $script:guestStatus
                        lastChangedBy = "user:$($Fixture.SubjectId)"
                        lastChangedAtUtc = $script:guestChangedAtUtc
                    })
            }
            return [ordered]@{
                guests = $guests
                page = 1
                pageSize = 10
                hasMore = $false
            }
        }

        function New-ReservationReceipt {
            return [ordered]@{
                reservationId = $script:reservationId
                propertyId = $Fixture.PropertyId
                status = $script:reservationStatus
                detailsRevision = 1
                version = $script:reservationVersion
            }
        }

        function New-ReservationDetail {
            $guests = [Collections.Generic.List[object]]::new()
            if ($script:guestLinked) {
                $guests.Add([ordered]@{
                        guestId = $script:guestId
                        role = 1
                    })
            }
            return [ordered]@{
                reservationId = $script:reservationId
                propertyId = $Fixture.PropertyId
                status = $script:reservationStatus
                detailsRevision = 1
                version = $script:reservationVersion
                guests = $guests
            }
        }

        function New-StayHistory {
            $stays = [Collections.Generic.List[object]]::new()
            if ($script:guestLinked) {
                $stays.Add([ordered]@{
                        reservationId = $script:reservationId
                        propertyId = $Fixture.PropertyId
                        role = 1
                        arrival = $Fixture.Arrival
                        departure = $Fixture.Departure
                        status = $script:reservationStatus
                        checkedInBusinessDate = if ($script:reservationStatus -in @(6, 9, 10)) {
                            $Fixture.Arrival
                        }
                        else {
                            $null
                        }
                        noShowBusinessDate = $null
                        checkedOutBusinessDate = if ($script:reservationStatus -eq 10) {
                            $Fixture.Arrival
                        }
                        else {
                            $null
                        }
                        isCurrentParticipant = $true
                        reservationVersion = $script:reservationVersion
                    })
            }
            return [ordered]@{
                stays = $stays
                page = 1
                pageSize = 10
                hasMore = $false
            }
        }

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)

            $script:guestId = $null
            $script:guestStatus = 0
            $script:guestVersion = 0L
            $script:guestChangedAtUtc = $null
            $script:initialGuestLabel = $null
            $script:updatedGuestLabel = $null
            $script:currentGuestLabel = $null
            $script:guestCreatePending = $false
            $script:updateOperationId = $null
            $script:archiveOperationId = $null
            $script:archiveReplayCount = 0
            $script:reservationId = $null
            $script:reservationStatus = 0
            $script:reservationVersion = 0L
            $script:guestLinked = $false
            $script:linkAttemptCount = 0
            $script:releaseSmokeSeen = $false
            $done = $false
            $requestCount = 0
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(8)
            while (-not $done -and
                $requestCount -lt 60 -and
                [DateTimeOffset]::UtcNow -lt $inactivityDeadline) {
                if (-not $listener.Pending()) {
                    Start-Sleep -Milliseconds 25
                    continue
                }

                $tcpClient = $listener.AcceptTcpClient()
                try {
                    $tcpClient.ReceiveTimeout = 5000
                    $tcpClient.SendTimeout = 5000
                    $stream = $tcpClient.GetStream()
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
                $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(8)
                    if ($method -ceq 'GET' -and $path -ceq '/api/smoke') {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                                application = 'BunkFy'
                                service = 'BunkFy.Host.Api'
                                status = 'ok'
                                releaseId = $Fixture.ReleaseId
                                timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                            })
                        if ($script:guestStatus -eq 2 -and
                            $script:reservationStatus -eq 10) {
                            $script:releaseSmokeSeen = $true
                        }
                        continue
                    }

                    $authorization = [string]$headers['Authorization']
                    $expectedTenant = if ($path.StartsWith('/api/organizations?', [StringComparison]::Ordinal)) {
                        'global'
                    }
                    else {
                        $Fixture.WorkspaceId
                    }
                    if ([string]$headers['X-Tenant-Id'] -cne $expectedTenant) {
                        throw "Fixture request used the wrong tenant for '$path'."
                    }

                    $guestCollectionPath = "/api/guests/properties/$($Fixture.PropertyId)"
                    if ($authorization -ceq "Bearer $($Fixture.DeniedToken)" -and
                        $method -ceq 'GET' -and
                        $path.StartsWith("${guestCollectionPath}?", [StringComparison]::Ordinal)) {
                        Write-FixtureResponse -Stream $stream -Status 403 -Reason Forbidden -Body ([ordered]@{
                                type = 'about:blank'
                                title = 'Access.Forbidden'
                                status = 403
                            })
                        continue
                    }
                    if ($authorization -cne "Bearer $($Fixture.OperatorToken)") {
                        throw 'Fixture request used the wrong bearer token.'
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

                    $availabilityPath = "/api/inventory/properties/$($Fixture.PropertyId)/availability?arrival=$($Fixture.Arrival)&departure=$($Fixture.Departure)"
                    if ($method -ceq 'GET' -and $path -ceq $availabilityPath) {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-AvailabilityResponse)
                        continue
                    }

                    if ($method -ceq 'POST' -and $path -ceq $guestCollectionPath) {
                        $request = $bodyText | ConvertFrom-Json -Depth 12
                        if ([Guid]$request.operationId -eq [Guid]::Empty -or
                            $null -ne $request.legalName -or
                            $null -ne $request.email -or
                            $null -ne $request.phone -or
                            $null -ne $request.dateOfBirth -or
                            $null -ne $request.nationalityCountryCode -or
                            $null -ne $request.preferredLanguageTag -or
                            $null -ne $request.notes) {
                            throw 'Fixture received an unsafe Guest create request.'
                        }

                        if (-not $script:guestCreatePending) {
                            $script:guestCreatePending = $true
                            $script:guestId = ([Guid]$request.operationId).ToString('D')
                            $script:initialGuestLabel = [string]$request.displayName
                            Write-FixtureProblem `
                                -Stream $stream `
                                -Code 'Guests.CountryPolicyDenied.MissingBinding'
                            continue
                        }
                        if ([Guid]$request.operationId -ne [Guid]$script:guestId) {
                            throw 'Guest creation retry used a different operation id.'
                        }
                        if ($script:guestStatus -eq 0) {
                            if ([string]$request.displayName -cne $script:initialGuestLabel) {
                                throw 'Guest creation retry changed its display label.'
                            }
                            $script:guestStatus = 1
                            $script:guestVersion = 1
                            $script:currentGuestLabel = $script:initialGuestLabel
                            $script:guestChangedAtUtc = '2026-08-12T00:00:00.1234567+00:00'
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-GuestReceipt)
                            continue
                        }
                        if ([string]$request.displayName -ceq $script:initialGuestLabel) {
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-GuestReceipt)
                        }
                        else {
                            Write-FixtureProblem -Stream $stream -Code 'Guests.CreationOperationConflict'
                        }
                        continue
                    }

                    $guestPath = "$guestCollectionPath/$script:guestId"
                    if ($method -ceq 'GET' -and $path -ceq $guestPath) {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-GuestDetail)
                        continue
                    }
                    if ($method -ceq 'GET' -and
                        $path.StartsWith("${guestCollectionPath}?", [StringComparison]::Ordinal)) {
                        $requestedStatus = if ($path.Contains('status=2', [StringComparison]::Ordinal)) {
                            2
                        }
                        else {
                            1
                        }
                        Write-FixtureResponse `
                            -Stream $stream `
                            -Status 200 `
                            -Reason OK `
                            -Body (New-GuestDirectory -RequestedStatus $requestedStatus)
                        continue
                    }
                    if ($method -ceq 'PUT' -and $path -ceq $guestPath) {
                        $request = $bodyText | ConvertFrom-Json -Depth 12
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if ($null -eq $script:updateOperationId) {
                            if ([long]$request.expectedVersion -ne 1 -or
                                [string]$request.displayName -ceq $script:initialGuestLabel) {
                                throw 'Fixture received an invalid first Guest update.'
                            }
                            $script:updateOperationId = $operationId
                            $script:updatedGuestLabel = [string]$request.displayName
                            $script:currentGuestLabel = $script:updatedGuestLabel
                            $script:guestVersion = 2
                            $script:guestChangedAtUtc = '2026-08-12T00:00:01.1234567+00:00'
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-GuestReceipt)
                            continue
                        }
                        if ($operationId -ceq $script:updateOperationId) {
                            if ([string]$request.displayName -ceq $script:updatedGuestLabel -and
                                [long]$request.expectedVersion -eq 1) {
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-GuestReceipt)
                            }
                            else {
                                Write-FixtureProblem -Stream $stream -Code 'Guests.ManagementOperationConflict'
                            }
                            continue
                        }
                        if ([long]$request.expectedVersion -ne $script:guestVersion) {
                            Write-FixtureProblem -Stream $stream -Code 'Guests.VersionConflict'
                            continue
                        }
                        throw 'Fixture received an unexpected additional Guest update.'
                    }

                    $reservationCollectionPath = "/api/reservations/properties/$($Fixture.PropertyId)"
                    if ($method -ceq 'POST' -and $path -ceq $reservationCollectionPath) {
                        $request = $bodyText | ConvertFrom-Json -Depth 12
                        if ([Guid]$request.operationId -eq [Guid]::Empty -or
                            [string]$request.arrival -cne $Fixture.Arrival -or
                            [string]$request.departure -cne $Fixture.Departure -or
                            @($request.inventoryUnitIds).Count -ne 1 -or
                            [Guid]$request.inventoryUnitIds[0] -ne [Guid]$Fixture.InventoryUnitId -or
                            [string]$request.primaryGuestName -cne $script:updatedGuestLabel -or
                            [int]$request.guestCount -ne 1 -or
                            [int]$request.sourceKind -ne 1 -or
                            $null -ne $request.email -or
                            $null -ne $request.phone -or
                            $null -ne $request.notes) {
                            throw 'Fixture received an unsafe or invalid Reservation create request.'
                        }
                        $script:reservationId = ([Guid]$request.operationId).ToString('D')
                        $script:reservationStatus = 1
                        $script:reservationVersion = 1
                        Write-Capture
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-ReservationReceipt)
                        continue
                    }

                    $reservationPath = "$reservationCollectionPath/$script:reservationId"
                    if ($method -ceq 'GET' -and $path -ceq $reservationPath) {
                        if ($script:reservationStatus -eq 1) {
                            $script:reservationStatus = 2
                            $script:reservationVersion = 2
                        }
                        elseif ($script:reservationStatus -eq 4) {
                            $script:reservationStatus = 5
                            $script:reservationVersion++
                        }
                        elseif ($script:reservationStatus -eq 9) {
                            $script:reservationStatus = 10
                            $script:reservationVersion++
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-ReservationDetail)
                        if (($Mode -ceq 'valid' -and $script:releaseSmokeSeen) -or
                            ($Mode -ceq 'archive-replay-drift' -and $script:archiveReplayCount -ge 1)) {
                            $done = $true
                        }
                        continue
                    }

                    if ($method -ceq 'PUT' -and $path -ceq "$reservationPath/guests") {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        if ([Guid]$request.guestId -ne [Guid]$script:guestId -or
                            [int]$request.role -ne 1 -or
                            [bool]$request.replaceExistingRole -or
                            [long]$request.expectedVersion -ne 2) {
                            throw 'Fixture received an invalid Reservation Guest link.'
                        }
                        $script:linkAttemptCount++
                        if ($script:linkAttemptCount -eq 1) {
                            Write-FixtureProblem -Stream $stream -Code 'Reservations.GuestNotLinkable'
                            continue
                        }
                        if (-not $script:guestLinked) {
                            $script:guestLinked = $true
                            $script:reservationVersion = 3
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-ReservationReceipt)
                        continue
                    }

                    if ($method -ceq 'GET' -and
                        $path -ceq "$guestPath/stays?page=1&pageSize=10") {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-StayHistory)
                        continue
                    }

                    if ($method -ceq 'POST' -and
                        $path.StartsWith("$reservationPath/", [StringComparison]::Ordinal)) {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $action = $path.Substring($reservationPath.Length + 1)
                        if ([Guid]$request.operationId -eq [Guid]::Empty -or
                            [long]$request.expectedVersion -ne $script:reservationVersion) {
                            throw "Fixture received an invalid '$action' operation."
                        }
                        switch ($action) {
                            'check-in' {
                                if ($script:reservationStatus -ne 2 -or
                                    [string]$request.businessDate -cne $Fixture.Arrival) {
                                    throw 'Fixture received an invalid check-in.'
                                }
                                $script:reservationStatus = 6
                                $script:reservationVersion++
                            }
                            'check-out' {
                                if ($script:reservationStatus -ne 6 -or
                                    [string]$request.businessDate -cne $Fixture.Arrival) {
                                    throw 'Fixture received an invalid checkout.'
                                }
                                $script:reservationStatus = 9
                                $script:reservationVersion++
                            }
                            'cancel' {
                                if ($script:reservationStatus -notin @(1, 2)) {
                                    throw 'Fixture received an invalid cancellation.'
                                }
                                $script:reservationStatus = 4
                                $script:reservationVersion++
                            }
                            default {
                                throw "Fixture received unexpected Reservation action '$action'."
                            }
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-ReservationReceipt)
                        continue
                    }

                    if ($method -ceq 'POST' -and $path -ceq "$guestPath/archive") {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if (-not [bool]$request.confirmed) {
                            throw 'Fixture received an unconfirmed Guest archive.'
                        }
                        if ($null -eq $script:archiveOperationId) {
                            if ([long]$request.expectedVersion -ne 2) {
                                throw 'Fixture received a stale Guest archive.'
                            }
                            $script:archiveOperationId = $operationId
                            $script:guestStatus = 2
                            $script:guestVersion = 3
                            $script:guestChangedAtUtc = '2026-08-12T00:00:02.1234567+00:00'
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-GuestReceipt)
                            continue
                        }
                        if ($operationId -cne $script:archiveOperationId -or
                            [long]$request.expectedVersion -ne 2) {
                            throw 'Fixture received changed Guest archive replay input.'
                        }
                        $script:archiveReplayCount++
                        Write-FixtureResponse `
                            -Stream $stream `
                            -Status 200 `
                            -Reason OK `
                            -Body (New-GuestReceipt `
                                -ArchiveReplayDrift:($Mode -ceq 'archive-replay-drift'))
                        continue
                    }

                    throw "Fixture received unexpected request '$method $path'."
                }
                finally {
                    $tcpClient.Dispose()
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
        throw "The $Mode Guests stay-history fixture did not become ready."
    }
    $port = [int](Get-Content -LiteralPath $readyPath -Raw)
    return [pscustomobject]@{
        Job = $job
        Origin = [Uri]"http://127.0.0.1:$port"
        CapturePath = $capturePath
    }
}

function Complete-BunkFyGuestsStayHistoryFixtureServer {
    param([Parameter(Mandatory = $true)][object] $Server)

    try {
        $completed = Wait-Job -Job $Server.Job -Timeout 15
        if ($null -eq $completed) {
            throw 'The Guests stay-history fixture server did not terminate after the probe.'
        }
        $output = @(Receive-Job -Job $Server.Job -ErrorAction Stop)
        if ($Server.Job.State -ne 'Completed') {
            throw "The Guests stay-history fixture ended in state '$($Server.Job.State)': $($output -join [Environment]::NewLine)"
        }
    }
    finally {
        Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    }
}

function Stop-BunkFyGuestsStayHistoryFixtureServer {
    param([AllowNull()][object] $Server)

    if ($null -eq $Server) {
        return
    }
    Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
}

function Invoke-BunkFyGuestsStayHistoryFixtureProbe {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'archive-replay-drift')]
        [string] $Mode,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $server = $null
    try {
        $server = Start-BunkFyGuestsStayHistoryFixtureServer -Mode $Mode
        $operatorToken = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        $deniedToken = ConvertTo-SecureString $fixture.DeniedToken -AsPlainText -Force
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
                -OperatorAccessToken $operatorToken `
                -DeniedAccessToken $deniedToken `
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
        $serverError = $null
        try {
            Complete-BunkFyGuestsStayHistoryFixtureServer -Server $server
        }
        catch {
            $serverError = $_
        }
        $capture = if (Test-Path -LiteralPath $server.CapturePath -PathType Leaf) {
            Get-Content -LiteralPath $server.CapturePath -Raw | ConvertFrom-Json
        }
        else {
            $null
        }
        $server = $null
        if ($null -ne $probeError) {
            if ($null -ne $serverError) {
                throw "Probe failed: $($probeError.Exception.Message) Fixture failed: $($serverError.Exception.Message)"
            }
            throw $probeError
        }
        if ($null -ne $serverError) {
            throw $serverError
        }
        return $capture
    }
    finally {
        Stop-BunkFyGuestsStayHistoryFixtureServer -Server $server
    }
}

try {
    $validOutput = Join-Path $fixtureRoot 'valid-evidence.json'
    $capture = Invoke-BunkFyGuestsStayHistoryFixtureProbe `
        -Mode valid `
        -OutputPath $validOutput
    if ($null -eq $capture) {
        throw 'The valid Guests fixture did not capture synthetic coordinates.'
    }

    $evidence = Get-Content -LiteralPath $validOutput -Raw |
        ConvertFrom-Json -Depth 12
    if ($evidence.schemaVersion -ne 1 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-guests-stay-history-probe' -or
        $evidence.result -cne 'passed' -or
        $evidence.releaseId -cne $fixture.ReleaseId -or
        $evidence.workflow.guestFinalStatus -cne 'archived' -or
        $evidence.workflow.reservationFinalStatus -cne 'checked-out' -or
        $evidence.workflow.stayFinalStatus -cne 'checked-out' -or
        $evidence.workflow.stayCount -ne 1 -or
        -not [bool]$evidence.workflow.guestVersionAdvanced -or
        -not [bool]$evidence.workflow.reservationVersionsMonotonic -or
        -not [bool]$evidence.cleanup.guestArchived -or
        -not [bool]$evidence.cleanup.inventoryReleased -or
        @($evidence.checks).Count -ne 19 -or
        @($evidence.limitations).Count -ne 4) {
        throw 'The valid Guests stay-history fixture produced invalid evidence.'
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
            $fixture.DeniedToken,
            [string]$capture.guestId,
            [string]$capture.reservationId,
            [string]$capture.initialGuestLabel,
            [string]$capture.updatedGuestLabel,
            'Authorization',
            'X-Tenant-Id')) {
        if ($evidenceText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Guests stay-history evidence retained scoped, personal, or credential data.'
        }
    }
    foreach ($stayDate in @($fixture.Arrival, $fixture.Departure)) {
        if ($evidenceText.Contains(
                '"' + $stayDate + '"',
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Guests stay-history evidence retained a synthetic stay date.'
        }
    }

    $driftOutput = Join-Path $fixtureRoot 'archive-replay-drift-evidence.json'
    $driftRejected = $false
    try {
        [void](Invoke-BunkFyGuestsStayHistoryFixtureProbe `
                -Mode archive-replay-drift `
                -OutputPath $driftOutput)
    }
    catch {
        $driftRejected = $_.Exception.Message.Contains(
            'exact Guest archive replay',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $driftRejected -or (Test-Path -LiteralPath $driftOutput)) {
        throw 'The Guests stay-history probe accepted archive replay drift or wrote passing evidence.'
    }

    $insecureOriginRejected = $false
    try {
        $operatorToken = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        $deniedToken = ConvertTo-SecureString $fixture.DeniedToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://guests.example.test:8080') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -InventoryUnitId $fixture.InventoryUnitId `
            -Arrival $fixture.Arrival `
            -Departure $fixture.Departure `
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
        throw 'The Guests stay-history probe accepted insecure non-loopback HTTP.'
    }

    Write-Host 'BunkFy deployed Guests stay-history fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
