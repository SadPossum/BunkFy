Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-retention.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-retention-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$now = [DateTimeOffset]::UtcNow
$fixture = [pscustomobject]@{
    WorkspaceId = '11111111-1111-4111-8111-111111111111'
    RawBaselineRunId = '22222222-2222-4222-8222-222222222222'
    RawObservedRunId = '33333333-3333-4333-8333-333333333333'
    SensitiveRunId = '44444444-4444-4444-8444-444444444444'
    ReaderToken = 'fixture-retention-reader-token-do-not-retain'
    RawBaselineStarted = $now.AddMinutes(-31).ToString('O')
    RawBaselineCompleted = $now.AddMinutes(-30).ToString('O')
    RawBaselineNextDue = $now.AddSeconds(30).ToString('O')
    RawObservedStarted = $now.AddSeconds(-3).ToString('O')
    RawObservedCompleted = $now.AddSeconds(-2).ToString('O')
    RawObservedNextDue = $now.AddMinutes(59).ToString('O')
    SensitiveStarted = $now.AddHours(-2).AddMinutes(-1).ToString('O')
    SensitiveCompleted = $now.AddHours(-2).ToString('O')
    SensitiveNextDue = $now.AddHours(4).ToString('O')
}

function Start-BunkFyRetentionFixtureServer {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'missing-catalogue', 'cross-workspace-leak', 'backlog')]
        [string] $Mode
    )

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
                [Parameter(Mandatory = $true)][string] $Body
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
            $Stream.Write($bytes, 0, $bytes.Length)
            $Stream.Flush()
        }

        function New-RawSchedule {
            param([Parameter(Mandatory = $true)][bool] $Advanced)

            return [ordered]@{
                ownerKey = 'ingestion'
                dataClassKey = 'raw-source-evidence'
                targetScopeKind = 1
                propertyId = $null
                executionPolicyVersion = 1
                status = 3
                lastRunId = if ($Advanced) {
                    $Fixture.RawObservedRunId
                }
                else {
                    $Fixture.RawBaselineRunId
                }
                lastStartedAtUtc = if ($Advanced) {
                    $Fixture.RawObservedStarted
                }
                else {
                    $Fixture.RawBaselineStarted
                }
                lastCompletedAtUtc = if ($Advanced) {
                    $Fixture.RawObservedCompleted
                }
                else {
                    $Fixture.RawBaselineCompleted
                }
                nextDueAtUtc = if ($Advanced) {
                    $Fixture.RawObservedNextDue
                }
                else {
                    $Fixture.RawBaselineNextDue
                }
                overdue = $false
                consecutiveFailures = 0
                lastScannedCount = if ($Advanced) { 1 } else { 0 }
                lastAffectedCount = if ($Advanced) { 1 } else { 0 }
                lastRemainingCount = if ($Advanced -and $Mode -ceq 'backlog') { 1 } else { 0 }
                outcomeCode = if ($Advanced -and $Mode -ceq 'backlog') {
                    'ingestion.raw-payload.backlog'
                }
                else {
                    'ingestion.raw-payload.completed'
                }
                holdReviewDueAtUtc = $null
            }
        }

        function New-SensitiveSchedule {
            return [ordered]@{
                ownerKey = 'ingestion'
                dataClassKey = 'sensitive-reservation-history'
                targetScopeKind = 1
                propertyId = $null
                executionPolicyVersion = 1
                status = 3
                lastRunId = $Fixture.SensitiveRunId
                lastStartedAtUtc = $Fixture.SensitiveStarted
                lastCompletedAtUtc = $Fixture.SensitiveCompleted
                nextDueAtUtc = $Fixture.SensitiveNextDue
                overdue = $false
                consecutiveFailures = 0
                lastScannedCount = 0
                lastAffectedCount = 0
                lastRemainingCount = 0
                outcomeCode = 'ingestion.sensitive-history.completed'
                holdReviewDueAtUtc = $null
            }
        }

        function New-ScheduleResponse {
            param([Parameter(Mandatory = $true)][bool] $Advanced)

            $items = [Collections.Generic.List[object]]::new()
            [void]$items.Add((New-RawSchedule -Advanced $Advanced))
            if ($Mode -cne 'missing-catalogue') {
                [void]$items.Add((New-SensitiveSchedule))
            }
            return [ordered]@{
                items = $items.ToArray()
                page = 1
                pageSize = 100
                hasMore = $false
                summary = [ordered]@{
                    total = $items.Count
                    healthy = $items.Count
                    running = 0
                    needsAttention = 0
                }
            }
        }

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)
            $targetReadCount = 0
            $requestCount = 0
            $done = $false
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            while (-not $done -and
                $requestCount -lt 10 -and
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
                    }
                    finally {
                        $reader.Dispose()
                    }

                    if ($method -cne 'GET' -or
                        $path -cne '/api/retention/schedules?page=1&pageSize=100') {
                        throw "Fixture received unexpected request '$method $path'."
                    }
                    if ([string]$headers['Authorization'] -cne
                        "Bearer $($Fixture.ReaderToken)") {
                        throw 'Fixture request used the wrong bearer token.'
                    }

                    $requestCount++
                    $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
                    $tenantId = [string]$headers['X-Tenant-Id']
                    if ($tenantId -cne $Fixture.WorkspaceId) {
                        if ($Mode -ceq 'cross-workspace-leak') {
                            $body = New-ScheduleResponse -Advanced $false |
                                ConvertTo-Json -Depth 12 -Compress
                            Write-FixtureResponse `
                                -Stream $stream `
                                -Status 200 `
                                -Reason 'OK' `
                                -Body $body
                        }
                        else {
                            Write-FixtureResponse `
                                -Stream $stream `
                                -Status 403 `
                                -Reason 'Forbidden' `
                                -Body '{"title":"forbidden"}'
                        }
                        $done = $Mode -ceq 'cross-workspace-leak'
                        continue
                    }

                    $targetReadCount++
                    $body = New-ScheduleResponse -Advanced ($targetReadCount -gt 1) |
                        ConvertTo-Json -Depth 12 -Compress
                    Write-FixtureResponse `
                        -Stream $stream `
                        -Status 200 `
                        -Reason 'OK' `
                        -Body $body
                    if ($Mode -in @('valid', 'backlog') -and $targetReadCount -ge 2) {
                        $done = $true
                    }
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
    } -ArgumentList $readyPath, $Mode, $fixture

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath) -and
        [DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
    }
    if (-not (Test-Path -LiteralPath $readyPath)) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw "The $Mode Retention fixture did not become ready."
    }
    $port = [int](Get-Content -LiteralPath $readyPath -Raw)
    return [pscustomobject]@{
        Job = $job
        Origin = [Uri]"http://127.0.0.1:$port"
    }
}

function Complete-BunkFyRetentionFixtureServer {
    param([Parameter(Mandatory = $true)][object] $Server)

    try {
        $completed = Wait-Job -Job $Server.Job -Timeout 15
        if ($null -eq $completed) {
            throw 'The Retention fixture server did not terminate after the probe.'
        }
        $output = @(Receive-Job -Job $Server.Job -ErrorAction Stop)
        if ($Server.Job.State -ne 'Completed') {
            throw "The Retention fixture ended in state '$($Server.Job.State)': $($output -join [Environment]::NewLine)"
        }
    }
    finally {
        Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    }
}

function Stop-BunkFyRetentionFixtureServer {
    param([AllowNull()][object] $Server)

    if ($null -eq $Server) {
        return
    }
    Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
}

function Invoke-BunkFyRetentionFixtureProbe {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'missing-catalogue', 'cross-workspace-leak', 'backlog')]
        [string] $Mode,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $server = $null
    try {
        $server = Start-BunkFyRetentionFixtureServer -Mode $Mode
        $token = ConvertTo-SecureString $fixture.ReaderToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin $server.Origin `
            -WorkspaceId $fixture.WorkspaceId `
            -ReaderAccessToken $token `
            -RequestTimeoutSeconds 5 `
            -CycleTimeoutSeconds 30 `
            -PollIntervalMilliseconds 500 `
            -ClockSkewSeconds 120 `
            -OutputPath $OutputPath `
            -AllowLoopbackHttp
        Complete-BunkFyRetentionFixtureServer -Server $server
        $server = $null
    }
    finally {
        Stop-BunkFyRetentionFixtureServer -Server $server
    }
}

try {
    $validOutput = Join-Path $fixtureRoot 'valid-evidence.json'
    Invoke-BunkFyRetentionFixtureProbe -Mode valid -OutputPath $validOutput
    $evidence = Get-Content -LiteralPath $validOutput -Raw |
        ConvertFrom-Json -Depth 12
    if ($evidence.schemaVersion -ne 1 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-retention-probe' -or
        $evidence.result -cne 'passed' -or
        @($evidence.checks).Count -ne 6 -or
        @($evidence.schedules).Count -ne 2 -or
        [Guid]$evidence.schedules[0].lastRunId -ne
            [Guid]$fixture.RawObservedRunId) {
        throw 'The valid Retention fixture produced invalid evidence.'
    }
    $evidenceText = Get-Content -LiteralPath $validOutput -Raw
    foreach ($sensitive in @(
            $fixture.ReaderToken,
            'Authorization',
            'X-Tenant-Id')) {
        if ($evidenceText.Contains($sensitive, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Retention evidence retained a credential or request header.'
        }
    }

    $missingOutput = Join-Path $fixtureRoot 'missing-evidence.json'
    $missingRejected = $false
    try {
        Invoke-BunkFyRetentionFixtureProbe `
            -Mode missing-catalogue `
            -OutputPath $missingOutput
    }
    catch {
        $missingRejected = $_.Exception.Message.Contains(
            'was not unique',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $missingRejected -or (Test-Path -LiteralPath $missingOutput)) {
        throw 'The Retention probe accepted a missing expected schedule or wrote passing evidence.'
    }

    $leakOutput = Join-Path $fixtureRoot 'cross-workspace-leak-evidence.json'
    $leakRejected = $false
    try {
        Invoke-BunkFyRetentionFixtureProbe `
            -Mode cross-workspace-leak `
            -OutputPath $leakOutput
    }
    catch {
        $leakRejected = $_.Exception.Message.Contains(
            'expected HTTP 403',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $leakRejected -or (Test-Path -LiteralPath $leakOutput)) {
        throw 'The Retention probe accepted cross-workspace schedule disclosure or wrote passing evidence.'
    }

    $backlogOutput = Join-Path $fixtureRoot 'backlog-evidence.json'
    $backlogRejected = $false
    try {
        Invoke-BunkFyRetentionFixtureProbe `
            -Mode backlog `
            -OutputPath $backlogOutput
    }
    catch {
        $backlogRejected = $_.Exception.Message.Contains(
            'did not converge without backlog',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $backlogRejected -or (Test-Path -LiteralPath $backlogOutput)) {
        throw 'The Retention probe accepted an expected schedule with retained backlog or wrote passing evidence.'
    }

    $insecureOriginRejected = $false
    try {
        $token = ConvertTo-SecureString $fixture.ReaderToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://retention.example.test:8080') `
            -WorkspaceId $fixture.WorkspaceId `
            -ReaderAccessToken $token `
            -OutputPath (Join-Path $fixtureRoot 'insecure-origin.json')
    }
    catch {
        $insecureOriginRejected = $_.Exception.Message.Contains(
            'must use HTTPS',
            [StringComparison]::Ordinal)
    }
    if (-not $insecureOriginRejected) {
        throw 'The Retention probe accepted insecure non-loopback HTTP.'
    }

    Write-Host 'BunkFy deployed Retention fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
