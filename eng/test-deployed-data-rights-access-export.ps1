Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-data-rights-access-export.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-data-rights-access-export-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$fixture = [pscustomobject]@{
    ReleaseId = 'release-fixture-001'
    AdmissionEvidenceReference = 'admission:11111111111111111111111111111111'
    WorkspaceId = '11111111-1111-4111-8111-111111111111'
    PropertyId = '22222222-2222-4222-8222-222222222222'
    MembershipId = '33333333-3333-4333-8333-333333333333'
    SubjectId = '44444444-4444-4444-8444-444444444444'
    GuestId = '55555555-5555-4555-8555-555555555555'
    CaseId = '66666666-6666-4666-8666-666666666666'
    ArtifactId = '77777777-7777-4777-8777-777777777777'
    ManagementOperationId = '88888888-8888-4888-8888-888888888888'
    AssuredToken = 'fixture-data-rights-assured-token-do-not-retain'
    UnassuredToken = 'fixture-data-rights-unassured-token-do-not-retain'
    DeniedToken = 'fixture-data-rights-denied-token-do-not-retain'
    GuestLabel = 'BunkFy data rights verification'
    RequestedAtUtc = '2026-08-12T10:00:00+00:00'
    GeneratedAtUtc = '2026-08-12T10:01:00+00:00'
    ExpiresAtUtc = '2026-08-13T10:00:00+00:00'
}

function Start-BunkFyDataRightsFixtureServer {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'valid',
            'wrong-release',
            'unsafe-headers',
            'malformed-export',
            'oversized-export',
            'unassured-allowed',
            'cleanup-failure')]
        [string] $Mode
    )

    $nonce = [Guid]::NewGuid().ToString('N')
    $readyPath = Join-Path $fixtureRoot "ready-$Mode-$nonce.txt"
    $capturePath = Join-Path $fixtureRoot "requests-$Mode-$nonce.txt"
    $job = Start-Job -ScriptBlock {
        param($ReadyPath, $CapturePath, $Mode, $Fixture)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        function Write-FixtureResponse {
            param(
                [Parameter(Mandatory = $true)][IO.Stream] $Stream,
                [Parameter(Mandatory = $true)][int] $Status,
                [Parameter(Mandatory = $true)][string] $Reason,
                [Parameter(Mandatory = $true)][AllowEmptyString()][object] $Body,
                [hashtable] $AdditionalHeaders
            )

            $bytes = if ($Body -is [byte[]]) {
                [byte[]]$Body
            }
            elseif ($Body -is [string]) {
                [Text.UTF8Encoding]::new($false).GetBytes([string]$Body)
            }
            else {
                [Text.UTF8Encoding]::new($false).GetBytes(
                    ($Body | ConvertTo-Json -Depth 20 -Compress))
            }
            $headers = [Collections.Generic.List[string]]::new()
            $headers.Add("HTTP/1.1 $Status $Reason")
            $headers.Add('Connection: close')
            $headers.Add("Content-Length: $($bytes.Length)")
            if ($null -eq $AdditionalHeaders -or
                -not $AdditionalHeaders.ContainsKey('Content-Type')) {
                $headers.Add('Content-Type: application/json; charset=utf-8')
            }
            if ($null -ne $AdditionalHeaders) {
                foreach ($entry in $AdditionalHeaders.GetEnumerator()) {
                    $headers.Add("$($entry.Key): $($entry.Value)")
                }
            }
            $headers.Add('')
            $headers.Add('')
            $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers -join "`r`n")
            $Stream.Write($headerBytes, 0, $headerBytes.Length)
            if ($bytes.Length -gt 0) {
                $Stream.Write($bytes, 0, $bytes.Length)
            }
            $Stream.Flush()
        }

        function Write-Problem {
            param(
                [Parameter(Mandatory = $true)][IO.Stream] $Stream,
                [Parameter(Mandatory = $true)][int] $Status,
                [Parameter(Mandatory = $true)][string] $Title
            )

            Write-FixtureResponse `
                -Stream $Stream `
                -Status $Status `
                -Reason $(if ($Status -eq 401) { 'Unauthorized' } elseif ($Status -eq 403) { 'Forbidden' } elseif ($Status -eq 409) { 'Conflict' } else { 'Error' }) `
                -Body ([ordered]@{
                    type = 'about:blank'
                    title = $Title
                    status = $Status
                })
        }

        function Assert-FixtureHeader {
            param(
                [Parameter(Mandatory = $true)][hashtable] $Headers,
                [Parameter(Mandatory = $true)][string] $Name,
                [Parameter(Mandatory = $true)][string] $Expected
            )

            if ([string]$Headers[$Name] -cne $Expected) {
                throw "Fixture request used the wrong $Name header."
            }
        }

        function New-CaseResponse {
            param(
                [Parameter(Mandatory = $true)][int] $Status,
                [Parameter(Mandatory = $true)][long] $Version,
                [int] $SelectedSubjectCount = 0,
                [int] $Decision = 0,
                [int] $DecisionReason = 0,
                [AllowNull()][object] $DecisionRevision = $null
            )

            return [ordered]@{
                id = $Fixture.CaseId
                propertyId = $Fixture.PropertyId
                type = 1
                requestedOperations = 1
                restrictionDirective = 0
                requesterRelationship = 3
                verificationStatus = 4
                routingStatus = 3
                status = $Status
                decision = $Decision
                decisionReason = $DecisionReason
                decisionRevision = $DecisionRevision
                decidedAtUtc = if ($Decision -eq 1) { '2026-08-12T09:59:00+00:00' } else { $null }
                executionRevision = $null
                executionStartedAtUtc = $null
                selectedSubjectCount = $SelectedSubjectCount
                dueAtUtc = $null
                version = $Version
                createdAtUtc = '2026-08-12T09:55:00+00:00'
                lastChangedAtUtc = '2026-08-12T09:59:00+00:00'
                approvalEvidence = $null
                responseDeadlineEvidence = $null
            }
        }

        function New-ArtifactResponse {
            param(
                [Parameter(Mandatory = $true)][int] $Status,
                [Parameter(Mandatory = $true)][long] $Version,
                [switch] $TransientPrecision
            )

            $requestedAtUtc = [DateTimeOffset]$Fixture.RequestedAtUtc
            $expiresAtUtc = [DateTimeOffset]$Fixture.ExpiresAtUtc
            if ($TransientPrecision) {
                $requestedAtUtc = $requestedAtUtc.AddTicks(1)
                $expiresAtUtc = $expiresAtUtc.AddTicks(1)
            }

            return [ordered]@{
                id = $Fixture.ArtifactId
                caseId = $Fixture.CaseId
                propertyId = $Fixture.PropertyId
                caseType = 1
                decisionRevision = 1
                selectedSubjectCount = 1
                status = $Status
                requestedAtUtc = $requestedAtUtc.ToString('O')
                generationStartedAtUtc = if ($Status -ge 2) { '2026-08-12T10:00:30+00:00' } else { $null }
                availableAtUtc = if ($Status -eq 3) { $Fixture.GeneratedAtUtc } else { $null }
                expiresAtUtc = $expiresAtUtc.ToString('O')
                version = $Version
            }
        }

        function New-ExportBytes {
            $value = [ordered]@{
                format = 'bunkfy.data-rights.export'
                formatVersion = 1
                caseType = 'guestRights'
                scopeType = 'property'
                decisionRevision = 1
                generatedAtUtc = $Fixture.GeneratedAtUtc
                expiresAtUtc = $Fixture.ExpiresAtUtc
                subjects = @([ordered]@{
                    coordinate = [ordered]@{
                        owner = 'guests'
                        recordType = 'guest-profile'
                        recordId = $Fixture.GuestId
                        recordVersion = 1
                    }
                    ownerDescriptor = [ordered]@{
                        catalogId = 'guests.personal-data'
                        catalogSchemaVersion = 1
                        catalogVersion = 1
                        exportSchemaId = 'guests.access-export'
                        exportSchemaVersion = 1
                    }
                    records = @(
                        [ordered]@{
                            recordType = 'guest-profile'
                            recordId = $Fixture.GuestId
                            recordVersion = 1
                            fields = @()
                        },
                        [ordered]@{
                            recordType = 'guest-management-operation'
                            recordId = $Fixture.ManagementOperationId
                            recordVersion = 1
                            fields = @()
                        })
                    recordCount = 2
                })
                summary = [ordered]@{
                    subjectCount = 1
                    recordCount = 2
                }
            }
            return ,([Text.UTF8Encoding]::new($false).GetBytes(
                ($value | ConvertTo-Json -Depth 20 -Compress)))
        }

        function Write-ExportResponse {
            param(
                [Parameter(Mandatory = $true)][IO.Stream] $Stream,
                [switch] $UnsafeHeaders,
                [switch] $Malformed,
                [switch] $Oversized
            )

            [byte[]]$body = if ($Malformed) {
                [Text.UTF8Encoding]::new($false).GetBytes('{not-json')
            }
            elseif ($Oversized) {
                $oversizedBytes = [byte[]]::new((1MB) + 1)
                [Array]::Fill[byte]($oversizedBytes, [byte]0x78)
                $oversizedBytes
            }
            else {
                New-ExportBytes
            }
            $headers = @{
                'Content-Type' = 'application/json'
                'Content-Disposition' = 'attachment; filename="bunkfy-data-rights-export.json"'
                'Pragma' = 'no-cache'
                'Expires' = '0'
                'X-Content-Type-Options' = 'nosniff, nosniff'
            }
            $headers['Cache-Control'] = if ($UnsafeHeaders) {
                'private, max-age=60'
            }
            else {
                'no-store, no-cache, max-age=0'
            }
            Write-FixtureResponse `
                -Stream $Stream `
                -Status 200 `
                -Reason OK `
                -Body $body `
                -AdditionalHeaders $headers
        }

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $requests = [Collections.Generic.List[string]]::new()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)
            $done = $false
            $caseVersion = 0L
            $exportRequestCount = 0
            $requestCount = 0
            $guestCreated = $false
            $guestArchived = $false
            $successfulAssuredDownloads = 0
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            while (-not $done -and
                $requestCount -lt 40 -and
                [DateTimeOffset]::UtcNow -lt $inactivityDeadline) {
                if (-not $listener.Pending()) {
                    Start-Sleep -Milliseconds 20
                    continue
                }

                $accepted = $listener.AcceptTcpClient()
                try {
                    $accepted.ReceiveTimeout = 5000
                    $accepted.SendTimeout = 5000
                    $stream = $accepted.GetStream()
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
                        $contentLength = if ($headers.ContainsKey('Content-Length')) {
                            [int]$headers['Content-Length']
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
                    $requests.Add("$method $path")
                    $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
                    if ($method -ceq 'GET' -and $path -ceq '/api/smoke') {
                        $releaseId = if ($Mode -ceq 'wrong-release') {
                            'wrong-release-001'
                        }
                        else {
                            $Fixture.ReleaseId
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                            application = 'BunkFy'
                            service = 'BunkFy.Host.Api'
                            status = 'ok'
                            releaseId = $releaseId
                            admissionEvidenceReference = $Fixture.AdmissionEvidenceReference
                            timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                        })
                        if ($Mode -ceq 'wrong-release' -or $guestArchived) {
                            $done = $true
                        }
                        continue
                    }

                    $authorization = [string]$headers['Authorization']
                    $tenant = [string]$headers['X-Tenant-Id']
                    if ($method -ceq 'GET' -and
                        $path -ceq '/api/organizations?page=1&pageSize=100') {
                        Assert-FixtureHeader -Headers $headers -Name Authorization -Expected "Bearer $($Fixture.AssuredToken)"
                        Assert-FixtureHeader -Headers $headers -Name 'X-Tenant-Id' -Expected global
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
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

                    Assert-FixtureHeader `
                        -Headers $headers `
                        -Name 'X-Tenant-Id' `
                        -Expected $Fixture.WorkspaceId

                    if ($method -ceq 'GET' -and
                        $path -ceq "/api/properties/$($Fixture.PropertyId)") {
                        if ($authorization -cne "Bearer $($Fixture.AssuredToken)") {
                            throw 'Property preflight used the wrong access token.'
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                            propertyId = $Fixture.PropertyId
                            name = 'Fixture property'
                            status = 1
                            version = 1
                        })
                        continue
                    }

                    $casesPath = "/api/data-rights/properties/$($Fixture.PropertyId)/cases"
                    $casePath = "$casesPath/$($Fixture.CaseId)"
                    $guestPath = "/api/guests/properties/$($Fixture.PropertyId)"
                    if ($method -ceq 'GET' -and
                        $path -ceq "${casesPath}?page=1&pageSize=1") {
                        if ($authorization -cne "Bearer $($Fixture.DeniedToken)") {
                            throw 'Nonmember case access used the wrong token.'
                        }
                        Write-Problem -Stream $stream -Status 403 -Title 'AccessControl.AccessDenied'
                        continue
                    }

                    if ($method -ceq 'POST' -and $path -ceq $guestPath) {
                        if ($authorization -cne "Bearer $($Fixture.AssuredToken)") {
                            throw 'Guest creation used the wrong token.'
                        }
                        $body = $bodyText | ConvertFrom-Json -Depth 12
                        if ([string]$body.displayName -cne $Fixture.GuestLabel -or
                            [Guid]$body.operationId -eq [Guid]::Empty) {
                            throw 'Guest creation request was not the bounded synthetic fixture.'
                        }
                        $guestCreated = $true
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                            guestId = $Fixture.GuestId
                            status = 1
                            version = 1
                            lastChangedAtUtc = '2026-08-12T09:54:00+00:00'
                        })
                        continue
                    }

                    if ($method -ceq 'POST' -and $path -ceq $casesPath) {
                        if (-not $guestCreated -or
                            $authorization -cne "Bearer $($Fixture.AssuredToken)") {
                            throw 'Case creation occurred without the assured synthetic Guest context.'
                        }
                        $body = $bodyText | ConvertFrom-Json -Depth 12
                        if ([int]$body.requestedOperations -ne 1 -or
                            [int]$body.restrictionDirective -ne 0 -or
                            [int]$body.requesterRelationship -ne 3) {
                            throw 'Case creation request used the wrong Data Rights contract.'
                        }
                        $caseVersion = 1
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-CaseResponse -Status 1 -Version $caseVersion)
                        continue
                    }

                    if ($authorization -ceq "Bearer $($Fixture.AssuredToken)" -and
                        $method -ceq 'POST' -and
                        $path -ceq "$casePath/discovery") {
                        $caseVersion = 2
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-CaseResponse -Status 2 -Version $caseVersion)
                        continue
                    }
                    if ($authorization -ceq "Bearer $($Fixture.AssuredToken)" -and
                        $method -ceq 'POST' -and
                        $path -ceq "$casePath/subjects/discover") {
                        $body = $bodyText | ConvertFrom-Json -Depth 12
                        if ([Guid]$body.recordId -ne [Guid]$Fixture.GuestId -or
                            [string]$body.ownerKey -cne 'guests') {
                            throw 'Subject discovery did not use the exact Guest coordinate.'
                        }
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                            candidates = @([ordered]@{
                                coordinate = [ordered]@{
                                    ownerKey = 'guests'
                                    recordType = 'guest-profile'
                                    recordId = $Fixture.GuestId
                                    recordVersion = 1
                                }
                                displayName = $Fixture.GuestLabel
                                emailHint = $null
                                phoneHint = $null
                            })
                            limitReached = $false
                        })
                        continue
                    }
                    if ($authorization -ceq "Bearer $($Fixture.AssuredToken)" -and
                        $method -ceq 'POST' -and
                        $path -ceq "$casePath/subjects/select") {
                        $caseVersion = 3
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-CaseResponse -Status 2 -Version $caseVersion -SelectedSubjectCount 1)
                        continue
                    }
                    if ($authorization -ceq "Bearer $($Fixture.AssuredToken)" -and
                        $method -ceq 'POST' -and
                        $path -ceq "$casePath/review") {
                        $caseVersion = 4
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-CaseResponse -Status 3 -Version $caseVersion -SelectedSubjectCount 1)
                        continue
                    }
                    if ($authorization -ceq "Bearer $($Fixture.AssuredToken)" -and
                        $method -ceq 'POST' -and
                        $path -ceq "$casePath/decision") {
                        $caseVersion = 5
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-CaseResponse -Status 4 -Version $caseVersion -SelectedSubjectCount 1)
                        continue
                    }
                    if ($authorization -ceq "Bearer $($Fixture.AssuredToken)" -and
                        $method -ceq 'POST' -and
                        $path -ceq "$casePath/decision/outcome") {
                        $caseVersion = 6
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-CaseResponse `
                                -Status 5 `
                                -Version $caseVersion `
                                -SelectedSubjectCount 1 `
                                -Decision 1 `
                                -DecisionReason 1 `
                                -DecisionRevision 1)
                        continue
                    }

                    $exportPath = "$casePath/export"
                    if ($authorization -ceq "Bearer $($Fixture.AssuredToken)" -and
                        $method -ceq 'POST' -and
                        $path -ceq $exportPath) {
                        $exportRequestCount++
                        if ($exportRequestCount -le 2) {
                            Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                                New-ArtifactResponse `
                                    -Status 1 `
                                    -Version 1 `
                                    -TransientPrecision:($exportRequestCount -eq 1))
                        }
                        else {
                            Write-Problem `
                                -Stream $stream `
                                -Status 409 `
                                -Title 'DataRights.ExportArtifactAlreadyRequested'
                        }
                        continue
                    }
                    if ($authorization -ceq "Bearer $($Fixture.AssuredToken)" -and
                        $method -ceq 'GET' -and
                        $path -ceq $exportPath) {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-ArtifactResponse -Status 3 -Version 3)
                        continue
                    }
                    if ($authorization -ceq "Bearer $($Fixture.AssuredToken)" -and
                        $method -ceq 'GET' -and
                        $path -ceq $casePath) {
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body (
                            New-CaseResponse `
                                -Status 9 `
                                -Version 7 `
                                -SelectedSubjectCount 1 `
                                -Decision 1 `
                                -DecisionReason 1 `
                                -DecisionRevision 1)
                        continue
                    }

                    $downloadPath = "$exportPath/$($Fixture.ArtifactId)/download"
                    if ($method -ceq 'GET' -and $path -ceq $downloadPath) {
                        if ($authorization -ceq "Bearer $($Fixture.UnassuredToken)") {
                            if ($Mode -ceq 'unassured-allowed') {
                                Write-ExportResponse -Stream $stream
                            }
                            else {
                                Write-Problem `
                                    -Stream $stream `
                                    -Status 401 `
                                    -Title 'Security.InsufficientAuthentication'
                            }
                            continue
                        }
                        if ($authorization -ceq "Bearer $($Fixture.DeniedToken)") {
                            Write-Problem -Stream $stream -Status 403 -Title 'AccessControl.AccessDenied'
                            continue
                        }
                        if ($authorization -cne "Bearer $($Fixture.AssuredToken)") {
                            throw 'Export download used an unknown token.'
                        }

                        $successfulAssuredDownloads++
                        Write-ExportResponse `
                            -Stream $stream `
                            -UnsafeHeaders:($Mode -ceq 'unsafe-headers') `
                            -Malformed:($Mode -ceq 'malformed-export') `
                            -Oversized:($Mode -ceq 'oversized-export')
                        continue
                    }

                    if ($method -ceq 'POST' -and
                        $path -ceq "$guestPath/$($Fixture.GuestId)/archive") {
                        if ($authorization -cne "Bearer $($Fixture.AssuredToken)") {
                            throw 'Guest cleanup used the wrong token.'
                        }
                        if ($Mode -ceq 'cleanup-failure') {
                            Write-Problem -Stream $stream -Status 500 -Title 'Fixture.CleanupFailed'
                            $done = $true
                            continue
                        }
                        $guestArchived = $true
                        Write-FixtureResponse -Stream $stream -Status 200 -Reason OK -Body ([ordered]@{
                            guestId = $Fixture.GuestId
                            status = 2
                            version = 2
                            lastChangedAtUtc = '2026-08-12T10:02:00+00:00'
                        })
                        if ($Mode -cne 'valid') {
                            $done = $true
                        }
                        continue
                    }

                    throw "Fixture received unexpected request '$method $path'."
                }
                finally {
                    $accepted.Dispose()
                }
            }

            if (-not $done) {
                throw "Fixture stopped before the expected terminal request after $requestCount requests."
            }
        }
        finally {
            [IO.File]::WriteAllLines($CapturePath, $requests)
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
        throw "The $Mode Data Rights fixture did not become ready."
    }
    $port = [int](Get-Content -LiteralPath $readyPath -Raw)
    return [pscustomobject]@{
        Job = $job
        Origin = [Uri]"http://127.0.0.1:$port"
        CapturePath = $capturePath
    }
}

function Complete-BunkFyDataRightsFixtureServer {
    param([Parameter(Mandatory = $true)][object] $Server)

    try {
        $completed = Wait-Job -Job $Server.Job -Timeout 20
        if ($null -eq $completed) {
            throw 'The Data Rights fixture server did not terminate after the probe.'
        }
        $output = @(Receive-Job -Job $Server.Job -ErrorAction Stop)
        if ($Server.Job.State -ne 'Completed') {
            throw "The Data Rights fixture ended in state '$($Server.Job.State)': $($output -join [Environment]::NewLine)"
        }
    }
    finally {
        Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    }
}

function Stop-BunkFyDataRightsFixtureServer {
    param([AllowNull()][object] $Server)

    if ($null -eq $Server) {
        return
    }
    Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
}

function New-FixtureSecureToken {
    param([Parameter(Mandatory = $true)][string] $Value)

    return ConvertTo-SecureString $Value -AsPlainText -Force
}

function Invoke-BunkFyDataRightsFixtureProbe {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'valid',
            'wrong-release',
            'unsafe-headers',
            'malformed-export',
            'oversized-export',
            'unassured-allowed',
            'cleanup-failure')]
        [string] $Mode,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $server = $null
    try {
        $server = Start-BunkFyDataRightsFixtureServer -Mode $Mode
        $probeError = $null
        try {
            & $probeScript `
                -PublicOrigin $server.Origin `
                -ExpectedReleaseId $fixture.ReleaseId `
                -WorkspaceId $fixture.WorkspaceId `
                -PropertyId $fixture.PropertyId `
                -AssuredOperatorAccessToken (New-FixtureSecureToken $fixture.AssuredToken) `
                -UnassuredOperatorAccessToken (New-FixtureSecureToken $fixture.UnassuredToken) `
                -DeniedAccessToken (New-FixtureSecureToken $fixture.DeniedToken) `
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
            Complete-BunkFyDataRightsFixtureServer -Server $server
        }
        catch {
            $serverError = $_
        }
        $server = $null
        if ($null -ne $probeError) {
            throw $probeError
        }
        if ($null -ne $serverError) {
            throw $serverError
        }
    }
    finally {
        Stop-BunkFyDataRightsFixtureServer -Server $server
    }
}

try {
    $validOutput = Join-Path $fixtureRoot 'valid-evidence.json'
    Invoke-BunkFyDataRightsFixtureProbe -Mode valid -OutputPath $validOutput
    $evidenceText = Get-Content -LiteralPath $validOutput -Raw
    $evidence = $evidenceText | ConvertFrom-Json -Depth 16
    $expectedChecks = @(
        'scoped-assured-operator-and-property-preflight',
        'nonmember-case-access-denied',
        'synthetic-guest-created',
        'controller-initiated-case-entered-discovery',
        'exact-guest-subject-discovered-and-selected',
        'review-and-decision-approved',
        'export-generation-requested',
        'export-request-replay-stable',
        'second-artifact-request-denied',
        'worker-export-generation-converged',
        'case-completed-with-approved-scope',
        'unassured-export-download-denied',
        'nonmember-export-download-denied',
        'protected-download-headers-and-shape-verified',
        'download-replay-stable',
        'synthetic-guest-archived',
        'artifact-expiry-bounded-and-scheduled',
        'release-identity-continuous')
    if ($evidence.schemaVersion -ne 2 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-data-rights-access-export-probe' -or
        $evidence.result -cne 'passed' -or
        $evidence.releaseId -cne $fixture.ReleaseId -or
        $evidence.admissionEvidenceReference -cne $fixture.AdmissionEvidenceReference -or
        (@($evidence.checks.name) -join '|') -cne ($expectedChecks -join '|') -or
        @($evidence.limitations).Count -ne 4 -or
        $evidence.workflow.finalStatus -cne 'completed' -or
        $evidence.artifact.finalStatus -cne 'available' -or
        $evidence.artifact.formatVersion -ne 1 -or
        $evidence.artifact.subjectCount -ne 1 -or
        $evidence.artifact.recordCount -ne 2 -or
        $evidence.artifact.byteCount -le 0 -or
        $evidence.artifact.expiryHours -ne 24 -or
        -not [bool]$evidence.cleanup.guestArchived -or
        $evidence.cleanup.artifactDisposition -cne 'scheduled-expiry') {
        throw 'The valid Data Rights fixture produced invalid evidence.'
    }
    foreach ($sensitive in @(
            $fixture.WorkspaceId,
            $fixture.PropertyId,
            $fixture.MembershipId,
            $fixture.SubjectId,
            $fixture.GuestId,
            $fixture.CaseId,
            $fixture.ArtifactId,
            $fixture.ManagementOperationId,
            $fixture.AssuredToken,
            $fixture.UnassuredToken,
            $fixture.DeniedToken,
            $fixture.GuestLabel,
            $fixture.RequestedAtUtc,
            $fixture.GeneratedAtUtc,
            $fixture.ExpiresAtUtc,
            'Authorization',
            'X-Tenant-Id')) {
        if ($evidenceText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Data Rights evidence retained scoped, personal, credential, or plaintext data.'
        }
    }

    foreach ($negative in @(
            [pscustomobject]@{ Mode = 'wrong-release'; Message = 'release' },
            [pscustomobject]@{ Mode = 'unsafe-headers'; Message = 'headers' },
            [pscustomobject]@{ Mode = 'malformed-export'; Message = 'invalid JSON' },
            [pscustomobject]@{ Mode = 'oversized-export'; Message = 'exceeds' },
            [pscustomobject]@{ Mode = 'unassured-allowed'; Message = 'require step-up' },
            [pscustomobject]@{ Mode = 'cleanup-failure'; Message = 'cleanup' })) {
        $output = Join-Path $fixtureRoot "$($negative.Mode)-evidence.json"
        $rejected = $false
        try {
            Invoke-BunkFyDataRightsFixtureProbe `
                -Mode $negative.Mode `
                -OutputPath $output
        }
        catch {
            $rejected = $_.Exception.Message.Contains(
                $negative.Message,
                [StringComparison]::OrdinalIgnoreCase)
        }
        if (-not $rejected -or (Test-Path -LiteralPath $output)) {
            throw "The Data Rights probe accepted '$($negative.Mode)' or wrote passing evidence."
        }
    }

    $overwriteRejected = $false
    try {
        & $probeScript `
            -PublicOrigin ([Uri]'http://127.0.0.1:1') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -AssuredOperatorAccessToken (New-FixtureSecureToken $fixture.AssuredToken) `
            -UnassuredOperatorAccessToken (New-FixtureSecureToken $fixture.UnassuredToken) `
            -DeniedAccessToken (New-FixtureSecureToken $fixture.DeniedToken) `
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
        throw 'The Data Rights probe accepted output evidence overwrite.'
    }

    $insecureOriginRejected = $false
    try {
        & $probeScript `
            -PublicOrigin ([Uri]'http://data-rights.example.test:8080') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -AssuredOperatorAccessToken (New-FixtureSecureToken $fixture.AssuredToken) `
            -UnassuredOperatorAccessToken (New-FixtureSecureToken $fixture.UnassuredToken) `
            -DeniedAccessToken (New-FixtureSecureToken $fixture.DeniedToken) `
            -OutputPath (Join-Path $fixtureRoot 'insecure-origin.json') `
            -Confirm:$false
    }
    catch {
        $insecureOriginRejected = $_.Exception.Message.Contains(
            'must use HTTPS',
            [StringComparison]::Ordinal)
    }
    if (-not $insecureOriginRejected) {
        throw 'The Data Rights probe accepted insecure non-loopback HTTP.'
    }

    Write-Host 'BunkFy deployed Data Rights access export fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
