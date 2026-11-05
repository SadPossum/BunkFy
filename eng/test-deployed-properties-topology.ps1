Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-properties-topology.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-properties-topology-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$fixture = [pscustomobject]@{
    ReleaseId = 'release-properties-fixture-001'
    AdmissionEvidenceReference = 'admission:11111111111111111111111111111111'
    WorkspaceId = '11111111-1111-4111-8111-111111111111'
    MembershipId = '12121212-1212-4212-8212-121212121212'
    SubjectId = '13131313-1313-4313-8313-131313131313'
    RoomId = '22222222-2222-4222-8222-222222222222'
    FirstBedId = '33333333-3333-4333-8333-333333333333'
    SecondBedId = '44444444-4444-4444-8444-444444444444'
    BedTopologyChangeId = '55555555-5555-4555-8555-555555555555'
    RoomTopologyChangeId = '66666666-6666-4666-8666-666666666666'
    DriftTopologyChangeId = '77777777-7777-4777-8777-777777777777'
    OperatorToken = 'fixture-properties-operator-token-do-not-retain'
    DeniedToken = 'fixture-properties-nonmember-token-do-not-retain'
}

function Start-BunkFyPropertiesTopologyFixtureServer {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'room-retirement-replay-drift')]
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
                $Body | ConvertTo-Json -Depth 16 -Compress
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

        function Write-Capture {
            $retiredBeds = @($script:beds | Where-Object { [int]$_.status -eq 2 }).Count
            $capture = [ordered]@{
                propertyId = $script:propertyId
                propertyStatus = $script:propertyStatus
                propertyVersion = $script:propertyVersion
                roomStatus = $script:roomStatus
                roomVersion = $script:roomVersion
                retiredBedCount = $retiredBeds
                bedProjectionMisses = $script:bedProjectionMisses
                roomProjectionMisses = $script:roomProjectionMisses
                replayDriftEmitted = $script:replayDriftEmitted
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

        function New-PropertyReceipt {
            param(
                [Parameter(Mandatory = $true)][int] $Status,
                [Parameter(Mandatory = $true)][long] $Version
            )

            return [ordered]@{
                propertyId = $script:propertyId
                status = $Status
                processingStatus = 1
                version = $Version
            }
        }

        function New-PropertyDetails {
            return [ordered]@{
                propertyId = $script:propertyId
                name = $script:propertyName
                code = $script:propertyCode
                timeZoneId = 'UTC'
                status = $script:propertyStatus
                processingStatus = 1
                version = $script:propertyVersion
                createdAtUtc = '2026-08-13T00:00:00.1000000+00:00'
                lastChangedAtUtc = '2026-08-13T00:00:00.9000000+00:00'
                retiredAtUtc = if ($script:propertyStatus -eq 2) {
                    '2026-08-13T00:00:00.9000000+00:00'
                }
                else {
                    $null
                }
            }
        }

        function New-PropertyDirectory {
            $properties = [Collections.Generic.List[object]]::new()
            if ($null -ne $script:propertyId) {
                [void]$properties.Add([ordered]@{
                        propertyId = $script:propertyId
                        name = $script:propertyName
                        code = $script:propertyCode
                        timeZoneId = 'UTC'
                        status = $script:propertyStatus
                        processingStatus = 1
                        version = $script:propertyVersion
                    })
            }
            return [ordered]@{
                properties = $properties
                page = 1
                pageSize = 100
                hasMore = $false
            }
        }

        function New-RoomReceipt {
            param([Parameter(Mandatory = $true)][long] $Version)

            return [ordered]@{
                propertyId = $script:propertyId
                roomId = $Fixture.RoomId
                status = 1
                version = $Version
            }
        }

        function New-RoomDetails {
            return [ordered]@{
                propertyId = $script:propertyId
                roomId = $Fixture.RoomId
                name = $script:roomName
                buildingLabel = $script:buildingLabel
                floorLabel = $script:floorLabel
                status = $script:roomStatus
                version = $script:roomVersion
                createdAtUtc = '2026-08-13T00:00:00.3000000+00:00'
                lastChangedAtUtc = '2026-08-13T00:00:00.8000000+00:00'
                retiredAtUtc = if ($script:roomStatus -eq 2) {
                    '2026-08-13T00:00:00.8000000+00:00'
                }
                else {
                    $null
                }
            }
        }

        function New-RoomDirectory {
            $rooms = [Collections.Generic.List[object]]::new()
            if ($script:roomCreated) {
                [void]$rooms.Add([ordered]@{
                        propertyId = $script:propertyId
                        roomId = $Fixture.RoomId
                        name = $script:roomName
                        buildingLabel = $script:buildingLabel
                        floorLabel = $script:floorLabel
                        status = $script:roomStatus
                        version = $script:roomVersion
                    })
            }
            return [ordered]@{
                rooms = $rooms
                page = 1
                pageSize = 100
                hasMore = $false
            }
        }

        function New-BedDirectory {
            $items = [Collections.Generic.List[object]]::new()
            foreach ($bed in $script:beds) {
                [void]$items.Add([ordered]@{
                        propertyId = $script:propertyId
                        roomId = $Fixture.RoomId
                        bedId = $bed.bedId
                        label = $bed.label
                        status = $bed.status
                        version = $bed.version
                        roomVersion = $script:roomVersion
                        createdAtUtc = '2026-08-13T00:00:00.5000000+00:00'
                        lastChangedAtUtc = '2026-08-13T00:00:00.8000000+00:00'
                        retiredAtUtc = if ([int]$bed.status -eq 2) {
                            '2026-08-13T00:00:00.8000000+00:00'
                        }
                        else {
                            $null
                        }
                    })
            }
            return [ordered]@{
                beds = $items
                page = 1
                pageSize = 100
                hasMore = $false
            }
        }

        function New-BedReceipt {
            return [ordered]@{
                propertyId = $script:propertyId
                roomId = $Fixture.RoomId
                bedId = $Fixture.FirstBedId
                status = 1
                version = 2
                roomVersion = 5
            }
        }

        function New-RetirementProcess {
            param(
                [Parameter(Mandatory = $true)][ValidateSet('bed', 'room')][string] $Kind,
                [Guid] $TopologyChangeId
            )

            $isBed = $Kind -ceq 'bed'
            $status = if ($isBed) { $script:bedRetirementStatus } else { $script:roomRetirementStatus }
            $version = if ($isBed) { $script:bedRetirementVersion } else { $script:roomRetirementVersion }
            $reason = if ($isBed) { $script:bedRetirementReason } else { $script:roomRetirementReason }
            if ($null -eq $TopologyChangeId -or $TopologyChangeId -eq [Guid]::Empty) {
                $TopologyChangeId = if ($isBed) {
                    [Guid]$Fixture.BedTopologyChangeId
                }
                else {
                    [Guid]$Fixture.RoomTopologyChangeId
                }
            }
            $process = [ordered]@{
                topologyChangeId = $TopologyChangeId.ToString('D')
                propertyId = $script:propertyId
                roomId = $Fixture.RoomId
                reason = $reason
                requestedBy = $Fixture.SubjectId
                status = $status
                rejectionReason = $null
                cancellationReason = $null
                canceledBy = $null
                activeAllocationCount = 0
                activeManualBlockCount = 0
                affectedReservationIds = @()
                affectedReservationIdsTruncated = $false
                version = $version
                createdAtUtc = '2026-08-13T00:00:00.6000000+00:00'
                updatedAtUtc = '2026-08-13T00:00:00.8000000+00:00'
                completedAtUtc = if ($status -eq 4) {
                    '2026-08-13T00:00:00.8000000+00:00'
                }
                else {
                    $null
                }
            }
            if ($isBed) {
                $process.bedId = $Fixture.FirstBedId
            }
            else {
                $process.activeBedRetirementCount = 0
            }
            return $process
        }

        function Complete-BedRetirement {
            $script:bedRetirementStatus = 4
            $script:bedRetirementVersion = 3
            $script:beds[0].status = 2
            $script:beds[0].version = 3
            $script:roomVersion = 6
            Write-Capture
        }

        function Complete-RoomRetirement {
            $script:roomRetirementStatus = 4
            $script:roomRetirementVersion = 3
            $script:roomStatus = 2
            $script:roomVersion = 7
            if ($script:beds.Count -eq 2) {
                $script:beds[0].status = 2
                if ([int]$script:beds[0].version -lt 3) {
                    $script:beds[0].version = 3
                }
                $script:beds[1].status = 2
                $script:beds[1].version = 2
            }
            Write-Capture
        }

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)

            $script:propertyId = $null
            $script:propertyName = $null
            $script:propertyCode = $null
            $script:propertyStatus = 0
            $script:propertyVersion = 0L
            $script:createPropertyOperationId = $null
            $script:updatePropertyOperationId = $null
            $script:propertyRetirementOperationId = $null
            $script:propertyRetirementExpectedVersion = 0L
            $script:roomCreated = $false
            $script:roomName = $null
            $script:buildingLabel = $null
            $script:floorLabel = $null
            $script:roomStatus = 0
            $script:roomVersion = 0L
            $script:createRoomOperationId = $null
            $script:updateRoomOperationId = $null
            $script:addBedsOperationId = $null
            $script:updateBedOperationId = $null
            $script:beds = [Collections.Generic.List[object]]::new()
            $script:bedRetirementOperationId = $null
            $script:bedRetirementReason = $null
            $script:bedRetirementStatus = 0
            $script:bedRetirementVersion = 0L
            $script:bedRetirementReads = 0
            $script:roomRetirementOperationId = $null
            $script:roomRetirementReason = $null
            $script:roomRetirementStatus = 0
            $script:roomRetirementVersion = 0L
            $script:roomRetirementReads = 0
            $script:bedProjectionMisses = 0
            $script:roomProjectionMisses = 0
            $script:replayDriftEmitted = $false
            $script:releaseSmokeSeen = $false
            $script:postReleasePropertyReads = 0
            $done = $false
            $requestCount = 0
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(8)
            while (-not $done -and
                $requestCount -lt 100 -and
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
                                $read = $reader.Read($buffer, $offset, $contentLength - $offset)
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
                                admissionEvidenceReference = $Fixture.AdmissionEvidenceReference
                                timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                            })
                        if ($script:propertyStatus -eq 2) {
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

                    if ($authorization -ceq "Bearer $($Fixture.DeniedToken)" -and
                        $method -ceq 'GET' -and
                        $path -ceq '/api/properties?page=1&pageSize=1') {
                        Write-FixtureProblem -Stream $stream -Code 'Access.Forbidden' -Status 403 -Reason Forbidden
                        continue
                    }
                    if ($authorization -cne "Bearer $($Fixture.OperatorToken)") {
                        throw 'Fixture request used the wrong authorization token.'
                    }

                    if ($method -ceq 'GET' -and
                        $path -ceq '/api/organizations?page=1&pageSize=100') {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-MembershipPage)
                        continue
                    }

                    if ($method -ceq 'POST' -and $path -ceq '/api/properties') {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if ([string]$request.timeZoneId -cne 'UTC') {
                            throw 'Fixture received an invalid property time zone.'
                        }
                        if ($null -eq $script:propertyId) {
                            if ([Guid]$request.operationId -eq [Guid]::Empty) {
                                throw 'Fixture received an empty property creation operation.'
                            }
                            $script:propertyId = $operationId
                            $script:createPropertyOperationId = $operationId
                            $script:propertyName = [string]$request.name
                            $script:propertyCode = [string]$request.code
                            $script:propertyStatus = 1
                            $script:propertyVersion = 1
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-PropertyReceipt -Status 1 -Version 1)
                            continue
                        }
                        if ($operationId -cne $script:createPropertyOperationId) {
                            throw 'Fixture received a different property creation operation.'
                        }
                        if ([string]$request.name -cne $script:propertyName -or
                            [string]$request.code -cne $script:propertyCode) {
                            Write-FixtureProblem -Stream $stream -Code 'Properties.CreationOperationConflict'
                            continue
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-PropertyReceipt -Status 1 -Version 1)
                        continue
                    }

                    $propertyPath = "/api/properties/$script:propertyId"
                    if ($method -ceq 'GET' -and $path -ceq $propertyPath) {
                        if ($null -eq $script:propertyId) {
                            Write-FixtureProblem -Stream $stream -Code 'Properties.PropertyNotFound' -Status 404 -Reason 'Not Found'
                            continue
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-PropertyDetails)
                        if ($script:releaseSmokeSeen) {
                            $script:postReleasePropertyReads++
                            if ($script:postReleasePropertyReads -ge 3) {
                                Write-Capture
                                $done = $true
                            }
                        }
                        elseif ($Mode -ceq 'room-retirement-replay-drift' -and
                            $script:replayDriftEmitted -and
                            $script:propertyStatus -eq 2 -and
                            $script:roomStatus -eq 2 -and
                            @($script:beds | Where-Object { [int]$_.status -eq 2 }).Count -eq 2) {
                            Write-Capture
                            $done = $true
                        }
                        continue
                    }

                    if ($method -ceq 'GET' -and $path -ceq '/api/properties?page=1&pageSize=100') {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-PropertyDirectory)
                        continue
                    }

                    if ($method -ceq 'PUT' -and $path -ceq $propertyPath) {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if ($null -eq $script:updatePropertyOperationId) {
                            if ([long]$request.expectedVersion -ne 1 -or
                                [string]$request.timeZoneId -cne 'UTC') {
                                throw 'Fixture received an invalid first property update.'
                            }
                            $script:updatePropertyOperationId = $operationId
                            $script:propertyName = [string]$request.name
                            $script:propertyCode = [string]$request.code
                            $script:propertyVersion = 2
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-PropertyReceipt -Status 1 -Version 2)
                            continue
                        }
                        if ($operationId -ceq $script:updatePropertyOperationId) {
                            if ([string]$request.name -cne $script:propertyName -or
                                [string]$request.code -cne $script:propertyCode -or
                                [long]$request.expectedVersion -ne 1) {
                                Write-FixtureProblem -Stream $stream -Code 'Properties.ManagementOperationConflict'
                                continue
                            }
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-PropertyReceipt -Status 1 -Version 2)
                            continue
                        }
                        if ([long]$request.expectedVersion -ne $script:propertyVersion) {
                            Write-FixtureProblem -Stream $stream -Code 'Properties.VersionConflict'
                            continue
                        }
                        throw 'Fixture received an unexpected additional property update.'
                    }

                    $roomsPath = "$propertyPath/rooms"
                    if ($method -ceq 'POST' -and $path -ceq $roomsPath) {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if (-not $script:roomCreated) {
                            if ([long]$request.expectedPropertyVersion -ne 2) {
                                throw 'Fixture received an invalid property version for room creation.'
                            }
                            $script:createRoomOperationId = $operationId
                            $script:roomName = [string]$request.name
                            $script:buildingLabel = [string]$request.buildingLabel
                            $script:floorLabel = [string]$request.floorLabel
                            $script:roomCreated = $true
                            $script:roomStatus = 1
                            $script:roomVersion = 1
                            $script:propertyVersion = 3
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-RoomReceipt -Version 1)
                            continue
                        }
                        if ($operationId -cne $script:createRoomOperationId -or
                            [string]$request.name -cne $script:roomName -or
                            [string]$request.buildingLabel -cne $script:buildingLabel -or
                            [string]$request.floorLabel -cne $script:floorLabel -or
                            [long]$request.expectedPropertyVersion -ne 2) {
                            Write-FixtureProblem -Stream $stream -Code 'Properties.ManagementOperationConflict'
                            continue
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-RoomReceipt -Version 1)
                        continue
                    }

                    if ($method -ceq 'GET' -and $path -ceq "${roomsPath}?page=1&pageSize=100") {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-RoomDirectory)
                        continue
                    }

                    $roomPath = "$roomsPath/$($Fixture.RoomId)"
                    if ($method -ceq 'GET' -and $path -ceq $roomPath) {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-RoomDetails)
                        continue
                    }

                    if ($method -ceq 'PUT' -and $path -ceq $roomPath) {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if ($null -eq $script:updateRoomOperationId) {
                            if ([long]$request.expectedVersion -ne 1) {
                                throw 'Fixture received an invalid first room update.'
                            }
                            $script:updateRoomOperationId = $operationId
                            $script:roomName = [string]$request.name
                            $script:buildingLabel = [string]$request.buildingLabel
                            $script:floorLabel = [string]$request.floorLabel
                            $script:roomVersion = 2
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-RoomReceipt -Version 2)
                            continue
                        }
                        if ($operationId -ceq $script:updateRoomOperationId) {
                            if ([string]$request.name -cne $script:roomName -or
                                [string]$request.buildingLabel -cne $script:buildingLabel -or
                                [string]$request.floorLabel -cne $script:floorLabel -or
                                [long]$request.expectedVersion -ne 1) {
                                Write-FixtureProblem -Stream $stream -Code 'Properties.ManagementOperationConflict'
                                continue
                            }
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-RoomReceipt -Version 2)
                            continue
                        }
                        if ([long]$request.expectedVersion -ne $script:roomVersion) {
                            Write-FixtureProblem -Stream $stream -Code 'Properties.VersionConflict'
                            continue
                        }
                        throw 'Fixture received an unexpected additional room update.'
                    }

                    $bedsPath = "$roomPath/beds"
                    if ($method -ceq 'POST' -and $path -ceq "$bedsPath/batch") {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        $labels = @($request.labels)
                        if ($script:beds.Count -eq 0) {
                            if ([long]$request.expectedRoomVersion -ne 2 -or $labels.Count -ne 2) {
                                throw 'Fixture received an invalid bed batch.'
                            }
                            $script:addBedsOperationId = $operationId
                            [void]$script:beds.Add([pscustomobject]@{
                                    bedId = $Fixture.FirstBedId
                                    label = [string]$labels[0]
                                    status = 1
                                    version = 1
                                })
                            [void]$script:beds.Add([pscustomobject]@{
                                    bedId = $Fixture.SecondBedId
                                    label = [string]$labels[1]
                                    status = 1
                                    version = 1
                                })
                            $script:roomVersion = 4
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                                    propertyId = $script:propertyId
                                    roomId = $Fixture.RoomId
                                    affectedBedCount = 2
                                    roomVersion = 4
                                })
                            continue
                        }
                        if ($operationId -cne $script:addBedsOperationId -or
                            $labels.Count -ne 2 -or
                            [string]$labels[0] -cne [string]$script:beds[0].label -or
                            [string]$labels[1] -cne [string]$script:beds[1].label -or
                            [long]$request.expectedRoomVersion -ne 2) {
                            Write-FixtureProblem -Stream $stream -Code 'Properties.ManagementOperationConflict'
                            continue
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                                propertyId = $script:propertyId
                                roomId = $Fixture.RoomId
                                affectedBedCount = 2
                                roomVersion = 4
                            })
                        continue
                    }

                    if ($method -ceq 'GET' -and $path -ceq "${bedsPath}?page=1&pageSize=100") {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-BedDirectory)
                        continue
                    }

                    $firstBedPath = "$bedsPath/$($Fixture.FirstBedId)"
                    if ($method -ceq 'PUT' -and $path -ceq $firstBedPath) {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if ($null -eq $script:updateBedOperationId) {
                            if ([long]$request.expectedRoomVersion -ne 4) {
                                throw 'Fixture received an invalid first bed update.'
                            }
                            $script:updateBedOperationId = $operationId
                            $script:beds[0].label = [string]$request.label
                            $script:beds[0].version = 2
                            $script:roomVersion = 5
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-BedReceipt)
                            continue
                        }
                        if ($operationId -ceq $script:updateBedOperationId) {
                            if ([string]$request.label -cne [string]$script:beds[0].label -or
                                [long]$request.expectedRoomVersion -ne 4) {
                                Write-FixtureProblem -Stream $stream -Code 'Properties.ManagementOperationConflict'
                                continue
                            }
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-BedReceipt)
                            continue
                        }
                        if ([long]$request.expectedRoomVersion -ne $script:roomVersion) {
                            Write-FixtureProblem -Stream $stream -Code 'Properties.VersionConflict'
                            continue
                        }
                        throw 'Fixture received an unexpected additional bed update.'
                    }

                    if ($method -ceq 'POST' -and $path -ceq "$propertyPath/retire") {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if (-not [bool]$request.confirmed) {
                            throw 'Fixture received an unconfirmed property retirement.'
                        }
                        if ($script:roomStatus -eq 1) {
                            Write-FixtureProblem -Stream $stream -Code 'Properties.PropertyHasActiveRooms'
                            continue
                        }
                        if ($null -eq $script:propertyRetirementOperationId) {
                            if ([long]$request.expectedVersion -ne $script:propertyVersion) {
                                Write-FixtureProblem -Stream $stream -Code 'Properties.VersionConflict'
                                continue
                            }
                            $script:propertyRetirementOperationId = $operationId
                            $script:propertyRetirementExpectedVersion = [long]$request.expectedVersion
                            $script:propertyStatus = 2
                            $script:propertyVersion++
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-PropertyReceipt -Status 2 -Version $script:propertyVersion)
                            continue
                        }
                        if ($operationId -cne $script:propertyRetirementOperationId -or
                            [long]$request.expectedVersion -ne $script:propertyRetirementExpectedVersion) {
                            Write-FixtureProblem -Stream $stream -Code 'Properties.ManagementOperationConflict'
                            continue
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-PropertyReceipt -Status 2 -Version $script:propertyVersion)
                        continue
                    }

                    if ($method -ceq 'POST' -and $path -ceq "$firstBedPath/retire") {
                        Write-FixtureProblem -Stream $stream -Code 'Properties.BedRetirementRequiresInventory'
                        continue
                    }
                    if ($method -ceq 'POST' -and $path -ceq "$roomPath/retire") {
                        Write-FixtureProblem -Stream $stream -Code 'Properties.RoomRetirementRequiresInventory'
                        continue
                    }

                    $inventoryRoomPath = "/api/inventory/properties/$script:propertyId/rooms/$($Fixture.RoomId)"
                    $bedRetirementPath = "$inventoryRoomPath/beds/$($Fixture.FirstBedId)/retirement"
                    if ($method -ceq 'POST' -and $path -ceq $bedRetirementPath) {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if (-not [bool]$request.confirmed) {
                            throw 'Fixture received an unconfirmed bed retirement.'
                        }
                        if ($script:bedProjectionMisses -eq 0) {
                            $script:bedProjectionMisses = 1
                            Write-Capture
                            Write-FixtureProblem -Stream $stream -Code 'Inventory.InventoryUnitNotFound' -Status 404 -Reason 'Not Found'
                            continue
                        }
                        if ($null -eq $script:bedRetirementOperationId) {
                            $script:bedRetirementOperationId = $operationId
                            $script:bedRetirementReason = [string]$request.reason
                            $script:bedRetirementStatus = 2
                            $script:bedRetirementVersion = 1
                            Write-Capture
                        }
                        elseif ($operationId -cne $script:bedRetirementOperationId -or
                            [string]$request.reason -cne $script:bedRetirementReason) {
                            Write-FixtureProblem -Stream $stream -Code 'Inventory.RetirementRequestConflict'
                            continue
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-RetirementProcess -Kind bed)
                        continue
                    }

                    $bedRetirementReadPath = "/api/inventory/properties/$script:propertyId/bed-retirements/$($Fixture.BedTopologyChangeId)"
                    if ($method -ceq 'GET' -and $path -ceq $bedRetirementReadPath) {
                        if ($script:bedRetirementStatus -ne 4) {
                            $script:bedRetirementReads++
                            if ($script:bedRetirementReads -eq 1) {
                                $script:bedRetirementStatus = 3
                                $script:bedRetirementVersion = 2
                            }
                            else {
                                Complete-BedRetirement
                            }
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-RetirementProcess -Kind bed)
                        continue
                    }

                    $roomRetirementPath = "$inventoryRoomPath/retirement"
                    if ($method -ceq 'POST' -and $path -ceq $roomRetirementPath) {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if (-not [bool]$request.confirmed) {
                            throw 'Fixture received an unconfirmed room retirement.'
                        }
                        if ($script:roomProjectionMisses -eq 0) {
                            $script:roomProjectionMisses = 1
                            Write-Capture
                            Write-FixtureProblem -Stream $stream -Code 'Inventory.RoomNotFound' -Status 404 -Reason 'Not Found'
                            continue
                        }
                        if ($null -eq $script:roomRetirementOperationId) {
                            $script:roomRetirementOperationId = $operationId
                            $script:roomRetirementReason = [string]$request.reason
                            $script:roomRetirementStatus = 2
                            $script:roomRetirementVersion = 1
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-RetirementProcess -Kind room)
                            continue
                        }
                        if ($operationId -cne $script:roomRetirementOperationId -or
                            [string]$request.reason -cne $script:roomRetirementReason) {
                            Write-FixtureProblem -Stream $stream -Code 'Inventory.RetirementRequestConflict'
                            continue
                        }
                        if ($Mode -ceq 'room-retirement-replay-drift' -and
                            -not $script:replayDriftEmitted) {
                            $script:replayDriftEmitted = $true
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-RetirementProcess -Kind room -TopologyChangeId ([Guid]$Fixture.DriftTopologyChangeId))
                            continue
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-RetirementProcess -Kind room)
                        continue
                    }

                    $roomRetirementReadPath = "/api/inventory/properties/$script:propertyId/room-retirements/$($Fixture.RoomTopologyChangeId)"
                    if ($method -ceq 'GET' -and $path -ceq $roomRetirementReadPath) {
                        if ($script:roomRetirementStatus -ne 4) {
                            $script:roomRetirementReads++
                            if ($script:roomRetirementReads -eq 1) {
                                $script:roomRetirementStatus = 3
                                $script:roomRetirementVersion = 2
                            }
                            else {
                                Complete-RoomRetirement
                            }
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-RetirementProcess -Kind room)
                        continue
                    }

                    if ($method -ceq 'GET' -and $path -ceq "$propertyPath/processing") {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                                propertyId = $script:propertyId
                                configuredStatus = 1
                                effectiveStatus = 3
                                reasonCode = 'Properties.PropertyRetired'
                                governancePolicy = $null
                                propertyVersion = $script:propertyVersion
                            })
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
        throw "The $Mode Properties topology fixture did not become ready."
    }
    $port = [int](Get-Content -LiteralPath $readyPath -Raw)
    return [pscustomobject]@{
        Job = $job
        Origin = [Uri]"http://127.0.0.1:$port"
        CapturePath = $capturePath
    }
}

function Complete-BunkFyPropertiesTopologyFixtureServer {
    param([Parameter(Mandatory = $true)][object] $Server)

    try {
        $completed = Wait-Job -Job $Server.Job -Timeout 15
        if ($null -eq $completed) {
            throw 'The Properties topology fixture server did not terminate after the probe.'
        }
        $receiveErrors = @()
        $output = @(Receive-Job `
                -Job $Server.Job `
                -ErrorAction SilentlyContinue `
                -ErrorVariable receiveErrors)
        if ($Server.Job.State -ne 'Completed') {
            $details = @($receiveErrors | ForEach-Object {
                    ($_ | Format-List * -Force | Out-String).Trim()
                })
            $reason = $Server.Job.ChildJobs[0].JobStateInfo.Reason
            if ($null -ne $reason) {
                $details += ($reason | Format-List * -Force | Out-String).Trim()
            }
            throw "The Properties topology fixture ended in state '$($Server.Job.State)': $(@($output + $details) -join [Environment]::NewLine)"
        }
    }
    finally {
        Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    }
}

function Stop-BunkFyPropertiesTopologyFixtureServer {
    param([AllowNull()][object] $Server)

    if ($null -eq $Server) {
        return
    }
    Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
}

function Invoke-BunkFyPropertiesTopologyFixtureProbe {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'room-retirement-replay-drift')]
        [string] $Mode,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $server = $null
    try {
        $server = Start-BunkFyPropertiesTopologyFixtureServer -Mode $Mode
        $operatorToken = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        $deniedToken = ConvertTo-SecureString $fixture.DeniedToken -AsPlainText -Force
        $probeError = $null
        try {
            & $probeScript `
                -PublicOrigin $server.Origin `
                -ExpectedReleaseId $fixture.ReleaseId `
                -WorkspaceId $fixture.WorkspaceId `
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
            Complete-BunkFyPropertiesTopologyFixtureServer -Server $server
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
        Stop-BunkFyPropertiesTopologyFixtureServer -Server $server
    }
}

try {
    $validOutput = Join-Path $fixtureRoot 'valid-evidence.json'
    $capture = Invoke-BunkFyPropertiesTopologyFixtureProbe -Mode valid -OutputPath $validOutput
    if ($null -eq $capture -or
        [int]$capture.propertyStatus -ne 2 -or
        [int]$capture.propertyVersion -ne 4 -or
        [int]$capture.roomStatus -ne 2 -or
        [int]$capture.roomVersion -ne 7 -or
        [int]$capture.retiredBedCount -ne 2 -or
        [int]$capture.bedProjectionMisses -ne 1 -or
        [int]$capture.roomProjectionMisses -ne 1 -or
        [bool]$capture.replayDriftEmitted) {
        throw 'The valid Properties topology fixture did not reach the expected terminal state.'
    }

    $evidence = Get-Content -LiteralPath $validOutput -Raw | ConvertFrom-Json -Depth 12
    if ($evidence.schemaVersion -ne 2 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-properties-topology-probe' -or
        $evidence.result -cne 'passed' -or
        $evidence.releaseId -cne $fixture.ReleaseId -or
        $evidence.admissionEvidenceReference -cne $fixture.AdmissionEvidenceReference -or
        $evidence.workflow.propertyFinalStatus -cne 'retired' -or
        -not [bool]$evidence.workflow.propertyVersionAdvanced -or
        $evidence.workflow.processingFinalStatus -cne 'suspended-by-retirement' -or
        $evidence.workflow.roomFinalStatus -cne 'retired' -or
        -not [bool]$evidence.workflow.roomVersionAdvanced -or
        [int]$evidence.workflow.bedCount -ne 2 -or
        [int]$evidence.workflow.retiredBedCount -ne 2 -or
        -not [bool]$evidence.workflow.bedVersionsAdvanced -or
        $evidence.workflow.retirementLifecycle -cne 'bed-then-room-completed' -or
        -not [bool]$evidence.workflow.directRetirementDenied -or
        -not [bool]$evidence.cleanup.topologyRetirementsCompleted -or
        [bool]$evidence.cleanup.parentCleanupRequired -or
        @($evidence.checks).Count -ne 31 -or
        @($evidence.limitations).Count -ne 4) {
        throw 'The valid Properties topology fixture produced invalid evidence.'
    }

    $evidenceText = Get-Content -LiteralPath $validOutput -Raw
    foreach ($sensitive in @(
            $fixture.WorkspaceId,
            $fixture.MembershipId,
            $fixture.SubjectId,
            $fixture.RoomId,
            $fixture.FirstBedId,
            $fixture.SecondBedId,
            $fixture.BedTopologyChangeId,
            $fixture.RoomTopologyChangeId,
            $fixture.OperatorToken,
            $fixture.DeniedToken,
            [string]$capture.propertyId,
            'BunkFy topology proof',
            'Topology room',
            'Verification floor',
            'Synthetic topology bed retirement',
            'Synthetic topology room retirement',
            'Authorization',
            'X-Tenant-Id',
            'timeZoneId',
            'governancePolicy')) {
        if ($evidenceText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Properties topology evidence retained scoped, topology, credential, or policy data.'
        }
    }

    $driftOutput = Join-Path $fixtureRoot 'room-retirement-replay-drift-evidence.json'
    $driftRejected = $false
    try {
        [void](Invoke-BunkFyPropertiesTopologyFixtureProbe `
                -Mode room-retirement-replay-drift `
                -OutputPath $driftOutput)
    }
    catch {
        $driftRejected = $_.Exception.Message.Contains(
            'exact room retirement replay',
            [StringComparison]::OrdinalIgnoreCase)
    }
    $driftCapturePath = Get-ChildItem `
        -LiteralPath $fixtureRoot `
        -Filter 'capture-room-retirement-replay-drift-*.json' |
        Select-Object -First 1 -ExpandProperty FullName
    $driftCapture = if ($null -ne $driftCapturePath) {
        Get-Content -LiteralPath $driftCapturePath -Raw | ConvertFrom-Json
    }
    else {
        $null
    }
    if (-not $driftRejected -or
        (Test-Path -LiteralPath $driftOutput) -or
        $null -eq $driftCapture -or
        -not [bool]$driftCapture.replayDriftEmitted -or
        [int]$driftCapture.propertyStatus -ne 2 -or
        [int]$driftCapture.roomStatus -ne 2 -or
        [int]$driftCapture.retiredBedCount -ne 2) {
        throw 'The Properties topology probe accepted replay drift, wrote passing evidence, or failed terminal cleanup.'
    }

    $insecureOriginRejected = $false
    try {
        $operatorToken = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        $deniedToken = ConvertTo-SecureString $fixture.DeniedToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://properties.example.test:8080') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
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
        throw 'The Properties topology probe accepted insecure non-loopback HTTP.'
    }

    Write-Host 'BunkFy deployed Properties topology fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
