Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'operations\deployed-public-edge.common.ps1')

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-public-edge.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-edge-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

function Start-BunkFyEdgeFixtureServer {
    param([Parameter(Mandatory = $true)][string] $Mode)

    $readyPath = Join-Path $fixtureRoot ("ready-$Mode-$([Guid]::NewGuid().ToString('N')).txt")
    $job = Start-Job -ScriptBlock {
        param($ReadyPath, $Mode)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)

            $requestNumber = 0
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
            while ($requestNumber -lt 5 -and
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
                    }
                    finally {
                        $reader.Dispose()
                    }

                    $status = 404
                    $reason = 'Not Found'
                    $contentType = 'application/json; charset=utf-8'
                    $bodyText = '{}'
                    $hostValue = if ($headers.ContainsKey('Host')) { [string]$headers['Host'] } else { '' }
                    if ($hostValue.StartsWith('untrusted.invalid', [StringComparison]::OrdinalIgnoreCase)) {
                        if ($Mode -eq 'HostAccepted') {
                            $status = 200
                            $reason = 'OK'
                            $bodyText = [ordered]@{
                                application = 'BunkFy'
                                service = 'BunkFy.Host.Api'
                                status = 'ok'
                                releaseId = 'release-fixture-001'
                                timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                            } | ConvertTo-Json -Compress
                        }
                        else {
                            $status = 421
                            $reason = 'Misdirected Request'
                            $bodyText = '{}'
                        }
                    }
                    elseif ($path -eq '/') {
                        $status = 200
                        $reason = 'OK'
                        $contentType = 'text/html; charset=utf-8'
                        $bodyText = '<!doctype html><title>BunkFy</title>'
                    }
                    elseif ($path -eq '/healthz') {
                        $status = 204
                        $reason = 'No Content'
                        $contentType = $null
                        $bodyText = ''
                    }
                    elseif ($path -eq '/api/smoke') {
                        $status = 200
                        $reason = 'OK'
                        $bodyText = [ordered]@{
                            application = 'BunkFy'
                            service = 'BunkFy.Host.Api'
                            status = 'ok'
                            releaseId = if ($Mode -eq 'ReleaseMismatch') {
                                'release-fixture-other'
                            }
                            else {
                                'release-fixture-001'
                            }
                            timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                        } | ConvertTo-Json -Compress
                    }
                    elseif ($path -eq '/api/admin/audit/' -and $Mode -eq 'AdminExposed') {
                        $status = 200
                        $reason = 'OK'
                        $bodyText = '{}'
                    }

                    $body = [Text.UTF8Encoding]::new($false).GetBytes($bodyText)
                    $responseHeaders = [Collections.Generic.List[string]]::new()
                    $responseHeaders.Add("HTTP/1.1 $status $reason")
                    $responseHeaders.Add('Connection: close')
                    $responseHeaders.Add("Content-Length: $($body.Length)")
                    if ($null -ne $contentType) {
                        $responseHeaders.Add("Content-Type: $contentType")
                    }
                    $responseHeaders.Add('X-Content-Type-Options: nosniff')
                    $responseHeaders.Add('X-Frame-Options: DENY')
                    $responseHeaders.Add('Referrer-Policy: strict-origin-when-cross-origin')
                    $contentSecurityPolicy = "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'"
                    if ($Mode -eq 'ExtraCspDirective') {
                        $contentSecurityPolicy += '; frame-src *'
                    }
                    $responseHeaders.Add("Content-Security-Policy: $contentSecurityPolicy")
                    $permissionsPolicy = 'camera=(), microphone=(), geolocation=(), payment=(), usb=()'
                    if ($Mode -eq 'ExtraPermissionsFeature') {
                        $permissionsPolicy += ', fullscreen=(*)'
                    }
                    $responseHeaders.Add("Permissions-Policy: $permissionsPolicy")
                    $responseHeaders.Add('Strict-Transport-Security: max-age=31536000')
                    $responseHeaders.Add('Cross-Origin-Opener-Policy: same-origin')
                    if ($Mode -ne 'MissingHeader') {
                        $responseHeaders.Add('X-Permitted-Cross-Domain-Policies: none')
                    }

                    $headerBytes = [Text.Encoding]::ASCII.GetBytes(
                        (($responseHeaders -join "`r`n") + "`r`n`r`n"))
                    $stream.Write($headerBytes, 0, $headerBytes.Length)
                    if ($body.Length -gt 0) {
                        $stream.Write($body, 0, $body.Length)
                    }
                    $stream.Flush()
                    $requestNumber++
                    $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(2)
                }
                finally {
                    $client.Dispose()
                }
            }
        }
        finally {
            $listener.Stop()
        }
    } -ArgumentList $readyPath, $Mode

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

function Stop-BunkFyEdgeFixtureServer {
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
        $errors = Receive-Job -Job $Server.Job -Keep 2>&1 | Out-String
        if ($Server.Job.ChildJobs[0].JobStateInfo.State -ne 'Completed' -or
            $Server.Job.ChildJobs[0].Error.Count -gt 0) {
            throw "Fixture server failed. $errors"
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

function Assert-BunkFyProbeRejected {
    param(
        [Parameter(Mandatory = $true)][string] $Mode,
        [Parameter(Mandatory = $true)][string] $ExpectedMessage
    )

    $server = Start-BunkFyEdgeFixtureServer -Mode $Mode
    $output = Join-Path $fixtureRoot "$Mode.json"
    try {
        $rejected = $false
        try {
            & $probeScript `
                -PublicOrigin $server.Origin `
                -ExpectedReleaseId 'release-fixture-001' `
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
        Stop-BunkFyEdgeFixtureServer -Server $server
    }
}

try {
    $validServer = Start-BunkFyEdgeFixtureServer -Mode 'Valid'
    $validOutput = Join-Path $fixtureRoot 'valid.json'
    try {
        & $probeScript `
            -PublicOrigin $validServer.Origin `
            -ExpectedReleaseId 'release-fixture-001' `
            -AllowLoopbackHttp `
            -OutputPath $validOutput
        Stop-BunkFyEdgeFixtureServer -Server $validServer -RequireCompleted
        $validServer = $null
    }
    finally {
        if ($null -ne $validServer) {
            Stop-BunkFyEdgeFixtureServer -Server $validServer
        }
    }

    $evidence = Get-Content -LiteralPath $validOutput -Raw | ConvertFrom-Json -Depth 8
    if ($evidence.schemaVersion -ne 2 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-public-edge-probe' -or
        $evidence.result -cne 'passed' -or
        $evidence.transport -cne 'loopback-http-fixture' -or
        $evidence.releaseId -cne 'release-fixture-001' -or
        @($evidence.checks).Count -ne 5 -or
        @($evidence.limitations).Count -ne 3) {
        throw 'Valid edge fixture emitted unexpected evidence.'
    }
    $serializedEvidence = Get-Content -LiteralPath $validOutput -Raw
    foreach ($forbidden in @('responseBody', 'rawHeaders', 'sourceCommit', 'imageDigest')) {
        if ($serializedEvidence.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Edge evidence contains forbidden field '$forbidden'."
        }
    }

    Assert-BunkFyProbeRejected `
        -Mode 'ReleaseMismatch' `
        -ExpectedMessage 'does not match'
    Assert-BunkFyProbeRejected `
        -Mode 'MissingHeader' `
        -ExpectedMessage 'X-Permitted-Cross-Domain-Policies'
    Assert-BunkFyProbeRejected `
        -Mode 'AdminExposed' `
        -ExpectedMessage 'expected HTTP 404'
    Assert-BunkFyProbeRejected `
        -Mode 'HostAccepted' `
        -ExpectedMessage 'accepted an untrusted Host'
    Assert-BunkFyProbeRejected `
        -Mode 'ExtraCspDirective' `
        -ExpectedMessage 'outside the checked-in BunkFy policy'
    Assert-BunkFyProbeRejected `
        -Mode 'ExtraPermissionsFeature' `
        -ExpectedMessage 'outside the checked-in BunkFy policy'

    $insecureRemoteRejected = $false
    try {
        Assert-BunkFyPublicEdgeOrigin -Origin ([Uri]'http://example.test/') | Out-Null
    }
    catch {
        $insecureRemoteRejected = $true
    }
    if (-not $insecureRemoteRejected) {
        throw 'The edge origin validator accepted insecure remote HTTP.'
    }

    Write-Host 'BunkFy deployed public edge fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
