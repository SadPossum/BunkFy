param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][Guid] $WorkspaceId,
    [Security.SecureString] $ReaderAccessToken,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [ValidateRange(30, 7200)][int] $CycleTimeoutSeconds = 4500,
    [ValidateRange(500, 60000)][int] $PollIntervalMilliseconds = 30000,
    [ValidateRange(0, 600)][int] $ClockSkewSeconds = 120,
    [string] $OutputPath,
    [switch] $AllowLoopbackHttp,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'deployed-public-edge.common.ps1')
. (Join-Path $PSScriptRoot 'deployed-authenticated-smoke.common.ps1')

$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackHttp
if ($WorkspaceId -eq [Guid]::Empty) {
    throw 'WorkspaceId must not be an empty GUID.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/retention-$stamp.json"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) {
    $item = Get-Item -LiteralPath $OutputPath -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The output path is not a regular file: '$OutputPath'."
    }
    if (-not $Force) {
        throw "The output file already exists: '$OutputPath'. Use -Force to replace it."
    }
}

$readerToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $ReaderAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_RETENTION_READER_TOKEN' `
    -Prompt 'Retention reader access token'
if ([string]::IsNullOrWhiteSpace($readerToken)) {
    throw 'The Retention reader access token is required.'
}

$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$handler.AutomaticDecompression =
    [Net.DecompressionMethods]::GZip -bor
    [Net.DecompressionMethods]::Deflate -bor
    [Net.DecompressionMethods]::Brotli
$client = [Net.Http.HttpClient]::new($handler, $true)
$client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Deployed-Retention-Probe/1')
$checks = [Collections.Generic.List[object]]::new()
$finalSnapshot = $null

$expectedSchedules = @(
    [pscustomobject]@{
        OwnerKey = 'ingestion'
        DataClassKey = 'raw-source-evidence'
        TargetScopeKind = 1
        ExecutionPolicyVersion = 1
        OutcomeCode = 'ingestion.raw-payload.completed'
        MaximumCompletionAge = [TimeSpan]::FromHours(2)
    },
    [pscustomobject]@{
        OwnerKey = 'ingestion'
        DataClassKey = 'sensitive-reservation-history'
        TargetScopeKind = 1
        ExecutionPolicyVersion = 1
        OutcomeCode = 'ingestion.sensitive-history.completed'
        MaximumCompletionAge = [TimeSpan]::FromHours(8)
    })
$observedSchedule = $expectedSchedules[0]

function Invoke-SmokeApi {
    param([Parameter(Mandatory = $true)][Guid] $TenantId)

    return Invoke-BunkFyAuthenticatedJsonRequest `
        -Client $client `
        -Origin $origin `
        -Path '/api/retention/schedules?page=1&pageSize=100' `
        -Method GET `
        -TenantId $TenantId.ToString('D') `
        -AccessToken $readerToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body $null
}

function Invoke-SmokeSchedulePage {
    param(
        [Parameter(Mandatory = $true)][Guid] $TenantId,
        [Parameter(Mandatory = $true)][int] $Page
    )

    return Invoke-BunkFyAuthenticatedJsonRequest `
        -Client $client `
        -Origin $origin `
        -Path "/api/retention/schedules?page=$Page&pageSize=100" `
        -Method GET `
        -TenantId $TenantId.ToString('D') `
        -AccessToken $readerToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body $null
}

function Read-SmokeJson {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    return ConvertFrom-BunkFyAuthenticatedJsonResponse `
        -Response $Response `
        -ExpectedStatus $ExpectedStatus `
        -Operation $Operation
}

function Get-ScheduleCoordinate {
    param([Parameter(Mandatory = $true)][object] $Schedule)

    $target = if ($null -eq $Schedule.propertyId) {
        'tenant'
    }
    else {
        ([Guid]$Schedule.propertyId).ToString('D')
    }
    return "$([string]$Schedule.ownerKey)|$([string]$Schedule.dataClassKey)|$target|$([int]$Schedule.executionPolicyVersion)"
}

function Get-SmokeRetentionSnapshot {
    $items = [Collections.Generic.List[object]]::new()
    $coordinates = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $summary = $null
    $page = 1
    do {
        $response = Read-SmokeJson `
            -Response (Invoke-SmokeSchedulePage -TenantId $WorkspaceId -Page $page) `
            -ExpectedStatus 200 `
            -Operation "Read Retention schedules page $page"
        if ([int]$response.page -ne $page -or [int]$response.pageSize -ne 100) {
            throw 'Retention schedule pagination metadata does not match the requested page.'
        }
        if ($page -eq 1) {
            $summary = $response.summary
        }
        elseif ([int]$response.summary.total -ne [int]$summary.total -or
            [int]$response.summary.healthy -ne [int]$summary.healthy -or
            [int]$response.summary.running -ne [int]$summary.running -or
            [int]$response.summary.needsAttention -ne [int]$summary.needsAttention) {
            throw 'Retention schedule summary changed while paging the bounded catalogue.'
        }

        foreach ($schedule in @($response.items)) {
            $coordinate = Get-ScheduleCoordinate -Schedule $schedule
            if (-not $coordinates.Add($coordinate)) {
                throw "Retention schedule coordinate '$coordinate' is duplicated."
            }
            [void]$items.Add($schedule)
        }

        $hasMore = [bool]$response.hasMore
        $page++
        if ($page -gt 100) {
            throw 'Retention schedule lookup exceeded 100 pages.'
        }
    } while ($hasMore)

    if ($null -eq $summary -or [int]$summary.total -ne $items.Count) {
        throw 'Retention schedule summary total does not match the bounded catalogue.'
    }
    return [pscustomobject]@{
        Items = $items.ToArray()
        Summary = $summary
    }
}

function Get-ExpectedSchedule {
    param(
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [Parameter(Mandatory = $true)][object] $Expected
    )

    $matches = @($Snapshot.Items | Where-Object {
            [string]$_.ownerKey -ceq [string]$Expected.OwnerKey -and
            [string]$_.dataClassKey -ceq [string]$Expected.DataClassKey -and
            [int]$_.targetScopeKind -eq [int]$Expected.TargetScopeKind -and
            $null -eq $_.propertyId -and
            [int]$_.executionPolicyVersion -eq [int]$Expected.ExecutionPolicyVersion
        })
    if ($matches.Count -ne 1) {
        throw "Expected Retention schedule '$($Expected.OwnerKey).$($Expected.DataClassKey).v$($Expected.ExecutionPolicyVersion)' was not unique."
    }
    return $matches[0]
}

function Assert-ExpectedCatalogue {
    param([Parameter(Mandatory = $true)][object] $Snapshot)

    foreach ($expected in $expectedSchedules) {
        [void](Get-ExpectedSchedule -Snapshot $Snapshot -Expected $expected)
    }
}

function Assert-FinalSchedule {
    param(
        [Parameter(Mandatory = $true)][object] $Schedule,
        [Parameter(Mandatory = $true)][DateTimeOffset] $Now
    )

    if ([string]$Schedule.ownerKey -cnotmatch '^[a-z0-9][a-z0-9.-]{0,63}$' -or
        [string]$Schedule.dataClassKey -cnotmatch '^[a-z0-9][a-z0-9.-]{0,63}$' -or
        [int]$Schedule.targetScopeKind -notin @(1, 2) -or
        ([int]$Schedule.targetScopeKind -eq 1 -and $null -ne $Schedule.propertyId) -or
        ([int]$Schedule.targetScopeKind -eq 2 -and
            ($null -eq $Schedule.propertyId -or [Guid]$Schedule.propertyId -eq [Guid]::Empty)) -or
        [int]$Schedule.executionPolicyVersion -lt 1 -or
        [int]$Schedule.status -ne 3 -or
        $null -eq $Schedule.lastRunId -or [Guid]$Schedule.lastRunId -eq [Guid]::Empty -or
        $null -eq $Schedule.lastStartedAtUtc -or
        $null -eq $Schedule.lastCompletedAtUtc -or
        [DateTimeOffset]$Schedule.lastCompletedAtUtc -lt
            [DateTimeOffset]$Schedule.lastStartedAtUtc -or
        [DateTimeOffset]$Schedule.nextDueAtUtc -le
            [DateTimeOffset]$Schedule.lastCompletedAtUtc -or
        [bool]$Schedule.overdue -or
        [int]$Schedule.consecutiveFailures -ne 0 -or
        $null -eq $Schedule.lastScannedCount -or [int]$Schedule.lastScannedCount -lt 0 -or
        $null -eq $Schedule.lastAffectedCount -or [int]$Schedule.lastAffectedCount -lt 0 -or
        [int]$Schedule.lastAffectedCount -gt [int]$Schedule.lastScannedCount -or
        $null -eq $Schedule.lastRemainingCount -or [int]$Schedule.lastRemainingCount -lt 0 -or
        [string]$Schedule.outcomeCode -cnotmatch '^[a-z0-9][a-z0-9.-]{0,99}$' -or
        $null -ne $Schedule.holdReviewDueAtUtc -or
        [DateTimeOffset]$Schedule.nextDueAtUtc -lt $Now.AddSeconds(-$ClockSkewSeconds)) {
        throw "Retention schedule '$(Get-ScheduleCoordinate -Schedule $Schedule)' is not terminal, current, and PII-minimized."
    }
}

function Assert-FinalSnapshot {
    param([Parameter(Mandatory = $true)][object] $Snapshot)

    $now = [DateTimeOffset]::UtcNow
    foreach ($schedule in $Snapshot.Items) {
        Assert-FinalSchedule -Schedule $schedule -Now $now
    }
    if ([int]$Snapshot.Summary.total -ne $Snapshot.Items.Count -or
        [int]$Snapshot.Summary.healthy -ne $Snapshot.Items.Count -or
        [int]$Snapshot.Summary.running -ne 0 -or
        [int]$Snapshot.Summary.needsAttention -ne 0) {
        throw 'Retention health summary is not fully healthy and internally consistent.'
    }

    foreach ($expected in $expectedSchedules) {
        $schedule = Get-ExpectedSchedule -Snapshot $Snapshot -Expected $expected
        if ([string]$schedule.outcomeCode -cne [string]$expected.OutcomeCode -or
            [int]$schedule.lastRemainingCount -ne 0 -or
            [DateTimeOffset]$schedule.lastCompletedAtUtc -lt
                $now.Subtract([TimeSpan]$expected.MaximumCompletionAge)) {
            throw "Expected Retention schedule '$($expected.DataClassKey)' is stale or did not converge without backlog."
        }
    }
}

try {
    $releaseIdBefore = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds
    $baseline = Get-SmokeRetentionSnapshot
    Assert-ExpectedCatalogue -Snapshot $baseline
    [void]$checks.Add([ordered]@{
            name = 'retention-catalogue-present'
            status = 'passed'
        })

    $wrongWorkspaceId = [Guid]::NewGuid()
    while ($wrongWorkspaceId -eq $WorkspaceId) {
        $wrongWorkspaceId = [Guid]::NewGuid()
    }
    Assert-BunkFyAuthenticatedStatus `
        -Response (Invoke-SmokeApi -TenantId $wrongWorkspaceId) `
        -ExpectedStatus 403 `
        -Operation 'Reject cross-workspace Retention schedules'
    [void]$checks.Add([ordered]@{
            name = 'cross-workspace-retention-denied'
            status = 'passed'
        })

    $baselineObserved = Get-ExpectedSchedule `
        -Snapshot $baseline `
        -Expected $observedSchedule
    $baselineRunId = if ($null -eq $baselineObserved.lastRunId) {
        [Guid]::Empty
    }
    else {
        [Guid]$baselineObserved.lastRunId
    }
    $baselineWasRunning = [int]$baselineObserved.status -eq 2
    $baselineCapturedAt = [DateTimeOffset]::UtcNow
    $deadline = $baselineCapturedAt.AddSeconds($CycleTimeoutSeconds)
    Write-Host 'Waiting for the deployed Retention scheduler to complete the next raw-source-evidence occurrence...'
    if (-not $baselineWasRunning) {
        $wakeAt = ([DateTimeOffset]$baselineObserved.nextDueAtUtc).AddSeconds(
            -$ClockSkewSeconds)
        if ($wakeAt -ge $deadline) {
            throw 'The next raw-source-evidence occurrence is outside the configured cycle timeout.'
        }
        $initialDelay = $wakeAt - [DateTimeOffset]::UtcNow
        if ($initialDelay -gt [TimeSpan]::Zero) {
            Start-Sleep -Milliseconds ([int][Math]::Floor($initialDelay.TotalMilliseconds))
        }
    }
    do {
        $candidate = Get-SmokeRetentionSnapshot
        Assert-ExpectedCatalogue -Snapshot $candidate
        $candidateObserved = Get-ExpectedSchedule `
            -Snapshot $candidate `
            -Expected $observedSchedule
        $candidateRunId = if ($null -eq $candidateObserved.lastRunId) {
            [Guid]::Empty
        }
        else {
            [Guid]$candidateObserved.lastRunId
        }
        $eligibleIdentity = $candidateRunId -ne [Guid]::Empty -and (
            $candidateRunId -ne $baselineRunId -or
            ($baselineWasRunning -and $candidateRunId -eq $baselineRunId))
        if ($eligibleIdentity -and [int]$candidateObserved.status -in @(4, 5)) {
            throw 'The observed Retention occurrence completed blocked or failed.'
        }
        if ($eligibleIdentity -and
            [int]$candidateObserved.status -eq 3 -and
            $null -ne $candidateObserved.lastCompletedAtUtc -and
            [DateTimeOffset]$candidateObserved.lastCompletedAtUtc -ge
                $baselineCapturedAt.AddSeconds(-$ClockSkewSeconds)) {
            $finalSnapshot = $candidate
            break
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    if ($null -eq $finalSnapshot) {
        throw 'No new terminal raw-source-evidence Retention occurrence was observed before the timeout.'
    }
    [void]$checks.Add([ordered]@{
            name = 'automatic-retention-occurrence-observed'
            status = 'passed'
        })

    Assert-FinalSnapshot -Snapshot $finalSnapshot
    [void]$checks.Add([ordered]@{
            name = 'retention-schedules-terminal-and-current'
            status = 'passed'
        })
    [void]$checks.Add([ordered]@{
            name = 'retention-summary-consistent'
            status = 'passed'
        })
    [void]$checks.Add([ordered]@{
            name = 'retention-outcomes-pii-minimized'
            status = 'passed'
        })
    $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds
    if ($observedReleaseId -cne $releaseIdBefore) {
        throw 'The public API release identity changed during Retention verification.'
    }
    [void]$checks.Add([ordered]@{
            name = 'release-identity-continuous'
            status = 'passed'
        })
}
finally {
    $client.Dispose()
    $readerToken = $null
}

$expectedEvidence = foreach ($expected in $expectedSchedules) {
    $schedule = Get-ExpectedSchedule -Snapshot $finalSnapshot -Expected $expected
    [ordered]@{
        ownerKey = [string]$schedule.ownerKey
        dataClassKey = [string]$schedule.dataClassKey
        executionPolicyVersion = [int]$schedule.executionPolicyVersion
        lastRunId = ([Guid]$schedule.lastRunId).ToString('D')
        lastStartedAtUtc = ([DateTimeOffset]$schedule.lastStartedAtUtc).ToString('O')
        lastCompletedAtUtc = ([DateTimeOffset]$schedule.lastCompletedAtUtc).ToString('O')
        nextDueAtUtc = ([DateTimeOffset]$schedule.nextDueAtUtc).ToString('O')
        scannedCount = [int]$schedule.lastScannedCount
        affectedCount = [int]$schedule.lastAffectedCount
        remainingCount = [int]$schedule.lastRemainingCount
        outcomeCode = [string]$schedule.outcomeCode
    }
}
$evidence = [ordered]@{
    schemaVersion = 1
    evidenceKind = 'bunkfy-deployed-retention-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    publicOrigin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-fixture' }
    result = 'passed'
    workspaceId = $WorkspaceId.ToString('D')
    observedDataClassKey = [string]$observedSchedule.DataClassKey
    catalogueCount = [int]$finalSnapshot.Summary.total
    schedules = @($expectedEvidence)
    checks = @($checks)
    limitations = @(
        'owner-data-not-seeded-or-read',
        'generic-task-lease-and-restart-not-observed',
        'legal-hold-and-admin-retry-not-exercised',
        'private-maintenance-owner-topology-and-alerting-not-observed'
    )
}

$parent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $parent -Force)
}
$temporaryPath = "$OutputPath.$([Guid]::NewGuid().ToString('N')).tmp"
try {
    $json = $evidence | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText(
        $temporaryPath,
        ($json.Replace("`r`n", "`n") + "`n"),
        [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $OutputPath -Force:$Force
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

Write-Host "BunkFy deployed Retention passed $($checks.Count) checks."
Write-Host "Evidence: $OutputPath"
