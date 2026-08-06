Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-workspace-enrollment.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-workspace-enrollment-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$fixture = [pscustomobject]@{
    ReleaseId = 'release-fixture-001'
    WorkspaceId = '11111111-1111-4111-8111-111111111111'
    AllowedPropertyId = '22222222-2222-4222-8222-222222222222'
    DeniedPropertyId = '33333333-3333-4333-8333-333333333333'
    RejectedApplicationId = '44444444-4444-4444-8444-444444444444'
    RejectedClaimId = '55555555-5555-4555-8555-555555555555'
    ApprovedApplicationId = '66666666-6666-4666-8666-666666666666'
    ApprovedClaimId = '77777777-7777-4777-8777-777777777777'
    MembershipId = '88888888-8888-4888-8888-888888888888'
    StaffMemberId = '99999999-9999-4999-8999-999999999999'
    RejectedLinkId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    ApprovedLinkId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    ProfileId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    SubjectId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    ApplicantEmail = 'deployment-smoke-applicant@example.test'
    OwnerToken = 'fixture-owner-token-do-not-retain'
    ApplicantToken = 'fixture-applicant-token-do-not-retain'
    RejectedSecret = 'fixture-rejected-enrollment-secret-do-not-retain'
    ApprovedSecret = 'fixture-approved-enrollment-secret-do-not-retain'
}

function Start-BunkFyWorkspaceEnrollmentFixtureServer {
    param([Parameter(Mandatory = $true)][string] $Mode)

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

        function New-MembershipSummary {
            return @{
                organization = @{
                    organizationId = $Fixture.WorkspaceId
                    scopeId = $Fixture.WorkspaceId
                    name = 'Fixture workspace'
                    slug = 'fixture-workspace'
                }
                membership = @{
                    membershipId = $Fixture.MembershipId
                    subjectId = $Fixture.SubjectId
                    role = 'member'
                    status = 'active'
                    version = 1
                }
            }
        }

        function New-Application {
            param(
                [Parameter(Mandatory = $true)][bool] $ApprovedFlow,
                [Parameter(Mandatory = $true)][int] $Status
            )

            return @{
                applicationId = if ($ApprovedFlow) {
                    $Fixture.ApprovedApplicationId
                }
                else {
                    $Fixture.RejectedApplicationId
                }
                organizationId = $Fixture.WorkspaceId
                sourceKind = 2
                sourceId = if ($ApprovedFlow) { $script:source2 } else { $script:source1 }
                claimId = if ($ApprovedFlow) {
                    $Fixture.ApprovedClaimId
                }
                else {
                    $Fixture.RejectedClaimId
                }
                claimVersion = 1
                subjectId = $Fixture.SubjectId
                status = $Status
                staffMemberId = if ($Status -eq 5) { $Fixture.StaffMemberId } else { $null }
                version = if ($Status -in @(5, 7)) { 4 } else { 2 }
            }
        }

        function New-ClaimOutcome {
            param(
                [Parameter(Mandatory = $true)][bool] $ApprovedFlow,
                [Parameter(Mandatory = $true)][string] $Status
            )

            $claimId = if ($ApprovedFlow) {
                $Fixture.ApprovedClaimId
            }
            else {
                $Fixture.RejectedClaimId
            }
            $linkId = if ($ApprovedFlow) {
                $Fixture.ApprovedLinkId
            }
            else {
                $Fixture.RejectedLinkId
            }
            return @{
                claim = @{
                    claimId = $claimId
                    enrollmentLinkId = $linkId
                    organizationId = $Fixture.WorkspaceId
                    subjectId = $Fixture.SubjectId
                    status = $Status
                    membershipId = if ($Status -eq 'accepted') { $Fixture.MembershipId } else { $null }
                    version = if ($Status -eq 'pending') { 1 } else { 2 }
                }
                membership = if ($Status -eq 'accepted') { New-MembershipSummary } else { $null }
            }
        }

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)

            $script:source1 = $null
            $script:source2 = $null
            $issueCount = 0
            $rejected = $false
            $approved = $false
            $source1Disabled = $false
            $requestNumber = 0
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
            while ($requestNumber -lt 38 -and
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
                        $requestParts = $requestLine.Split(' ')
                        if ($requestParts.Count -lt 2) {
                            throw "Fixture received malformed request '$requestLine'."
                        }
                        $method = $requestParts[0]
                        $path = $requestParts[1]
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
                            $characters = [char[]]::new($contentLength)
                            $read = 0
                            while ($read -lt $contentLength) {
                                $next = $reader.ReadBlock(
                                    $characters,
                                    $read,
                                    $contentLength - $read)
                                if ($next -le 0) {
                                    throw 'Fixture request body ended early.'
                                }
                                $read += $next
                            }
                            $bodyText = [string]::new($characters)
                        }
                    }
                    finally {
                        $reader.Dispose()
                    }

                    $authorization = [string]$headers['Authorization']
                    $tenantId = [string]$headers['X-Tenant-Id']
                    $token = if ($authorization.StartsWith('Bearer ', [StringComparison]::Ordinal)) {
                        $authorization.Substring(7)
                    }
                    else {
                        ''
                    }
                    if ($path -ne '/api/smoke' -and
                        $token -notin @($Fixture.OwnerToken, $Fixture.ApplicantToken)) {
                        throw 'Fixture received a missing or unexpected bearer token.'
                    }
                    foreach ($secret in @($Fixture.RejectedSecret, $Fixture.ApprovedSecret)) {
                        if ($path.Contains($secret, [StringComparison]::Ordinal)) {
                            throw 'Fixture enrollment secret leaked into the request URI.'
                        }
                    }

                    $status = 200
                    $reason = 'OK'
                    $response = $null
                    if ($method -eq 'GET' -and $path -eq '/api/smoke') {
                        $response = [ordered]@{
                            application = 'BunkFy'
                            service = 'BunkFy.Host.Api'
                            status = 'ok'
                            releaseId = $Fixture.ReleaseId
                            timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                        }
                    }
                    elseif ($method -eq 'GET' -and $path -eq '/api/auth/methods') {
                        if ($token -cne $Fixture.ApplicantToken -or $tenantId -cne 'global') {
                            throw 'Authentication methods used the wrong identity or scope.'
                        }
                        $response = @{
                            emails = @(@{
                                    email = $Fixture.ApplicantEmail
                                    isActive = $true
                                    isVerified = $true
                                })
                            externalIdentities = @()
                        }
                    }
                    elseif ($method -eq 'GET' -and
                        $path -match '^/api/organizations\?page=1&pageSize=100$') {
                        if ($token -cne $Fixture.ApplicantToken -or $tenantId -cne 'global') {
                            throw 'Workspace membership check used the wrong identity or scope.'
                        }
                        $response = if ($approved) {
                            @{
                                items = @(New-MembershipSummary)
                                page = 1
                                pageSize = 100
                                hasMore = $false
                            }
                        }
                        else {
                            @{
                                items = [object[]]@()
                                page = 1
                                pageSize = 100
                                hasMore = $false
                            }
                        }
                    }
                    elseif ($method -eq 'GET' -and
                        $path -in @(
                            "/api/properties/$($Fixture.AllowedPropertyId)",
                            "/api/properties/$($Fixture.DeniedPropertyId)")) {
                        if ($tenantId -cne $Fixture.WorkspaceId) {
                            throw 'Property request used the wrong tenant scope.'
                        }
                        if ($token -ceq $Fixture.OwnerToken) {
                            $response = @{ propertyId = $path.Split('/')[-1] }
                        }
                        elseif ($path -eq "/api/properties/$($Fixture.AllowedPropertyId)" -and
                            ($approved -or $Mode -eq 'PendingPropertyAllowed')) {
                            $response = @{ propertyId = $Fixture.AllowedPropertyId }
                        }
                        else {
                            $status = 403
                            $reason = 'Forbidden'
                            $response = @{ code = 'AccessControl.Forbidden' }
                        }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq '/api/workspace-staff-enrollment/sources/enrollment-links') {
                        if ($token -cne $Fixture.OwnerToken -or $tenantId -cne $Fixture.WorkspaceId) {
                            throw 'Enrollment issuance used the wrong identity or scope.'
                        }
                        $body = $bodyText | ConvertFrom-Json -Depth 12
                        if ([int]$body.maximumClaims -ne 1 -or
                            [int]$body.approvalMode -ne 2 -or
                            [string]$body.profileKey -cne 'front-desk' -or
                            @($body.propertyIds).Count -ne 1 -or
                            [string]$body.propertyIds[0] -cne $Fixture.AllowedPropertyId) {
                            throw 'Enrollment issuance body did not preserve the approval plan.'
                        }
                        $issueCount++
                        $source = [string]$body.sourceId
                        if ($issueCount -eq 1) { $script:source1 = $source } else { $script:source2 = $source }
                        $response = @{
                            plan = @{
                                sourceId = $source
                                sourceKind = 2
                                profileId = $Fixture.ProfileId
                                profileKey = 'front-desk'
                                propertyIds = @($Fixture.AllowedPropertyId)
                                status = 2
                                version = 1
                            }
                            token = if ($issueCount -eq 1) {
                                $Fixture.RejectedSecret
                            }
                            else {
                                $Fixture.ApprovedSecret
                            }
                            alreadyIssued = $false
                        }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq '/api/organization-enrollment/preview') {
                        if ($token -cne $Fixture.ApplicantToken -or $tenantId -cne 'global') {
                            throw 'Enrollment preview used the wrong identity or scope.'
                        }
                        $body = $bodyText | ConvertFrom-Json
                        $approvedFlow = [string]$body.token -ceq $Fixture.ApprovedSecret
                        if (-not $approvedFlow -and
                            [string]$body.token -cne $Fixture.RejectedSecret) {
                            throw 'Enrollment preview used an unexpected secret.'
                        }
                        $response = @{
                            enrollmentLinkId = if ($approvedFlow) {
                                $Fixture.ApprovedLinkId
                            }
                            else {
                                $Fixture.RejectedLinkId
                            }
                            organizationId = $Fixture.WorkspaceId
                            organizationName = 'Fixture workspace'
                            organizationSlug = 'fixture-workspace'
                        }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq '/api/workspace-staff-enrollment/applications') {
                        if ($token -cne $Fixture.ApplicantToken -or $tenantId -cne 'global') {
                            throw 'Enrollment application used the wrong identity or scope.'
                        }
                        $body = $bodyText | ConvertFrom-Json -Depth 12
                        if ([string]$body.workEmail -cne $Fixture.ApplicantEmail) {
                            throw 'Enrollment application used an unexpected email.'
                        }
                        if ([string]$body.token -ceq $Fixture.RejectedSecret) {
                            $response = New-Application -ApprovedFlow $false -Status 1
                        }
                        elseif ([string]$body.token -ceq $Fixture.ApprovedSecret) {
                            $response = New-Application -ApprovedFlow $true -Status $(if ($approved) { 5 } else { 1 })
                        }
                        else {
                            throw 'Enrollment application used an unexpected secret.'
                        }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq '/api/organization-enrollment/claim') {
                        if ($token -cne $Fixture.ApplicantToken -or $tenantId -cne 'global') {
                            throw 'Enrollment claim used the wrong identity or scope.'
                        }
                        $secret = [string](($bodyText | ConvertFrom-Json).token)
                        if ($secret -ceq $Fixture.RejectedSecret) {
                            $response = New-ClaimOutcome `
                                -ApprovedFlow $false `
                                -Status $(if ($rejected) { 'rejected' } else { 'pending' })
                        }
                        elseif ($secret -ceq $Fixture.ApprovedSecret) {
                            $response = New-ClaimOutcome `
                                -ApprovedFlow $true `
                                -Status $(if ($approved) { 'accepted' } else { 'pending' })
                        }
                        else {
                            throw 'Enrollment claim used an unexpected secret.'
                        }
                    }
                    elseif ($method -eq 'GET' -and
                        $path -match '^/api/workspace-staff-enrollment/applications\?page=1&pageSize=100$') {
                        if ($token -cne $Fixture.OwnerToken -or $tenantId -cne $Fixture.WorkspaceId) {
                            throw 'Owner application queue used the wrong identity or scope.'
                        }
                        $candidate = if ($null -eq $script:source2) {
                            New-Application -ApprovedFlow $false -Status 2
                        }
                        else {
                            New-Application -ApprovedFlow $true -Status 2
                        }
                        $response = @{ items = @($candidate); page = 1; pageSize = 100; hasMore = $false }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq "/api/organizations/$($Fixture.WorkspaceId)/join-requests/$($Fixture.RejectedClaimId)/reject") {
                        if ($token -cne $Fixture.OwnerToken -or $tenantId -cne $Fixture.WorkspaceId) {
                            throw 'Enrollment rejection used the wrong identity or scope.'
                        }
                        $rejected = $true
                        $response = New-ClaimOutcome -ApprovedFlow $false -Status 'rejected'
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq "/api/organizations/$($Fixture.WorkspaceId)/join-requests/$($Fixture.ApprovedClaimId)/approve") {
                        if ($token -cne $Fixture.OwnerToken -or $tenantId -cne $Fixture.WorkspaceId) {
                            throw 'Enrollment approval used the wrong identity or scope.'
                        }
                        $approved = $true
                        $response = New-ClaimOutcome -ApprovedFlow $true -Status 'accepted'
                    }
                    elseif ($method -eq 'GET' -and
                        $path -eq "/api/workspace-staff-enrollment/$($Fixture.WorkspaceId)/applications/current?sourceKind=2&sourceId=$script:source1") {
                        $response = New-Application -ApprovedFlow $false -Status $(if ($rejected) { 7 } else { 2 })
                    }
                    elseif ($method -eq 'GET' -and
                        $path -eq "/api/workspace-staff-enrollment/$($Fixture.WorkspaceId)/applications/current?sourceKind=2&sourceId=$script:source2") {
                        $response = New-Application -ApprovedFlow $true -Status $(if ($approved) { 5 } else { 2 })
                    }
                    elseif ($method -eq 'GET' -and
                        $path -eq '/api/workspace-staff-enrollment/sources?sourceKind=2&page=1&pageSize=100') {
                        if ($token -cne $Fixture.OwnerToken -or $tenantId -cne $Fixture.WorkspaceId) {
                            throw 'Enrollment source list used the wrong identity or scope.'
                        }
                        $items = [Collections.Generic.List[object]]::new()
                        if ($null -ne $script:source1) {
                            $items.Add(@{
                                    sourceId = $script:source1
                                    status = if ($source1Disabled) { 6 } else { 1 }
                                    version = if ($source1Disabled) { 2 } else { 1 }
                                })
                        }
                        if ($null -ne $script:source2) {
                            $items.Add(@{
                                    sourceId = $script:source2
                                    status = if ($approved) { 7 } else { 1 }
                                    version = if ($approved) { 2 } else { 1 }
                                })
                        }
                        $response = @{ items = @($items); page = 1; pageSize = 100 }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq "/api/workspace-staff-enrollment/sources/enrollment-links/$script:source1/disable") {
                        if ($token -cne $Fixture.OwnerToken -or $tenantId -cne $Fixture.WorkspaceId) {
                            throw 'Enrollment source disablement used the wrong identity or scope.'
                        }
                        $source1Disabled = $true
                        $response = @{ sourceId = $script:source1; status = 6; version = 2 }
                    }
                    elseif ($method -eq 'GET' -and $path -eq '/api/staff/me') {
                        if (-not $approved -or
                            $token -cne $Fixture.ApplicantToken -or
                            $tenantId -cne $Fixture.WorkspaceId) {
                            throw 'Approved Staff read used the wrong state, identity, or scope.'
                        }
                        $response = @{
                            staffMemberId = $Fixture.StaffMemberId
                            authSubjectId = $Fixture.SubjectId
                            version = 1
                        }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq '/api/access/permissions/evaluate') {
                        if (-not $approved -or
                            $token -cne $Fixture.ApplicantToken -or
                            $tenantId -cne $Fixture.WorkspaceId) {
                            throw 'Approved permission evaluation used the wrong state, identity, or scope.'
                        }
                        $body = $bodyText | ConvertFrom-Json -Depth 12
                        $decisions = @($body.checks | ForEach-Object {
                                @{
                                    permission = $_.permission
                                    scope = $_.scope
                                    allowed =
                                        $_.scope -eq "tenant:$($Fixture.WorkspaceId)/property:$($Fixture.AllowedPropertyId)" -and
                                        $_.permission -in @('properties.read', 'reservations.create')
                                }
                            })
                        $response = @{ permissions = $decisions }
                    }
                    elseif ($method -eq 'GET' -and
                        $path -eq "/api/workspace-access/members/$($Fixture.SubjectId)/access") {
                        if (-not $approved -or
                            $token -cne $Fixture.OwnerToken -or
                            $tenantId -cne $Fixture.WorkspaceId) {
                            throw 'Approved member access read used the wrong state, identity, or scope.'
                        }
                        $response = @{
                            subjectId = $Fixture.SubjectId
                            assignments = @(@{
                                    profileId = $Fixture.ProfileId
                                    profileKey = 'front-desk'
                                    profileDisplayName = 'Front desk'
                                    profileVersion = 1
                                    propertyId = $Fixture.AllowedPropertyId
                                })
                        }
                    }
                    else {
                        throw "Fixture received unexpected request '$method $path'."
                    }

                    Write-FixtureResponse `
                        -Stream $stream `
                        -Status $status `
                        -Reason $reason `
                        -Body ($response | ConvertTo-Json -Depth 12 -Compress)
                    $requestNumber++
                    $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(2)
                }
                finally {
                    $client.Dispose()
                }
            }
            if ($Mode -eq 'Valid' -and $requestNumber -ne 38) {
                throw "Valid fixture observed $requestNumber requests; expected 38."
            }
        }
        finally {
            $listener.Stop()
        }
    } -ArgumentList $readyPath, $Mode, $fixture

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
            $details = Receive-Job -Job $job -Keep 2>&1 | Out-String
            Remove-Job -Job $job -Force
            throw "Fixture server stopped before becoming ready. $details"
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force
            throw 'Fixture server did not become ready in time.'
        }
        Start-Sleep -Milliseconds 50
    }

    $port = [int](Get-Content -LiteralPath $readyPath -Raw)
    return [pscustomobject]@{
        Job = $job
        ReadyPath = $readyPath
        Origin = [Uri]"http://127.0.0.1:$port/"
    }
}

function Stop-BunkFyWorkspaceEnrollmentFixtureServer {
    param(
        [Parameter(Mandatory = $true)][object] $Server,
        [switch] $RequireCompleted
    )

    if ($RequireCompleted) {
        [void](Wait-Job -Job $Server.Job -Timeout 10)
        if ($Server.Job.State -ne 'Completed') {
            Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
            throw "Fixture server did not complete; state is '$($Server.Job.State)'."
        }
        $details = Receive-Job -Job $Server.Job -Keep 2>&1 | Out-String
        if ($Server.Job.ChildJobs[0].Error.Count -gt 0) {
            throw "Fixture server failed. $details"
        }
    }
    elseif ($Server.Job.State -notin @('Completed', 'Failed', 'Stopped')) {
        [void](Wait-Job -Job $Server.Job -Timeout 3)
        if ($Server.Job.State -notin @('Completed', 'Failed', 'Stopped')) {
            Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        }
    }

    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Server.ReadyPath -Force -ErrorAction SilentlyContinue
}

try {
    $env:BUNKFY_SMOKE_OWNER_TOKEN = $fixture.OwnerToken
    $env:BUNKFY_SMOKE_APPLICANT_TOKEN = $fixture.ApplicantToken

    $validServer = Start-BunkFyWorkspaceEnrollmentFixtureServer -Mode 'Valid'
    $validOutput = Join-Path $fixtureRoot 'valid.json'
    try {
        & $probeScript `
            -PublicOrigin $validServer.Origin `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId ([Guid]$fixture.WorkspaceId) `
            -AllowedPropertyId ([Guid]$fixture.AllowedPropertyId) `
            -DeniedPropertyId ([Guid]$fixture.DeniedPropertyId) `
            -ApplicantEmail $fixture.ApplicantEmail `
            -AllowLoopbackHttp `
            -OutputPath $validOutput `
            -Confirm:$false
        Stop-BunkFyWorkspaceEnrollmentFixtureServer -Server $validServer -RequireCompleted
        $validServer = $null
    }
    finally {
        if ($null -ne $validServer) {
            Stop-BunkFyWorkspaceEnrollmentFixtureServer -Server $validServer
        }
    }

    $evidenceText = Get-Content -LiteralPath $validOutput -Raw
    $evidence = $evidenceText | ConvertFrom-Json -Depth 8
    if ($evidence.schemaVersion -ne 1 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-workspace-enrollment-probe' -or
        $evidence.result -cne 'passed' -or
        $evidence.transport -cne 'loopback-http-fixture' -or
        $evidence.releaseId -cne $fixture.ReleaseId -or
        @($evidence.checks).Count -ne 9 -or
        @($evidence.limitations).Count -ne 3 -or
        [Guid]$evidence.approved.membershipId -ne [Guid]$fixture.MembershipId) {
        throw 'Valid workspace enrollment fixture emitted unexpected evidence.'
    }
    foreach ($forbidden in @(
            $fixture.OwnerToken,
            $fixture.ApplicantToken,
            $fixture.RejectedSecret,
            $fixture.ApprovedSecret,
            $fixture.ApplicantEmail,
            $fixture.SubjectId,
            'responseBody',
            'rawHeaders')) {
        if ($evidenceText.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Workspace enrollment evidence retained a credential or personal-data value.'
        }
    }

    $invalidServer = Start-BunkFyWorkspaceEnrollmentFixtureServer -Mode 'PendingPropertyAllowed'
    $invalidOutput = Join-Path $fixtureRoot 'invalid.json'
    try {
        $rejected = $false
        try {
            & $probeScript `
                -PublicOrigin $invalidServer.Origin `
                -ExpectedReleaseId $fixture.ReleaseId `
                -WorkspaceId ([Guid]$fixture.WorkspaceId) `
                -AllowedPropertyId ([Guid]$fixture.AllowedPropertyId) `
                -DeniedPropertyId ([Guid]$fixture.DeniedPropertyId) `
                -ApplicantEmail $fixture.ApplicantEmail `
                -AllowLoopbackHttp `
                -OutputPath $invalidOutput `
                -Confirm:$false
        }
        catch {
            $rejected = $true
            if (-not $_.Exception.Message.Contains(
                    'expected HTTP 403',
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "Probe rejected invalid pending access for an unexpected reason: $($_.Exception.Message)"
            }
        }
        if (-not $rejected) {
            throw 'Probe accepted property access before owner approval.'
        }
        if (Test-Path -LiteralPath $invalidOutput) {
            throw 'Probe wrote passing evidence for invalid pending access.'
        }
    }
    finally {
        Stop-BunkFyWorkspaceEnrollmentFixtureServer -Server $invalidServer
    }

    Write-Host 'BunkFy deployed workspace enrollment fixture passed.'
}
finally {
    Remove-Item Env:BUNKFY_SMOKE_OWNER_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:BUNKFY_SMOKE_APPLICANT_TOKEN -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
