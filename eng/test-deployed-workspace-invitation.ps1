Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'operations\deployed-public-edge.common.ps1')

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-workspace-invitation.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-workspace-invitation-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$workspaceId = [Guid]'11111111-1111-4111-8111-111111111111'
$allowedPropertyId = [Guid]'22222222-2222-4222-8222-222222222222'
$deniedPropertyId = [Guid]'33333333-3333-4333-8333-333333333333'
$applicationId = [Guid]'44444444-4444-4444-8444-444444444444'
$membershipId = [Guid]'55555555-5555-4555-8555-555555555555'
$staffMemberId = [Guid]'66666666-6666-4666-8666-666666666666'
$invitationId = [Guid]'77777777-7777-4777-8777-777777777777'
$profileId = [Guid]'88888888-8888-4888-8888-888888888888'
$applicantEmail = 'deployment-smoke-applicant@example.test'
$ownerToken = 'fixture-owner-token-do-not-retain'
$applicantToken = 'fixture-applicant-token-do-not-retain'
$invitationToken = 'fixture-invitation-token-do-not-retain'
$subjectId = '99999999-9999-4999-8999-999999999999'
$releaseId = 'release-fixture-001'

function Start-BunkFyWorkspaceInvitationFixtureServer {
    param([Parameter(Mandatory = $true)][string] $Mode)

    $readyPath = Join-Path $fixtureRoot ("ready-$Mode-$([Guid]::NewGuid().ToString('N')).txt")
    $job = Start-Job -ScriptBlock {
        param(
            $ReadyPath,
            $Mode,
            $WorkspaceId,
            $AllowedPropertyId,
            $DeniedPropertyId,
            $ApplicationId,
            $MembershipId,
            $StaffMemberId,
            $InvitationId,
            $ProfileId,
            $ApplicantEmail,
            $OwnerToken,
            $ApplicantToken,
            $InvitationToken,
            $SubjectId,
            $ReleaseId)

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

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)

            $sourceId = $null
            $requestNumber = 0
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
            while ($requestNumber -lt 19 -and
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
                        $token -notin @($OwnerToken, $ApplicantToken)) {
                        throw 'Fixture received a missing or unexpected bearer token.'
                    }
                    if ($path.Contains($InvitationToken, [StringComparison]::Ordinal)) {
                        throw 'Fixture invitation token leaked into the request URI.'
                    }

                    $status = 200
                    $reason = 'OK'
                    $response = $null
                    if ($method -eq 'GET' -and $path -eq '/api/smoke') {
                        $response = [ordered]@{
                            application = 'BunkFy'
                            service = 'BunkFy.Host.Api'
                            status = 'ok'
                            releaseId = $ReleaseId
                            timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                        }
                    }
                    elseif ($method -eq 'GET' -and $path -eq '/api/auth/methods') {
                        if ($token -cne $ApplicantToken -or $tenantId -cne 'global') {
                            throw 'Authentication methods used the wrong identity or scope.'
                        }
                        $response = @{
                            emails = @(@{
                                    email = $ApplicantEmail
                                    isActive = $true
                                    isVerified = $true
                                })
                            externalIdentities = @()
                        }
                    }
                    elseif ($method -eq 'GET' -and $path -eq '/api/organizations?page=1&pageSize=100') {
                        if ($token -cne $ApplicantToken -or $tenantId -cne 'global') {
                            throw 'Workspace preflight used the wrong identity or scope.'
                        }
                        $response = @{ items = @(); page = 1; pageSize = 100; hasMore = $false }
                    }
                    elseif ($method -eq 'GET' -and
                        $path -in @(
                            "/api/properties/$AllowedPropertyId",
                            "/api/properties/$DeniedPropertyId")) {
                        if ($tenantId -cne $WorkspaceId) {
                            throw 'Property request used the wrong tenant scope.'
                        }
                        if ($token -ceq $ApplicantToken -and $path -eq "/api/properties/$DeniedPropertyId") {
                            if ($Mode -eq 'DeniedPropertyAllowed') {
                                $response = @{ propertyId = $DeniedPropertyId }
                            }
                            else {
                                $status = 403
                                $reason = 'Forbidden'
                                $response = @{ code = 'AccessControl.Forbidden' }
                            }
                        }
                        else {
                            $response = @{ propertyId = $path.Split('/')[-1] }
                        }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq '/api/workspace-staff-enrollment/sources/invitations') {
                        if ($token -cne $OwnerToken -or $tenantId -cne $WorkspaceId) {
                            throw 'Invitation issuance used the wrong identity or scope.'
                        }
                        $body = $bodyText | ConvertFrom-Json -Depth 12
                        if ([string]$body.recipientEmail -cne $ApplicantEmail -or
                            [string]$body.profileKey -cne 'front-desk' -or
                            @($body.propertyIds).Count -ne 1 -or
                            [string]$body.propertyIds[0] -cne $AllowedPropertyId) {
                            throw 'Invitation issuance body did not preserve the requested plan.'
                        }
                        $sourceId = [string]$body.sourceId
                        $response = @{
                            plan = @{
                                sourceId = $sourceId
                                sourceKind = 1
                                profileId = $ProfileId
                                profileKey = 'front-desk'
                                propertyIds = @($AllowedPropertyId)
                                status = 2
                                version = 1
                            }
                            token = $InvitationToken
                            alreadyIssued = $false
                        }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq '/api/organization-invitations/preview') {
                        if ($token -cne $ApplicantToken -or $tenantId -cne 'global' -or
                            [string](($bodyText | ConvertFrom-Json).token) -cne $InvitationToken) {
                            throw 'Invitation preview did not use the applicant and secret body.'
                        }
                        $response = @{
                            invitationId = $InvitationId
                            organizationId = $WorkspaceId
                            organizationName = 'Fixture workspace'
                            organizationSlug = 'fixture-workspace'
                        }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq '/api/workspace-staff-enrollment/applications') {
                        if ($token -cne $ApplicantToken -or $tenantId -cne 'global') {
                            throw 'Staff application used the wrong identity or scope.'
                        }
                        $body = $bodyText | ConvertFrom-Json -Depth 12
                        if ([string]$body.token -cne $InvitationToken -or
                            [string]$body.workEmail -cne $ApplicantEmail) {
                            throw 'Staff application did not preserve the invitation and email.'
                        }
                        $response = @{
                            applicationId = $ApplicationId
                            organizationId = $WorkspaceId
                            sourceKind = 1
                            sourceId = $sourceId
                            subjectId = $SubjectId
                            status = if ($requestNumber -lt 14) { 1 } else { 5 }
                            staffMemberId = if ($requestNumber -lt 14) { $null } else { $StaffMemberId }
                            version = if ($requestNumber -lt 14) { 1 } else { 4 }
                        }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq '/api/organization-invitations/accept') {
                        if ($token -cne $ApplicantToken -or $tenantId -cne 'global' -or
                            [string](($bodyText | ConvertFrom-Json).token) -cne $InvitationToken) {
                            throw 'Invitation acceptance did not use the applicant and secret body.'
                        }
                        $response = @{
                            invitation = @{ invitationId = $InvitationId }
                            membership = @{
                                organization = @{
                                    organizationId = $WorkspaceId
                                    scopeId = $WorkspaceId
                                    name = 'Fixture workspace'
                                    slug = 'fixture-workspace'
                                }
                                membership = @{
                                    membershipId = $MembershipId
                                    subjectId = $SubjectId
                                    role = 'member'
                                    status = 'active'
                                    version = 1
                                }
                            }
                        }
                    }
                    elseif ($method -eq 'GET' -and
                        $path -eq "/api/workspace-staff-enrollment/$WorkspaceId/applications/current?sourceKind=1&sourceId=$sourceId") {
                        if ($token -cne $ApplicantToken -or $tenantId -cne 'global') {
                            throw 'Application convergence used the wrong identity or scope.'
                        }
                        $response = @{
                            applicationId = $ApplicationId
                            organizationId = $WorkspaceId
                            sourceKind = 1
                            sourceId = $sourceId
                            subjectId = $SubjectId
                            status = 5
                            staffMemberId = $StaffMemberId
                            version = 4
                        }
                    }
                    elseif ($method -eq 'GET' -and $path -eq '/api/staff/me') {
                        if ($token -cne $ApplicantToken -or $tenantId -cne $WorkspaceId) {
                            throw 'Staff read used the wrong identity or scope.'
                        }
                        $response = @{
                            staffMemberId = $StaffMemberId
                            authSubjectId = $SubjectId
                            version = 1
                        }
                    }
                    elseif ($method -eq 'POST' -and
                        $path -eq '/api/access/permissions/evaluate') {
                        if ($token -cne $ApplicantToken -or $tenantId -cne $WorkspaceId) {
                            throw 'Permission evaluation used the wrong identity or scope.'
                        }
                        $body = $bodyText | ConvertFrom-Json -Depth 12
                        $decisions = @($body.checks | ForEach-Object {
                                $allowed =
                                    ($_.scope -eq "tenant:$WorkspaceId/property:$AllowedPropertyId" -and
                                        $_.permission -in @('properties.read', 'reservations.create'))
                                @{
                                    permission = $_.permission
                                    scope = $_.scope
                                    allowed = $allowed
                                }
                            })
                        $response = @{ permissions = $decisions }
                    }
                    elseif ($method -eq 'GET' -and
                        $path -eq "/api/workspace-access/members/$SubjectId/access") {
                        if ($token -cne $OwnerToken -or $tenantId -cne $WorkspaceId) {
                            throw 'Member access read used the wrong identity or scope.'
                        }
                        $response = @{
                            subjectId = $SubjectId
                            assignments = @(@{
                                    profileId = $ProfileId
                                    profileKey = 'front-desk'
                                    profileDisplayName = 'Front desk'
                                    profileVersion = 1
                                    propertyId = $AllowedPropertyId
                                })
                        }
                    }
                    else {
                        throw "Fixture received unexpected request '$method $path'."
                    }

                    $responseText = $response | ConvertTo-Json -Depth 12 -Compress
                    Write-FixtureResponse `
                        -Stream $stream `
                        -Status $status `
                        -Reason $reason `
                        -Body $responseText
                    $requestNumber++
                    $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(2)
                }
                finally {
                    $client.Dispose()
                }
            }
            if ($Mode -eq 'Valid' -and $requestNumber -ne 19) {
                throw "Valid fixture observed $requestNumber requests; expected 19."
            }
        }
        finally {
            $listener.Stop()
        }
    } -ArgumentList @(
        $readyPath,
        $Mode,
        $workspaceId.ToString('D'),
        $allowedPropertyId.ToString('D'),
        $deniedPropertyId.ToString('D'),
        $applicationId.ToString('D'),
        $membershipId.ToString('D'),
        $staffMemberId.ToString('D'),
        $invitationId.ToString('D'),
        $profileId.ToString('D'),
        $applicantEmail,
        $ownerToken,
        $applicantToken,
        $invitationToken,
        $subjectId,
        $releaseId)

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

function Stop-BunkFyWorkspaceInvitationFixtureServer {
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
    $env:BUNKFY_SMOKE_OWNER_TOKEN = $ownerToken
    $env:BUNKFY_SMOKE_APPLICANT_TOKEN = $applicantToken
    $validServer = Start-BunkFyWorkspaceInvitationFixtureServer -Mode 'Valid'
    $validOutput = Join-Path $fixtureRoot 'valid.json'
    try {
        & $probeScript `
            -PublicOrigin $validServer.Origin `
            -ExpectedReleaseId $releaseId `
            -WorkspaceId $workspaceId `
            -AllowedPropertyId $allowedPropertyId `
            -DeniedPropertyId $deniedPropertyId `
            -ApplicantEmail $applicantEmail `
            -AllowLoopbackHttp `
            -OutputPath $validOutput `
            -Confirm:$false
        Stop-BunkFyWorkspaceInvitationFixtureServer -Server $validServer -RequireCompleted
        $validServer = $null
    }
    finally {
        if ($null -ne $validServer) {
            Stop-BunkFyWorkspaceInvitationFixtureServer -Server $validServer
        }
    }

    $evidenceText = Get-Content -LiteralPath $validOutput -Raw
    $evidence = $evidenceText | ConvertFrom-Json -Depth 8
    if ($evidence.schemaVersion -ne 1 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-workspace-invitation-probe' -or
        $evidence.result -cne 'passed' -or
        $evidence.transport -cne 'loopback-http-fixture' -or
        $evidence.releaseId -cne $releaseId -or
        @($evidence.checks).Count -ne 8 -or
        @($evidence.limitations).Count -ne 3) {
        throw 'Valid workspace invitation fixture emitted unexpected evidence.'
    }
    foreach ($forbidden in @(
            $ownerToken,
            $applicantToken,
            $invitationToken,
            $applicantEmail,
            $subjectId,
            'responseBody',
            'rawHeaders')) {
        if ($evidenceText.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Workspace invitation evidence retained a credential or personal-data value.'
        }
    }

    $invalidServer = Start-BunkFyWorkspaceInvitationFixtureServer -Mode 'DeniedPropertyAllowed'
    $invalidOutput = Join-Path $fixtureRoot 'invalid.json'
    try {
        $rejected = $false
        try {
            & $probeScript `
                -PublicOrigin $invalidServer.Origin `
                -ExpectedReleaseId $releaseId `
                -WorkspaceId $workspaceId `
                -AllowedPropertyId $allowedPropertyId `
                -DeniedPropertyId $deniedPropertyId `
                -ApplicantEmail $applicantEmail `
                -AllowLoopbackHttp `
                -OutputPath $invalidOutput `
                -Confirm:$false
        }
        catch {
            $rejected = $true
            if (-not $_.Exception.Message.Contains(
                    'expected HTTP 403',
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "Probe rejected invalid route enforcement for an unexpected reason: $($_.Exception.Message)"
            }
        }
        if (-not $rejected) {
            throw 'Probe accepted an out-of-scope property route returning HTTP 200.'
        }
        if (Test-Path -LiteralPath $invalidOutput) {
            throw 'Probe wrote passing evidence for invalid property route enforcement.'
        }
    }
    finally {
        Stop-BunkFyWorkspaceInvitationFixtureServer -Server $invalidServer
    }

    $env:BUNKFY_SMOKE_APPLICANT_TOKEN = $ownerToken
    $sameIdentityRejected = $false
    try {
        & $probeScript `
            -PublicOrigin ([Uri]'http://127.0.0.1:1/') `
            -ExpectedReleaseId $releaseId `
            -WorkspaceId $workspaceId `
            -AllowedPropertyId $allowedPropertyId `
            -DeniedPropertyId $deniedPropertyId `
            -ApplicantEmail $applicantEmail `
            -AllowLoopbackHttp `
            -OutputPath (Join-Path $fixtureRoot 'same-identity.json') `
            -Confirm:$false
    }
    catch {
        $sameIdentityRejected = $_.Exception.Message.Contains(
            'distinct accounts',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $sameIdentityRejected) {
        throw 'Workspace invitation probe accepted the same token for owner and applicant.'
    }

    Write-Host 'BunkFy deployed workspace invitation fixture passed.'
}
finally {
    Remove-Item Env:BUNKFY_SMOKE_OWNER_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:BUNKFY_SMOKE_APPLICANT_TOKEN -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
