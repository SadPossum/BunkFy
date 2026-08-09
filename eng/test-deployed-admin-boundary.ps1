Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-admin-boundary.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-admin-boundary-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)
$evidenceSetId = [Guid]'11111111-1111-4111-8111-111111111111'
$releaseId = 'release-fixture-001'

function Start-BunkFyAdminBoundaryFixtureServer {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'valid-allowed',
            'valid-denied-http',
            'valid-denied-unreachable',
            'allowed-audit-exposed',
            'denied-admin-reachable',
            'denied-wrong-problem')]
        [string] $Mode
    )

    $readyPath = Join-Path $fixtureRoot (
        "ready-$Mode-$([Guid]::NewGuid().ToString('N')).json")
    $job = Start-Job -ScriptBlock {
        param($ReadyPath, $Mode, $ReleaseId)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        function Write-FixtureResponse {
            param(
                [Parameter(Mandatory = $true)][IO.Stream] $Stream,
                [Parameter(Mandatory = $true)][int] $Status,
                [Parameter(Mandatory = $true)][string] $Reason,
                [AllowNull()][string] $ContentType,
                [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Body
            )

            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Body)
            $headers = [Collections.Generic.List[string]]::new()
            $headers.Add("HTTP/1.1 $Status $Reason")
            $headers.Add('Connection: close')
            $headers.Add("Content-Length: $($bytes.Length)")
            if (-not [string]::IsNullOrWhiteSpace($ContentType)) {
                $headers.Add("Content-Type: $ContentType")
            }
            $headerBytes = [Text.Encoding]::ASCII.GetBytes(
                (($headers -join "`r`n") + "`r`n`r`n"))
            $Stream.Write($headerBytes, 0, $headerBytes.Length)
            if ($bytes.Length -gt 0) {
                $Stream.Write($bytes, 0, $bytes.Length)
            }
            $Stream.Flush()
        }

        function Read-FixtureRequestPath {
            param([Parameter(Mandatory = $true)][IO.Stream] $Stream)

            $reader = [IO.StreamReader]::new(
                $Stream,
                [Text.UTF8Encoding]::new($false),
                $false,
                1024,
                $true)
            try {
                $requestLine = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($requestLine)) {
                    throw 'Fixture received an empty request line.'
                }
                $requestParts = $requestLine.Split(' ')
                if ($requestParts.Count -lt 2 -or $requestParts[0] -ne 'GET') {
                    throw "Fixture received unsupported request '$requestLine'."
                }
                while (-not [string]::IsNullOrEmpty($reader.ReadLine())) {
                }
                return $requestParts[1]
            }
            finally {
                $reader.Dispose()
            }
        }

        $publicListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $publicListener.Start()
        $adminListener = $null
        $adminReservation = $null
        try {
            if ($Mode -ceq 'valid-denied-unreachable') {
                $adminReservation = [Net.Sockets.Socket]::new(
                    [Net.Sockets.AddressFamily]::InterNetwork,
                    [Net.Sockets.SocketType]::Stream,
                    [Net.Sockets.ProtocolType]::Tcp)
                $adminReservation.ExclusiveAddressUse = $true
                $adminReservation.Bind(
                    [Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
                $adminPort = ([Net.IPEndPoint]$adminReservation.LocalEndPoint).Port
            }
            else {
                $adminListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
                $adminListener.Start()
                $adminPort = ([Net.IPEndPoint]$adminListener.LocalEndpoint).Port
            }
            $publicPort = ([Net.IPEndPoint]$publicListener.LocalEndpoint).Port
            [IO.File]::WriteAllText(
                $ReadyPath,
                ([ordered]@{
                        publicPort = $publicPort
                        adminPort = $adminPort
                    } | ConvertTo-Json -Compress),
                [Text.UTF8Encoding]::new($false))

            $expectedRequests = switch ($Mode) {
                'valid-allowed' { 6 }
                'allowed-audit-exposed' { 6 }
                'valid-denied-unreachable' { 4 }
                default { 5 }
            }
            $requestCount = 0
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
            while ($requestCount -lt $expectedRequests -and
                [DateTimeOffset]::UtcNow -lt $inactivityDeadline) {
                $handled = $false
                foreach ($surface in @('public', 'admin')) {
                    $listener = if ($surface -ceq 'public') {
                        $publicListener
                    }
                    else {
                        $adminListener
                    }
                    if ($null -eq $listener -or -not $listener.Pending()) {
                        continue
                    }

                    $client = $listener.AcceptTcpClient()
                    try {
                        $client.ReceiveTimeout = 5000
                        $client.SendTimeout = 5000
                        $stream = $client.GetStream()
                        $path = Read-FixtureRequestPath -Stream $stream

                        $status = 404
                        $reason = 'Not Found'
                        $contentType = 'application/json; charset=utf-8'
                        $body = '{}'
                        if ($surface -ceq 'public' -and $path -ceq '/api/smoke') {
                            $status = 200
                            $reason = 'OK'
                            $body = [ordered]@{
                                application = 'BunkFy'
                                service = 'BunkFy.Host.Api'
                                status = 'ok'
                                releaseId = $ReleaseId
                                timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                            } | ConvertTo-Json -Compress
                        }
                        elseif ($surface -ceq 'public' -and $path -ceq '/healthz') {
                            $status = 204
                            $reason = 'No Content'
                            $contentType = $null
                            $body = ''
                        }
                        elseif ($surface -ceq 'public' -and
                            $path -ceq '/api/admin/audit/') {
                            $status = 404
                            $reason = 'Not Found'
                        }
                        elseif ($surface -ceq 'admin' -and $path -ceq '/health') {
                            if ($Mode -in @('valid-denied-http', 'denied-wrong-problem')) {
                                $status = 403
                                $reason = 'Forbidden'
                                $contentType = 'application/problem+json; charset=utf-8'
                                $title = if ($Mode -ceq 'denied-wrong-problem') {
                                    'Http.Forbidden'
                                }
                                else {
                                    'Http.PrivateNetworkRequired'
                                }
                                $body = [ordered]@{
                                    type = 'about:blank'
                                    title = $title
                                    status = 403
                                    detail = 'This endpoint is available only through an approved private network boundary.'
                                    traceId = 'fixture-trace-id-must-not-be-retained'
                                } | ConvertTo-Json -Compress
                            }
                            else {
                                $status = 200
                                $reason = 'OK'
                                $contentType = 'text/plain; charset=utf-8'
                                $body = 'Healthy'
                            }
                        }
                        elseif ($surface -ceq 'admin' -and
                            $path -ceq '/api/admin/audit/') {
                            if ($Mode -ceq 'allowed-audit-exposed') {
                                $status = 200
                                $reason = 'OK'
                                $body = '{}'
                            }
                            else {
                                $status = 401
                                $reason = 'Unauthorized'
                                $contentType = $null
                                $body = ''
                            }
                        }

                        Write-FixtureResponse `
                            -Stream $stream `
                            -Status $status `
                            -Reason $reason `
                            -ContentType $contentType `
                            -Body $body
                        $requestCount++
                        $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
                        $handled = $true
                    }
                    finally {
                        $client.Dispose()
                    }
                }
                if (-not $handled) {
                    Start-Sleep -Milliseconds 25
                }
            }
            if ($requestCount -ne $expectedRequests) {
                throw "Fixture observed $requestCount of $expectedRequests expected requests."
            }
        }
        finally {
            if ($null -ne $adminListener) {
                $adminListener.Stop()
            }
            if ($null -ne $adminReservation) {
                $adminReservation.Dispose()
            }
            $publicListener.Stop()
        }
    } -ArgumentList $readyPath, $Mode, $releaseId

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

    $ports = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
    return [pscustomobject]@{
        Job = $job
        ReadyPath = $readyPath
        PublicOrigin = [Uri]"http://127.0.0.1:$($ports.publicPort)/"
        AdminOrigin = [Uri]"http://127.0.0.1:$($ports.adminPort)/"
    }
}

function Stop-BunkFyAdminBoundaryFixtureServer {
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
        [void](Wait-Job -Job $Server.Job -Timeout 4)
        if ($Server.Job.State -notin @('Completed', 'Failed', 'Stopped')) {
            Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        }
    }

    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Server.ReadyPath -Force -ErrorAction SilentlyContinue
}

function Invoke-BunkFyValidFixture {
    param(
        [Parameter(Mandatory = $true)][string] $Mode,
        [Parameter(Mandatory = $true)][ValidateSet('Allowed', 'Denied')][string] $Reachability
    )

    $server = Start-BunkFyAdminBoundaryFixtureServer -Mode $Mode
    $output = Join-Path $fixtureRoot "$Mode.json"
    try {
        & $probeScript `
            -PublicOrigin $server.PublicOrigin `
            -ExpectedReleaseId $releaseId `
            -AdminOrigin $server.AdminOrigin `
            -ExpectedAdminReachability $Reachability `
            -EvidenceSetId $evidenceSetId `
            -RequestTimeoutSeconds 2 `
            -AllowLoopbackHttp `
            -OutputPath $output
        Stop-BunkFyAdminBoundaryFixtureServer -Server $server -RequireCompleted
        $server = $null
    }
    finally {
        if ($null -ne $server) {
            Stop-BunkFyAdminBoundaryFixtureServer -Server $server
        }
    }
    return $output
}

function Assert-BunkFyProbeRejected {
    param(
        [Parameter(Mandatory = $true)][string] $Mode,
        [Parameter(Mandatory = $true)][ValidateSet('Allowed', 'Denied')][string] $Reachability,
        [Parameter(Mandatory = $true)][string] $ExpectedMessage
    )

    $server = Start-BunkFyAdminBoundaryFixtureServer -Mode $Mode
    $output = Join-Path $fixtureRoot "$Mode-rejected.json"
    try {
        $rejected = $false
        try {
            & $probeScript `
                -PublicOrigin $server.PublicOrigin `
                -ExpectedReleaseId $releaseId `
                -AdminOrigin $server.AdminOrigin `
                -ExpectedAdminReachability $Reachability `
                -EvidenceSetId $evidenceSetId `
                -RequestTimeoutSeconds 2 `
                -AllowLoopbackHttp `
                -OutputPath $output
        }
        catch {
            $rejected = $true
            if (-not $_.Exception.Message.Contains(
                    $ExpectedMessage,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "Probe rejected '$Mode' for an unexpected reason: $($_.Exception.Message)"
            }
        }
        if (-not $rejected) {
            throw "Probe accepted invalid fixture mode '$Mode'."
        }
        if (Test-Path -LiteralPath $output) {
            throw "Probe wrote passing evidence for invalid fixture mode '$Mode'."
        }
    }
    finally {
        Stop-BunkFyAdminBoundaryFixtureServer -Server $server
    }
}

try {
    $allowedOutput = Invoke-BunkFyValidFixture `
        -Mode 'valid-allowed' `
        -Reachability Allowed
    $deniedOutput = Invoke-BunkFyValidFixture `
        -Mode 'valid-denied-http' `
        -Reachability Denied
    $unreachableOutput = Invoke-BunkFyValidFixture `
        -Mode 'valid-denied-unreachable' `
        -Reachability Denied

    $allowed = Get-Content -LiteralPath $allowedOutput -Raw | ConvertFrom-Json -Depth 8
    $denied = Get-Content -LiteralPath $deniedOutput -Raw | ConvertFrom-Json -Depth 8
    $unreachable = Get-Content -LiteralPath $unreachableOutput -Raw | ConvertFrom-Json -Depth 8
    if ($allowed.schemaVersion -ne 1 -or
        $allowed.evidenceKind -cne 'bunkfy-deployed-admin-boundary-probe' -or
        $allowed.expectedAdminReachability -cne 'allowed' -or
        $allowed.adminObservation.classification -cne 'private-reachable-auth-gated' -or
        $allowed.releaseId -cne $releaseId -or
        @($allowed.checks).Count -ne 5 -or
        @($allowed.limitations).Count -ne 3) {
        throw 'Valid allowed fixture emitted unexpected evidence.'
    }
    if ($denied.expectedAdminReachability -cne 'denied' -or
        $denied.adminObservation.classification -cne 'private-network-policy-denial' -or
        $denied.releaseId -cne $releaseId -or
        @($denied.checks).Count -ne 4) {
        throw 'Valid denied HTTP fixture emitted unexpected evidence.'
    }
    if ($unreachable.adminObservation.classification -cne 'network-unreachable' -or
        $unreachable.adminObservation.outcome -cne 'connection-unreachable' -or
        $unreachable.releaseId -cne $releaseId -or
        @($unreachable.checks).Count -ne 4) {
        throw 'Valid unreachable fixture emitted unexpected evidence.'
    }
    foreach ($candidate in @($allowed, $denied, $unreachable)) {
        if ([Guid]$candidate.evidenceSetId -ne $evidenceSetId -or
            $candidate.result -cne 'passed' -or
            $candidate.transport -cne 'loopback-http-fixture') {
            throw 'Admin boundary evidence did not retain the expected correlation and result metadata.'
        }
    }

    $serializedEvidence = @(
        Get-Content -LiteralPath $allowedOutput -Raw
        Get-Content -LiteralPath $deniedOutput -Raw
        Get-Content -LiteralPath $unreachableOutput -Raw) -join "`n"
    foreach ($forbidden in @(
            'responseBody',
            'rawHeaders',
            'traceId',
            'fixture-trace-id',
            'Http.PrivateNetworkRequired',
            'accessToken')) {
        if ($serializedEvidence.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Admin boundary evidence contains forbidden field or value '$forbidden'."
        }
    }

    Assert-BunkFyProbeRejected `
        -Mode 'allowed-audit-exposed' `
        -Reachability Allowed `
        -ExpectedMessage 'expected HTTP 401 or 403'
    Assert-BunkFyProbeRejected `
        -Mode 'denied-admin-reachable' `
        -Reachability Denied `
        -ExpectedMessage 'expected HTTP 403 or a network boundary'
    Assert-BunkFyProbeRejected `
        -Mode 'denied-wrong-problem' `
        -Reachability Denied `
        -ExpectedMessage 'expected private-network Problem Details'

    $insecureRemoteRejected = $false
    try {
        & $probeScript `
            -PublicOrigin ([Uri]'https://public.example.test/') `
            -ExpectedReleaseId $releaseId `
            -AdminOrigin ([Uri]'http://admin.example.test/') `
            -ExpectedAdminReachability Denied `
            -EvidenceSetId $evidenceSetId `
            -OutputPath (Join-Path $fixtureRoot 'insecure.json')
    }
    catch {
        $insecureRemoteRejected = $_.Exception.Message.Contains(
            'must use HTTPS',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $insecureRemoteRejected) {
        throw 'The Admin boundary verifier accepted insecure non-loopback HTTP.'
    }

    $sameAuthorityRejected = $false
    try {
        & $probeScript `
            -PublicOrigin ([Uri]'https://candidate.example.test/') `
            -ExpectedReleaseId $releaseId `
            -AdminOrigin ([Uri]'https://candidate.example.test/') `
            -ExpectedAdminReachability Allowed `
            -EvidenceSetId $evidenceSetId `
            -OutputPath (Join-Path $fixtureRoot 'same-authority.json')
    }
    catch {
        $sameAuthorityRejected = $_.Exception.Message.Contains(
            'distinct authorities',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $sameAuthorityRejected) {
        throw 'The Admin boundary verifier accepted one authority for public and Admin traffic.'
    }

    Write-Host 'BunkFy deployed Admin API boundary fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
