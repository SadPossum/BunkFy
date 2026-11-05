Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-staff-employment.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-staff-employment-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$fixture = [pscustomobject]@{
    ReleaseId = 'release-staff-fixture-001'
    AdmissionEvidenceReference = 'admission:11111111111111111111111111111111'
    WorkspaceId = '11111111-1111-4111-8111-111111111111'
    PropertyId = '22222222-2222-4222-8222-222222222222'
    MembershipId = '33333333-3333-4333-8333-333333333333'
    SubjectId = '44444444-4444-4444-8444-444444444444'
    AssignmentId = '55555555-5555-4555-8555-555555555555'
    OperatorToken = 'fixture-staff-operator-token-do-not-retain'
    DeniedToken = 'fixture-staff-nonmember-token-do-not-retain'
    EffectiveDate = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
}

function Start-BunkFyStaffEmploymentFixtureServer {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'resume-replay-drift')]
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
            $capture = [ordered]@{
                staffMemberId = $script:staffMemberId
                initialLabel = $script:initialLabel
                updatedLabel = $script:updatedLabel
                finalStatus = $script:status
                currentAssignmentCount = if ($script:assignmentCurrent) { 1 } else { 0 }
                propertyUnavailableResponses = $script:propertyUnavailableResponses
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

        function New-DirectoryAssignment {
            return [ordered]@{
                assignmentId = $Fixture.AssignmentId
                propertyId = $Fixture.PropertyId
                propertyJobTitle = $null
                isPrimary = $true
                effectiveFrom = $Fixture.EffectiveDate
            }
        }

        function New-ProfileAssignment {
            return [ordered]@{
                assignmentId = $Fixture.AssignmentId
                propertyId = $Fixture.PropertyId
                propertyJobTitle = $null
                isPrimary = $true
                isCurrent = $script:assignmentCurrent
                effectiveFrom = $Fixture.EffectiveDate
                effectiveTo = if ($script:assignmentCurrent) { $null } else { $Fixture.EffectiveDate }
                assignedAtUtc = '2026-08-13T00:00:00.3000000+00:00'
                unassignedAtUtc = if ($script:assignmentCurrent) {
                    $null
                }
                else {
                    '2026-08-13T00:00:00.6000000+00:00'
                }
                assignedAtVersion = 3
                unassignedAtVersion = if ($script:assignmentCurrent) { $null } else { 6 }
            }
        }

        function New-DirectoryMember {
            $assignments = [Collections.Generic.List[object]]::new()
            if ($script:assignmentCurrent) {
                [void]$assignments.Add((New-DirectoryAssignment))
            }
            return [ordered]@{
                staffMemberId = $script:staffMemberId
                displayName = $script:currentLabel
                jobTitle = $null
                department = $null
                status = $script:status
                version = $script:version
                assignments = $assignments
            }
        }

        function New-StaffProfile {
            $assignments = [Collections.Generic.List[object]]::new()
            if ($script:assignmentEverCreated) {
                [void]$assignments.Add((New-ProfileAssignment))
            }
            return [ordered]@{
                staffMemberId = $script:staffMemberId
                displayName = $script:currentLabel
                legalName = $null
                workEmail = $null
                workPhone = $null
                employeeNumber = $null
                jobTitle = $null
                department = $null
                authSubjectId = $null
                status = $script:status
                version = $script:version
                createdAtUtc = '2026-08-13T00:00:00.1000000+00:00'
                lastChangedAtUtc = $script:lastChangedAtUtc
                suspendedAtUtc = if ($script:status -eq 2) {
                    '2026-08-13T00:00:00.4000000+00:00'
                }
                else {
                    $null
                }
                departedAtUtc = if ($script:status -eq 3) {
                    '2026-08-13T00:00:00.6000000+00:00'
                }
                else {
                    $null
                }
                assignments = $assignments
            }
        }

        function New-StaffDirectory {
            param([Parameter(Mandatory = $true)][int] $RequestedStatus)

            $items = [Collections.Generic.List[object]]::new()
            if ($script:status -eq $RequestedStatus) {
                [void]$items.Add([ordered]@{
                        staffMemberId = $script:staffMemberId
                        displayName = $script:currentLabel
                        jobTitle = $null
                        department = $null
                        status = $script:status
                        version = $script:version
                        currentPropertyCount = if ($script:assignmentCurrent) { 1 } else { 0 }
                    })
            }
            return [ordered]@{
                items = $items
                page = 1
                pageSize = 10
                hasMore = $false
            }
        }

        function New-PropertyStaffDirectory {
            param([Parameter(Mandatory = $true)][int] $RequestedStatus)

            $items = [Collections.Generic.List[object]]::new()
            if ($script:assignmentCurrent -and $script:status -eq $RequestedStatus) {
                [void]$items.Add([ordered]@{
                        staffMemberId = $script:staffMemberId
                        displayName = $script:currentLabel
                        jobTitle = $null
                        department = $null
                        status = $script:status
                        version = $script:version
                        assignment = New-DirectoryAssignment
                    })
            }
            return [ordered]@{
                items = $items
                page = 1
                pageSize = 10
                hasMore = $false
            }
        }

        function New-MutationReceipt {
            param(
                [Parameter(Mandatory = $true)][int] $Status,
                [Parameter(Mandatory = $true)][long] $Version,
                [Parameter(Mandatory = $true)][string] $CompletedAtUtc
            )

            return [ordered]@{
                staffMemberId = $script:staffMemberId
                status = $Status
                version = $Version
                completedAtUtc = $CompletedAtUtc
            }
        }

        function Get-RequestedStatus {
            param([Parameter(Mandatory = $true)][string] $Path)

            if ($Path -notmatch '(?:\?|&)status=([123])(?:&|$)') {
                throw "Fixture request omitted a valid Staff status filter: '$Path'."
            }
            return [int]$Matches[1]
        }

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)

            $script:staffMemberId = $null
            $script:initialLabel = $null
            $script:updatedLabel = $null
            $script:currentLabel = $null
            $script:status = 0
            $script:version = 0L
            $script:lastChangedAtUtc = $null
            $script:assignmentEverCreated = $false
            $script:assignmentCurrent = $false
            $script:propertyUnavailableResponses = 0
            $script:updateOperationId = $null
            $script:assignmentOperationId = $null
            $script:suspendOperationId = $null
            $script:resumeOperationId = $null
            $script:departOperationId = $null
            $script:releaseSmokeSeen = $false
            $done = $false
            $requestCount = 0
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(8)
            while (-not $done -and
                $requestCount -lt 50 -and
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
                                admissionEvidenceReference = $Fixture.AdmissionEvidenceReference
                                timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                            })
                        if ($script:status -eq 3) {
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
                        $path.StartsWith('/api/staff/members?', [StringComparison]::Ordinal)) {
                        Write-FixtureProblem `
                            -Stream $stream `
                            -Code 'Access.Forbidden' `
                            -Status 403 `
                            -Reason Forbidden
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
                    if ($method -ceq 'GET' -and
                        $path -ceq "/api/properties/$($Fixture.PropertyId)") {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                                propertyId = $Fixture.PropertyId
                                status = 1
                            })
                        continue
                    }

                    if ($method -ceq 'POST' -and $path -ceq '/api/staff/members') {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if ([Guid]$request.operationId -eq [Guid]::Empty -or
                            $null -ne $request.legalName -or
                            $null -ne $request.workEmail -or
                            $null -ne $request.workPhone -or
                            $null -ne $request.employeeNumber -or
                            $null -ne $request.jobTitle -or
                            $null -ne $request.department) {
                            throw 'Fixture received an unsafe or invalid Staff create request.'
                        }
                        if ($null -eq $script:staffMemberId) {
                            $script:staffMemberId = $operationId
                            $script:initialLabel = [string]$request.displayName
                            $script:currentLabel = $script:initialLabel
                            $script:status = 1
                            $script:version = 1
                            $script:lastChangedAtUtc = '2026-08-13T00:00:00.1000000+00:00'
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-DirectoryMember)
                            continue
                        }
                        if ($operationId -cne $script:staffMemberId) {
                            throw 'Fixture received a different Staff creation operation.'
                        }
                        if ([string]$request.displayName -cne $script:initialLabel) {
                            Write-FixtureProblem -Stream $stream -Code 'Staff.CreationOperationConflict'
                            continue
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-DirectoryMember)
                        continue
                    }

                    $memberPath = "/api/staff/members/$script:staffMemberId"
                    if ($method -ceq 'GET' -and $path -ceq $memberPath) {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-DirectoryMember)
                        continue
                    }
                    if ($method -ceq 'GET' -and $path -ceq "$memberPath/profile") {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (New-StaffProfile)
                        if (($Mode -ceq 'valid' -and $script:releaseSmokeSeen) -or
                            ($Mode -ceq 'resume-replay-drift' -and $script:status -eq 3)) {
                            Write-Capture
                            $done = $true
                        }
                        continue
                    }
                    if ($method -ceq 'GET' -and
                        $path.StartsWith('/api/staff/members?', [StringComparison]::Ordinal)) {
                        $requestedStatus = Get-RequestedStatus -Path $path
                        Write-FixtureResponse `
                            -Stream $stream `
                            -Status 200 `
                            -Reason OK `
                            -Body (New-StaffDirectory -RequestedStatus $requestedStatus)
                        continue
                    }

                    if ($method -ceq 'PUT' -and $path -ceq $memberPath) {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if ($null -ne $request.legalName -or
                            $null -ne $request.workEmail -or
                            $null -ne $request.workPhone -or
                            $null -ne $request.employeeNumber -or
                            $null -ne $request.jobTitle -or
                            $null -ne $request.department) {
                            throw 'Fixture received personal data in a Staff update request.'
                        }
                        if ($null -eq $script:updateOperationId) {
                            if ([long]$request.expectedVersion -ne 1) {
                                throw 'Fixture received an invalid first Staff update version.'
                            }
                            $script:updateOperationId = $operationId
                            $script:updatedLabel = [string]$request.displayName
                            $script:currentLabel = $script:updatedLabel
                            $script:version = 2
                            $script:lastChangedAtUtc = '2026-08-13T00:00:00.2000000+00:00'
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-MutationReceipt -Status 1 -Version 2 -CompletedAtUtc $script:lastChangedAtUtc)
                            continue
                        }
                        if ($operationId -ceq $script:updateOperationId) {
                            if ([string]$request.displayName -cne $script:updatedLabel -or
                                [long]$request.expectedVersion -ne 1) {
                                Write-FixtureProblem -Stream $stream -Code 'Staff.ProfileUpdateOperationConflict'
                                continue
                            }
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-MutationReceipt -Status 1 -Version 2 -CompletedAtUtc '2026-08-13T00:00:00.2000000+00:00')
                            continue
                        }
                        if ([long]$request.expectedVersion -ne $script:version) {
                            Write-FixtureProblem -Stream $stream -Code 'Staff.VersionConflict'
                            continue
                        }
                        throw 'Fixture received an unexpected additional Staff update.'
                    }

                    $propertyMembersPath = "/api/staff/properties/$($Fixture.PropertyId)/members"
                    if ($method -ceq 'GET' -and
                        $path.StartsWith("${propertyMembersPath}?", [StringComparison]::Ordinal)) {
                        $requestedStatus = Get-RequestedStatus -Path $path
                        Write-FixtureResponse `
                            -Stream $stream `
                            -Status 200 `
                            -Reason OK `
                            -Body (New-PropertyStaffDirectory -RequestedStatus $requestedStatus)
                        continue
                    }

                    if ($method -ceq 'PUT' -and
                        $path -ceq "$propertyMembersPath/$script:staffMemberId/assignment") {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        if ([string]$request.effectiveFrom -cne $Fixture.EffectiveDate -or
                            $null -ne $request.propertyJobTitle) {
                            throw 'Fixture received an invalid Staff assignment date or title.'
                        }
                        if ($script:propertyUnavailableResponses -eq 0) {
                            $script:propertyUnavailableResponses = 1
                            Write-Capture
                            Write-FixtureProblem -Stream $stream -Code 'Staff.PropertyUnavailable'
                            continue
                        }
                        if ($null -eq $script:assignmentOperationId) {
                            if (-not [bool]$request.isPrimary -or
                                [long]$request.expectedVersion -ne 2) {
                                throw 'Fixture received an invalid first Staff assignment.'
                            }
                            $script:assignmentOperationId = $operationId
                            $script:assignmentEverCreated = $true
                            $script:assignmentCurrent = $true
                            $script:version = 3
                            $script:lastChangedAtUtc = '2026-08-13T00:00:00.3000000+00:00'
                            Write-Capture
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-MutationReceipt -Status 1 -Version 3 -CompletedAtUtc $script:lastChangedAtUtc)
                            continue
                        }
                        if ($operationId -cne $script:assignmentOperationId -or
                            [long]$request.expectedVersion -ne 2 -or
                            -not [bool]$request.isPrimary) {
                            Write-FixtureProblem -Stream $stream -Code 'Staff.AssignmentOperationConflict'
                            continue
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-MutationReceipt -Status 1 -Version 3 -CompletedAtUtc '2026-08-13T00:00:00.3000000+00:00')
                        continue
                    }

                    $memberActionPrefix = $memberPath + '/'
                    if ($method -ceq 'POST' -and
                        $path.StartsWith($memberActionPrefix, [StringComparison]::Ordinal)) {
                        $request = $bodyText | ConvertFrom-Json -Depth 8
                        $operationId = ([Guid]$request.operationId).ToString('D')
                        $action = $path.Substring($memberPath.Length + 1)
                        if ([string]$request.reason -cne 'Synthetic deployment verification') {
                            throw "Fixture received an invalid '$action' reason."
                        }
                        switch ($action) {
                            'suspend' {
                                if ($null -eq $script:suspendOperationId) {
                                    if ([long]$request.expectedVersion -ne 3 -or $script:status -ne 1) {
                                        throw 'Fixture received an invalid Staff suspension.'
                                    }
                                    $script:suspendOperationId = $operationId
                                    $script:status = 2
                                    $script:version = 4
                                    $script:lastChangedAtUtc = '2026-08-13T00:00:00.4000000+00:00'
                                }
                                elseif ($operationId -cne $script:suspendOperationId -or
                                    [long]$request.expectedVersion -ne 3) {
                                    Write-FixtureProblem -Stream $stream -Code 'Staff.LifecycleOperationConflict'
                                    continue
                                }
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                    New-MutationReceipt -Status 2 -Version 4 -CompletedAtUtc '2026-08-13T00:00:00.4000000+00:00')
                                continue
                            }
                            'resume' {
                                if ($null -eq $script:resumeOperationId) {
                                    if ([long]$request.expectedVersion -ne 4 -or $script:status -ne 2) {
                                        throw 'Fixture received an invalid Staff resume.'
                                    }
                                    $script:resumeOperationId = $operationId
                                    $script:status = 1
                                    $script:version = 5
                                    $script:lastChangedAtUtc = '2026-08-13T00:00:00.5000000+00:00'
                                    Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                        New-MutationReceipt -Status 1 -Version 5 -CompletedAtUtc $script:lastChangedAtUtc)
                                    continue
                                }
                                if ($operationId -cne $script:resumeOperationId -or
                                    [long]$request.expectedVersion -ne 4) {
                                    Write-FixtureProblem -Stream $stream -Code 'Staff.LifecycleOperationConflict'
                                    continue
                                }
                                $replayVersion = if ($Mode -ceq 'resume-replay-drift') { 6 } else { 5 }
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                    New-MutationReceipt -Status 1 -Version $replayVersion -CompletedAtUtc '2026-08-13T00:00:00.5000000+00:00')
                                continue
                            }
                            'depart' {
                                if ($null -eq $script:departOperationId) {
                                    if ([long]$request.expectedVersion -ne 5 -or
                                        [string]$request.effectiveOn -cne $Fixture.EffectiveDate -or
                                        $script:status -notin @(1, 2)) {
                                        throw 'Fixture received an invalid Staff departure.'
                                    }
                                    $script:departOperationId = $operationId
                                    $script:status = 3
                                    $script:version = 6
                                    $script:assignmentCurrent = $false
                                    $script:lastChangedAtUtc = '2026-08-13T00:00:00.6000000+00:00'
                                    Write-Capture
                                }
                                elseif ($operationId -cne $script:departOperationId -or
                                    [long]$request.expectedVersion -ne 5 -or
                                    [string]$request.effectiveOn -cne $Fixture.EffectiveDate) {
                                    Write-FixtureProblem -Stream $stream -Code 'Staff.LifecycleOperationConflict'
                                    continue
                                }
                                Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                    New-MutationReceipt -Status 3 -Version 6 -CompletedAtUtc '2026-08-13T00:00:00.6000000+00:00')
                                continue
                            }
                            default {
                                throw "Fixture received unexpected Staff lifecycle action '$action'."
                            }
                        }
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
        throw "The $Mode Staff employment fixture did not become ready."
    }
    $port = [int](Get-Content -LiteralPath $readyPath -Raw)
    return [pscustomobject]@{
        Job = $job
        Origin = [Uri]"http://127.0.0.1:$port"
        CapturePath = $capturePath
    }
}

function Complete-BunkFyStaffEmploymentFixtureServer {
    param([Parameter(Mandatory = $true)][object] $Server)

    try {
        $completed = Wait-Job -Job $Server.Job -Timeout 15
        if ($null -eq $completed) {
            throw 'The Staff employment fixture server did not terminate after the probe.'
        }
        $output = @(Receive-Job -Job $Server.Job -ErrorAction Stop)
        if ($Server.Job.State -ne 'Completed') {
            throw "The Staff employment fixture ended in state '$($Server.Job.State)': $($output -join [Environment]::NewLine)"
        }
    }
    finally {
        Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    }
}

function Stop-BunkFyStaffEmploymentFixtureServer {
    param([AllowNull()][object] $Server)

    if ($null -eq $Server) {
        return
    }
    Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
}

function Invoke-BunkFyStaffEmploymentFixtureProbe {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'resume-replay-drift')]
        [string] $Mode,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $server = $null
    try {
        $server = Start-BunkFyStaffEmploymentFixtureServer -Mode $Mode
        $operatorToken = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        $deniedToken = ConvertTo-SecureString $fixture.DeniedToken -AsPlainText -Force
        $probeError = $null
        try {
            & $probeScript `
                -PublicOrigin $server.Origin `
                -ExpectedReleaseId $fixture.ReleaseId `
                -WorkspaceId $fixture.WorkspaceId `
                -PropertyId $fixture.PropertyId `
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
            Complete-BunkFyStaffEmploymentFixtureServer -Server $server
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
        Stop-BunkFyStaffEmploymentFixtureServer -Server $server
    }
}

try {
    $validOutput = Join-Path $fixtureRoot 'valid-evidence.json'
    $capture = Invoke-BunkFyStaffEmploymentFixtureProbe `
        -Mode valid `
        -OutputPath $validOutput
    if ($null -eq $capture -or
        [int]$capture.finalStatus -ne 3 -or
        [int]$capture.currentAssignmentCount -ne 0 -or
        [int]$capture.propertyUnavailableResponses -ne 1) {
        throw 'The valid Staff fixture did not reach the expected projected and terminal state.'
    }

    $evidence = Get-Content -LiteralPath $validOutput -Raw |
        ConvertFrom-Json -Depth 12
    if ($evidence.schemaVersion -ne 2 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-staff-employment-probe' -or
        $evidence.result -cne 'passed' -or
        $evidence.releaseId -cne $fixture.ReleaseId -or
        $evidence.admissionEvidenceReference -cne $fixture.AdmissionEvidenceReference -or
        $evidence.workflow.finalStatus -cne 'departed' -or
        [bool]$evidence.workflow.authSubjectLinked -or
        -not [bool]$evidence.workflow.profileVersionAdvanced -or
        $evidence.workflow.assignmentLifecycle -cne 'assigned-then-closed' -or
        [int]$evidence.workflow.currentAssignmentCount -ne 0 -or
        [int]$evidence.workflow.historicalAssignmentCount -ne 1 -or
        -not [bool]$evidence.workflow.suspensionRetainedAssignment -or
        -not [bool]$evidence.cleanup.currentAssignmentsClosed -or
        @($evidence.checks).Count -ne 21 -or
        @($evidence.limitations).Count -ne 4) {
        throw 'The valid Staff employment fixture produced invalid evidence.'
    }

    $evidenceText = Get-Content -LiteralPath $validOutput -Raw
    foreach ($sensitive in @(
            $fixture.WorkspaceId,
            $fixture.PropertyId,
            $fixture.MembershipId,
            $fixture.SubjectId,
            $fixture.AssignmentId,
            $fixture.OperatorToken,
            $fixture.DeniedToken,
            [string]$capture.staffMemberId,
            [string]$capture.initialLabel,
            [string]$capture.updatedLabel,
            'Synthetic deployment verification',
            'Authorization',
            'X-Tenant-Id',
            'effectiveFrom',
            'effectiveTo',
            'effectiveOn')) {
        if ($evidenceText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Staff employment evidence retained scoped, personal, credential, reason, or effective-date data.'
        }
    }

    $driftOutput = Join-Path $fixtureRoot 'resume-replay-drift-evidence.json'
    $driftRejected = $false
    try {
        [void](Invoke-BunkFyStaffEmploymentFixtureProbe `
                -Mode resume-replay-drift `
                -OutputPath $driftOutput)
    }
    catch {
        $driftRejected = $_.Exception.Message.Contains(
            'Exact Staff resume replay',
            [StringComparison]::OrdinalIgnoreCase)
    }
    $driftCapturePath = Get-ChildItem -LiteralPath $fixtureRoot -Filter 'capture-resume-replay-drift-*.json' |
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
        [int]$driftCapture.finalStatus -ne 3 -or
        [int]$driftCapture.currentAssignmentCount -ne 0) {
        throw 'The Staff employment probe accepted resume replay drift, wrote passing evidence, or failed terminal cleanup.'
    }

    $insecureOriginRejected = $false
    try {
        $operatorToken = ConvertTo-SecureString $fixture.OperatorToken -AsPlainText -Force
        $deniedToken = ConvertTo-SecureString $fixture.DeniedToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://staff.example.test:8080') `
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
        throw 'The Staff employment probe accepted insecure non-loopback HTTP.'
    }

    Write-Host 'BunkFy deployed Staff employment fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
