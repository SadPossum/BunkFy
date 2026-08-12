[CmdletBinding()]
param([string] $RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$root = [IO.Path]::GetFullPath($RepositoryRoot)
. (Join-Path $root 'eng/image-candidate.common.ps1')

$rehearsalScript = Join-Path $root 'eng/operations/rehearse-deployed-release-rollback.ps1'
if (-not [IO.File]::Exists($rehearsalScript)) {
    throw "Missing deployed release rollback rehearsal '$rehearsalScript'."
}

function New-TestPromotionEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][string] $ReleaseId,
        [Parameter(Mandatory = $true)][string] $SourceCommit,
        [Parameter(Mandatory = $true)][char] $DigestSeed
    )

    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $promotionId = [Guid]::NewGuid()
    $archiveHash = ([string]$DigestSeed) * 64
    $backendDigest = 'sha256:' + ([string][char]([int]$DigestSeed + 1)) * 64
    $webDigest = 'sha256:' + ([string][char]([int]$DigestSeed + 2)) * 64
    $record = [ordered]@{
        schemaVersion = 1
        evidenceKind = 'bunkfy-image-promotion'
        promotionId = $promotionId.ToString('D')
        promotionEvidenceReference = "promotion:$($promotionId.ToString('N'))"
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        result = 'passed'
        repository = 'SadPossum/BunkFy'
        releaseId = $ReleaseId
        sourceCommit = $SourceCommit
        platform = 'linux/amd64'
        candidate = [ordered]@{
            bundleChecksumsSha256 = $archiveHash
            attestationsVerified = $false
        }
        images = @(
            [ordered]@{
                name = 'backend'
                sourceArchiveSha256 = $archiveHash
                sourceManifestDigest = $backendDigest
                tagReference = "registry.fixture.invalid/bunkfy/backend:$ReleaseId"
                digestReference = "registry.fixture.invalid/bunkfy/backend@$backendDigest"
                outcome = 'published'
            },
            [ordered]@{
                name = 'web'
                sourceArchiveSha256 = ([string][char]([int]$DigestSeed + 3)) * 64
                sourceManifestDigest = $webDigest
                tagReference = "registry.fixture.invalid/bunkfy/web:$ReleaseId"
                digestReference = "registry.fixture.invalid/bunkfy/web@$webDigest"
                outcome = 'published'
            })
        limitations = @(
            'registry-tag-immutability-policy-not-observed',
            'deployment-not-observed',
            'rollback-not-executed')
    }
    $recordPath = Join-Path $Directory 'promotion.json'
    Write-BunkFyCandidateJson -Path $recordPath -Value $record
    $recordHash = (Get-FileHash $recordPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $Directory 'checksums.sha256'),
        "$recordHash  promotion.json`n",
        [Text.UTF8Encoding]::new($false))
}

function Start-TestRollbackEdge {
    param(
        [Parameter(Mandatory = $true)][string] $FixtureRoot,
        [Parameter(Mandatory = $true)][string] $InitialReleaseId
    )

    $statePath = Join-Path $FixtureRoot "release-$([Guid]::NewGuid().ToString('N')).txt"
    $readyPath = Join-Path $FixtureRoot "ready-$([Guid]::NewGuid().ToString('N')).txt"
    [IO.File]::WriteAllText($statePath, $InitialReleaseId)
    $job = Start-Job -ScriptBlock {
        param($ReadyPath, $StatePath)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)
            $requestCount = 0
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
            while ($requestCount -lt 200 -and [DateTimeOffset]::UtcNow -lt $deadline) {
                if (-not $listener.Pending()) {
                    Start-Sleep -Milliseconds 20
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
                            throw 'Rollback fixture received an empty request line.'
                        }
                        $parts = $requestLine.Split(' ')
                        if ($parts.Count -lt 2 -or $parts[0] -ne 'GET') {
                            throw "Rollback fixture received unsupported request '$requestLine'."
                        }
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

                    $releaseId = [IO.File]::ReadAllText($StatePath).Trim()
                    $status = 404
                    $reason = 'Not Found'
                    $contentType = 'application/json; charset=utf-8'
                    $bodyText = '{}'
                    $hostValue = if ($headers.ContainsKey('Host')) {
                        [string]$headers['Host']
                    }
                    else {
                        ''
                    }
                    if ($hostValue.StartsWith(
                            'untrusted.invalid',
                            [StringComparison]::OrdinalIgnoreCase)) {
                        $status = 421
                        $reason = 'Misdirected Request'
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
                            releaseId = $releaseId
                            timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                        } | ConvertTo-Json -Compress
                    }

                    $body = [Text.UTF8Encoding]::new($false).GetBytes($bodyText)
                    $responseHeaders = [Collections.Generic.List[string]]::new()
                    $responseHeaders.Add("HTTP/1.1 $status $reason")
                    $responseHeaders.Add('Connection: close')
                    $responseHeaders.Add("Content-Length: $($body.Length)")
                    if ($null -ne $contentType) {
                        $responseHeaders.Add("Content-Type: $contentType")
                    }
                    $responseHeaders.Add("X-BunkFy-Release-Id: $releaseId")
                    $responseHeaders.Add('X-Content-Type-Options: nosniff')
                    $responseHeaders.Add('X-Frame-Options: DENY')
                    $responseHeaders.Add('Referrer-Policy: strict-origin-when-cross-origin')
                    $responseHeaders.Add(
                        "Content-Security-Policy: default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'")
                    $responseHeaders.Add(
                        'Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()')
                    $responseHeaders.Add('Strict-Transport-Security: max-age=31536000')
                    $responseHeaders.Add('Cross-Origin-Opener-Policy: same-origin')
                    $responseHeaders.Add('X-Permitted-Cross-Domain-Policies: none')
                    $headerBytes = [Text.Encoding]::ASCII.GetBytes(
                        (($responseHeaders -join "`r`n") + "`r`n`r`n"))
                    $stream.Write($headerBytes, 0, $headerBytes.Length)
                    if ($body.Length -gt 0) {
                        $stream.Write($body, 0, $body.Length)
                    }
                    $stream.Flush()
                    $requestCount++
                    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
                }
                finally {
                    $client.Dispose()
                }
            }
        }
        finally {
            $listener.Stop()
        }
    } -ArgumentList $readyPath, $statePath

    $readyDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while (-not [IO.File]::Exists($readyPath)) {
        if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
            $details = Receive-Job $job -Keep 2>&1 | Out-String
            Remove-Job $job -Force
            throw "Rollback fixture stopped before becoming ready. $details"
        }
        if ([DateTimeOffset]::UtcNow -ge $readyDeadline) {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force
            throw 'Rollback fixture did not become ready in time.'
        }
        Start-Sleep -Milliseconds 50
    }

    return [pscustomobject]@{
        Job = $job
        StatePath = $statePath
        ReadyPath = $readyPath
        Origin = [Uri]"http://127.0.0.1:$([IO.File]::ReadAllText($readyPath))/"
    }
}

function Stop-TestRollbackEdge {
    param([Parameter(Mandatory = $true)][object] $Server)

    if ($Server.Job.State -notin @('Completed', 'Failed', 'Stopped')) {
        Stop-Job $Server.Job -ErrorAction SilentlyContinue
    }
    $details = Receive-Job $Server.Job -Keep 2>&1 | Out-String
    if ($Server.Job.ChildJobs[0].Error.Count -gt 0) {
        throw "Rollback fixture failed. $details"
    }
    Remove-Job $Server.Job -Force -ErrorAction SilentlyContinue
}

function Assert-TestFailure {
    param(
        [Parameter(Mandatory = $true)][hashtable] $Arguments,
        [Parameter(Mandatory = $true)][string] $ExpectedMessage,
        [Parameter(Mandatory = $true)][string] $Context
    )

    try {
        & $rehearsalScript @Arguments | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains(
                $ExpectedMessage,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unexpected $Context rejection: $($_.Exception.Message)"
        }
        return
    }
    throw "$Context did not reject '$ExpectedMessage'."
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "bunkfy-rollback-fixture-$([Guid]::NewGuid().ToString('N'))")
try {
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $candidateRelease = 'release-candidate-001'
    $rollbackRelease = 'release-rollback-001'
    $candidateSource = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $rollbackSource = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $candidatePromotion = Join-Path $temporaryRoot 'candidate-promotion'
    $rollbackPromotion = Join-Path $temporaryRoot 'rollback-promotion'
    New-TestPromotionEvidence `
        -Directory $candidatePromotion `
        -ReleaseId $candidateRelease `
        -SourceCommit $candidateSource `
        -DigestSeed '1'
    New-TestPromotionEvidence `
        -Directory $rollbackPromotion `
        -ReleaseId $rollbackRelease `
        -SourceCommit $rollbackSource `
        -DigestSeed '4'

    Assert-TestFailure `
        -Arguments @{
            PublicOrigin = [Uri]'https://example.test/'
            CandidatePromotionDirectory = $candidatePromotion
            CandidateReleaseId = $candidateRelease
            CandidateSourceCommit = $candidateSource
            RollbackPromotionDirectory = $rollbackPromotion
            RollbackReleaseId = $rollbackRelease
            RollbackSourceCommit = $rollbackSource
            AllowFixtureEvidence = $true
        } `
        -ExpectedMessage 'explicit loopback rehearsal' `
        -Context 'fixture scope'

    $server = Start-TestRollbackEdge `
        -FixtureRoot $temporaryRoot `
        -InitialReleaseId $candidateRelease
    $output = Join-Path $temporaryRoot 'passing-evidence'
    $transition = Start-Job -ScriptBlock {
        param($StatePath, $RollbackRelease, $CandidateRelease, $OutputDirectory)

        function Wait-ForProbeEvidence {
            param(
                [Parameter(Mandatory = $true)][string] $Name,
                [Parameter(Mandatory = $true)][string] $OutputDirectory
            )

            $parent = Split-Path -Parent $OutputDirectory
            $prefix = [IO.Path]::GetFileName($OutputDirectory) + '.tmp-'
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            while ([DateTimeOffset]::UtcNow -lt $deadline) {
                foreach ($directory in [IO.Directory]::GetDirectories($parent, "$prefix*")) {
                    if ([IO.File]::Exists((Join-Path $directory $Name))) {
                        return
                    }
                }
                Start-Sleep -Milliseconds 50
            }
            throw "Timed out waiting for rollback fixture evidence '$Name'."
        }

        function Set-FixtureRelease {
            param(
                [Parameter(Mandatory = $true)][string] $StatePath,
                [Parameter(Mandatory = $true)][string] $ReleaseId
            )

            $temporaryPath = "$StatePath.$([Guid]::NewGuid().ToString('N')).tmp"
            [IO.File]::WriteAllText($temporaryPath, $ReleaseId)
            [IO.File]::Move($temporaryPath, $StatePath, $true)
        }

        Wait-ForProbeEvidence `
            -Name 'candidate-baseline-public-edge.json' `
            -OutputDirectory $OutputDirectory
        Set-FixtureRelease -StatePath $StatePath -ReleaseId $RollbackRelease
        Wait-ForProbeEvidence `
            -Name 'rollback-public-edge.json' `
            -OutputDirectory $OutputDirectory
        Set-FixtureRelease -StatePath $StatePath -ReleaseId $CandidateRelease
    } -ArgumentList $server.StatePath, $rollbackRelease, $candidateRelease, $output
    try {
        $result = & $rehearsalScript `
            -PublicOrigin $server.Origin `
            -CandidatePromotionDirectory $candidatePromotion `
            -CandidateReleaseId $candidateRelease `
            -CandidateSourceCommit $candidateSource `
            -RollbackPromotionDirectory $rollbackPromotion `
            -RollbackReleaseId $rollbackRelease `
            -RollbackSourceCommit $rollbackSource `
            -OutputDirectory $output `
            -RequestTimeoutSeconds 2 `
            -TransitionTimeoutSeconds 10 `
            -PollIntervalMilliseconds 250 `
            -AllowLoopbackHttp `
            -AllowFixtureEvidence `
            -PassThru
        [void](Wait-Job $transition -Timeout 20)
        if ($transition.State -ne 'Completed') {
            throw 'Rollback fixture transition did not complete.'
        }
        Receive-Job $transition -ErrorAction Stop | Out-Null
    }
    finally {
        Remove-Job $transition -Force -ErrorAction SilentlyContinue
        Stop-TestRollbackEdge -Server $server
    }

    $closed = Get-BunkFyClosedChecksumSet `
        -Directory $output `
        -MaximumPayloadBytes 4MB `
        -Context 'Rollback fixture evidence'
    $record = [IO.File]::ReadAllText((Join-Path $output 'rollback-rehearsal.json')) |
        ConvertFrom-Json -Depth 12
    if ($closed.Files.Count -ne 4 -or
        $record.schemaVersion -ne 1 -or
        $record.evidenceKind -cne 'bunkfy-deployed-release-rollback-rehearsal' -or
        $record.result -cne 'passed' -or
        $record.rollbackEvidenceReference -cnotmatch '^rollback:[0-9a-f]{32}$' -or
        $record.candidate.releaseId -cne $candidateRelease -or
        $record.rollback.releaseId -cne $rollbackRelease -or
        @($record.checks).Count -ne 3 -or
        @($record.limitations).Count -ne 5 -or
        $result.rollbackEvidenceReference -cne $record.rollbackEvidenceReference) {
        throw 'Rollback fixture emitted invalid closed evidence.'
    }
    foreach ($name in @(
            'candidate-baseline-public-edge.json',
            'rollback-public-edge.json',
            'candidate-restored-public-edge.json')) {
        $edge = [IO.File]::ReadAllText((Join-Path $output $name)) |
            ConvertFrom-Json -Depth 8
        if ($edge.schemaVersion -ne 3 -or
            $edge.result -cne 'passed' -or
            @($edge.checks).Count -ne 6) {
            throw "Rollback fixture contains invalid public-edge evidence '$name'."
        }
    }
    $serialized = [IO.File]::ReadAllText((Join-Path $output 'rollback-rehearsal.json'))
    foreach ($forbidden in @('password', 'token', 'responseBody', 'rawHeaders')) {
        if ($serialized.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Rollback evidence contains forbidden field '$forbidden'."
        }
    }

    Assert-TestFailure `
        -Arguments @{
            PublicOrigin = $server.Origin
            CandidatePromotionDirectory = $candidatePromotion
            CandidateReleaseId = $candidateRelease
            CandidateSourceCommit = $candidateSource
            RollbackPromotionDirectory = $candidatePromotion
            RollbackReleaseId = $candidateRelease
            RollbackSourceCommit = $candidateSource
            OutputDirectory = (Join-Path $temporaryRoot 'rejected-same-release')
            AllowLoopbackHttp = $true
            AllowFixtureEvidence = $true
        } `
        -ExpectedMessage 'distinct releases' `
        -Context 'identical promotion'

    $timeoutServer = Start-TestRollbackEdge `
        -FixtureRoot $temporaryRoot `
        -InitialReleaseId $candidateRelease
    $timeoutOutput = Join-Path $temporaryRoot 'rejected-timeout'
    try {
        Assert-TestFailure `
            -Arguments @{
                PublicOrigin = $timeoutServer.Origin
                CandidatePromotionDirectory = $candidatePromotion
                CandidateReleaseId = $candidateRelease
                CandidateSourceCommit = $candidateSource
                RollbackPromotionDirectory = $rollbackPromotion
                RollbackReleaseId = $rollbackRelease
                RollbackSourceCommit = $rollbackSource
                OutputDirectory = $timeoutOutput
                RequestTimeoutSeconds = 2
                TransitionTimeoutSeconds = 1
                PollIntervalMilliseconds = 250
                AllowLoopbackHttp = $true
                AllowFixtureEvidence = $true
            } `
            -ExpectedMessage 'Timed out waiting for rollback' `
            -Context 'missing rollback transition'
    }
    finally {
        Stop-TestRollbackEdge -Server $timeoutServer
    }
    if ([IO.Directory]::Exists($timeoutOutput)) {
        throw 'Timed-out rollback rehearsal left passing evidence.'
    }
}
finally {
    if ([IO.Directory]::Exists($temporaryRoot)) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}

Write-Host 'BunkFy deployed release rollback fixture passed.'
