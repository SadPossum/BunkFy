[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][string] $EnvironmentPath,
    [string] $ComposePath,
    [string] $OperatorComposePath,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [ValidateRange(30, 600)][int] $ConvergenceTimeoutSeconds = 180,
    [ValidateRange(500, 5000)][int] $PollIntervalMilliseconds = 2000,
    [ValidateRange(300, 3600)][int] $ProcessTimeoutSeconds = 1800,
    [string] $OutputPath,
    [switch] $AllowLoopbackHttp,
    [switch] $SkipWorkerRestart,
    [switch] $IncludeCustomProfileAdministration,
    [switch] $Headed,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '../common.ps1')
. (Join-Path $PSScriptRoot 'local-sensitive-state.common.ps1')
. (Join-Path $PSScriptRoot 'deployed-public-edge.common.ps1')
. (Join-Path $PSScriptRoot 'preview-state.common.ps1')

$root = Get-BunkFyRepositoryRoot
$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackHttp
if ([string]::IsNullOrWhiteSpace($ComposePath)) {
    $ComposePath = Join-BunkFyPath 'deploy/preview/compose.yaml'
}
if ([string]::IsNullOrWhiteSpace($OperatorComposePath)) {
    $OperatorComposePath = Join-BunkFyPath 'deploy/preview/compose.mailpit-operator.yaml'
}
$ComposePath = [IO.Path]::GetFullPath($ComposePath)
$OperatorComposePath = [IO.Path]::GetFullPath($OperatorComposePath)
$EnvironmentPath = [IO.Path]::GetFullPath($EnvironmentPath)
foreach ($path in @($ComposePath, $OperatorComposePath, $EnvironmentPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required browser rehearsal file '$path' does not exist."
    }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Required browser rehearsal file '$path' must not be a reparse point."
    }
}
Assert-BunkFyLocalSensitivePath `
    -Path $EnvironmentPath `
    -PathType Leaf `
    -Description 'Preview environment'

$composeDefinition = Get-BunkFyPreviewComposeDefinition `
    -Root $root `
    -ComposePath $ComposePath `
    -EnvironmentPath $EnvironmentPath
$composeProjectName = [string]$composeDefinition.name
if ($composeProjectName -cne 'bunkfy-preview' -or
    $null -eq $composeDefinition.services.PSObject.Properties['worker'] -or
    $null -eq $composeDefinition.services.PSObject.Properties['mailpit']) {
    throw 'Browser rehearsal requires the exact bunkfy-preview Worker and Mailpit topology.'
}
$mailpitPorts = $composeDefinition.services.mailpit.PSObject.Properties['ports']
if ($null -ne $mailpitPorts -and
    $null -ne $mailpitPorts.Value -and
    @($mailpitPorts.Value).Count -gt 0) {
    throw 'Base Preview Compose publishes a Mailpit host port.'
}

$driverPath = Join-Path $PSScriptRoot 'rehearse-preview-browser-onboarding.mjs'
$webPath = Join-Path (Join-Path $root 'apps') 'web'
$playwrightPath = Join-Path $webPath 'node_modules/@playwright/test'
if (-not (Test-Path -LiteralPath $driverPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $playwrightPath -PathType Container)) {
    throw 'Install the pinned web dependencies and Chromium before the browser rehearsal.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/preview-browser-onboarding-$stamp.json"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $OutputPath
if (Test-Path -LiteralPath $OutputPath) {
    $item = Get-Item -LiteralPath $OutputPath -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The evidence path is not a regular file: '$OutputPath'."
    }
    if (-not $Force) {
        throw "The evidence file already exists: '$OutputPath'. Use -Force to replace it."
    }
}

if (-not $PSCmdlet.ShouldProcess(
        $origin.GetLeftPart([UriPartial]::Authority),
        'exercise browser invitation and Team QR onboarding with a guarded Worker restart')) {
    return
}

if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-BunkFyLocalSensitiveDirectory `
        -Path $outputDirectory `
        -Description 'Preview browser rehearsal evidence directory'
}
else {
    Protect-BunkFyLocalSensitivePath `
        -Path $outputDirectory `
        -PathType Container `
        -Description 'Preview browser rehearsal evidence directory'
}
$nodeResultPath = Join-Path $outputDirectory (
    ".preview-browser-node-$([Guid]::NewGuid().ToString('N')).json")

$mailpitWindowOpened = $false
$mailpitOrigin = $null
$childExitCode = -1
$childTimedOut = $false
$parentCleanupFailures = [Collections.Generic.List[string]]::new()
$parentWorkerStatus = if ($SkipWorkerRestart) { 'not-requested' } else { 'not-checked' }
$parentMailpitStatus = 'not-opened'

function Invoke-BrowserRehearsalCompose {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Operation,
        [switch] $OperatorWindow
    )

    $dockerArguments = @(
        'compose',
        '--env-file', $EnvironmentPath,
        '-f', $ComposePath)
    if ($OperatorWindow) {
        $dockerArguments += @('-f', $OperatorComposePath)
    }
    $dockerArguments += $Arguments
    Push-Location -LiteralPath $root
    try {
        $output = @(& docker @dockerArguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exitCode -ne 0) {
        throw "$Operation failed with exit code $exitCode."
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Wait-BrowserRehearsalServiceHealthy {
    param([Parameter(Mandatory = $true)][ValidateSet('mailpit', 'worker')][string] $Service)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        try {
            if ($Service -eq 'mailpit') {
                [void](Invoke-BrowserRehearsalCompose `
                        -Arguments @('exec', '-T', 'mailpit', '/mailpit', 'readyz') `
                        -Operation 'Mailpit readiness check' `
                        -OperatorWindow:$mailpitWindowOpened)
                return
            }
            $containerIds = @(
                @(Invoke-BrowserRehearsalCompose `
                        -Arguments @('ps', '--status', 'running', '--quiet', 'worker') `
                        -Operation 'Resolve running Preview Worker') |
                    Where-Object { $_ -match '^[0-9a-f]{12,64}$' }
            )
            if ($containerIds.Count -eq 1) {
                $containerId = [string]($containerIds | Select-Object -First 1)
                $health = @(& docker inspect `
                        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' `
                        $containerId 2>&1)
                if ($LASTEXITCODE -eq 0 -and $health.Count -eq 1) {
                    $verifiedState = [string]($health | Select-Object -First 1)
                    # Docker reports Health.Status when a healthcheck exists and
                    # falls back to State.Status for the background Worker.
                    if ($verifiedState -cin @('healthy', 'running')) {
                        return $verifiedState
                    }
                }
            }
        }
        catch {
            # Readiness is retried until the bounded deadline.
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "$Service did not become healthy before the timeout."
}

function Open-BrowserRehearsalMailpit {
    $script:mailpitWindowOpened = $true
    [void](Invoke-BrowserRehearsalCompose `
            -Arguments @('up', '--detach', '--no-deps', '--no-build', '--force-recreate', 'mailpit') `
            -Operation 'Open loopback Mailpit operator window' `
            -OperatorWindow)
    Wait-BrowserRehearsalServiceHealthy -Service mailpit
    $containerIds = @(
        @(Invoke-BrowserRehearsalCompose `
                -Arguments @('ps', '--quiet', 'mailpit') `
                -Operation 'Resolve operator Mailpit container' `
                -OperatorWindow) |
            Where-Object { $_ -match '^[0-9a-f]{12,64}$' }
    )
    if ($containerIds.Count -ne 1) {
        throw 'Unable to resolve exactly one operator Mailpit container.'
    }
    $containerId = [string]($containerIds | Select-Object -First 1)
    $published = @(
        @(& docker port $containerId '8025/tcp' 2>&1) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    $publishedEndpoint = [string]($published | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or
        $published.Count -ne 1 -or
        $publishedEndpoint -notmatch '^127[.]0[.]0[.]1:(?<port>[0-9]{1,5})$') {
        throw 'Mailpit operator access is not bound to exactly one IPv4 loopback port.'
    }
    $port = [int]$Matches['port']
    if ($port -lt 1 -or $port -gt 65535) {
        throw 'Mailpit operator port is invalid.'
    }
    return [Uri]::new("http://127.0.0.1:$port/")
}

function Close-BrowserRehearsalMailpit {
    [void](Invoke-BrowserRehearsalCompose `
            -Arguments @('up', '--detach', '--no-deps', '--no-build', '--force-recreate', 'mailpit') `
            -Operation 'Close and purge Mailpit operator window')
    $script:mailpitWindowOpened = $false
    Wait-BrowserRehearsalServiceHealthy -Service mailpit
    $containerIds = @(
        @(Invoke-BrowserRehearsalCompose `
                -Arguments @('ps', '--quiet', 'mailpit') `
                -Operation 'Resolve private Mailpit container') |
            Where-Object { $_ -match '^[0-9a-f]{12,64}$' }
    )
    if ($containerIds.Count -ne 1) {
        throw 'Unable to resolve exactly one private Mailpit container.'
    }
    $containerId = [string]($containerIds | Select-Object -First 1)
    $published = @(
        @(& docker port $containerId 2>&1) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    if ($LASTEXITCODE -ne 0 -or $published.Count -ne 0) {
        throw 'Mailpit still has a published host port after cleanup.'
    }

    $networkIds = @(
        @(& docker network ls `
                --quiet `
                --filter "label=com.docker.compose.project=$composeProjectName" `
                --filter 'label=com.docker.compose.network=mailpit-operator' 2>&1) |
            Where-Object { $_ -match '^[0-9a-f]{12,64}$' }
    )
    if ($LASTEXITCODE -ne 0 -or $networkIds.Count -gt 1) {
        throw 'Unable to resolve the temporary Mailpit operator network.'
    }
    if ($networkIds.Count -eq 1) {
        $networkId = [string]($networkIds | Select-Object -First 1)
        $attachments = @(& docker network inspect `
                $networkId `
                --format '{{json .Containers}}' 2>&1)
        if ($LASTEXITCODE -ne 0 -or $attachments.Count -ne 1) {
            throw 'Unable to inspect the temporary Mailpit operator network.'
        }
        $containers = ($attachments | Select-Object -First 1) | ConvertFrom-Json
        if (@($containers.PSObject.Properties).Count -ne 0) {
            throw 'The temporary Mailpit operator network still has attached containers.'
        }
        [void](& docker network rm $networkId 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to remove the temporary Mailpit operator network.'
        }
    }
}

function Restore-BrowserRehearsalWorker {
    [void](Invoke-BrowserRehearsalCompose `
            -Arguments @('up', '--detach', '--no-deps', '--no-build', 'worker') `
            -Operation 'Restore Preview Worker')
    return Wait-BrowserRehearsalServiceHealthy -Service worker
}

try {
    $mailpitOrigin = Open-BrowserRehearsalMailpit
    $parentMailpitStatus = 'open-loopback-only'

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'node'
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add($driverPath)
    $startInfo.Environment['BUNKFY_BROWSER_PUBLIC_ORIGIN'] = $origin.AbsoluteUri
    $startInfo.Environment['BUNKFY_BROWSER_EXPECTED_RELEASE_ID'] = $ExpectedReleaseId
    $startInfo.Environment['BUNKFY_BROWSER_MAILPIT_ORIGIN'] = $mailpitOrigin.AbsoluteUri
    $startInfo.Environment['BUNKFY_BROWSER_COMPOSE_PATH'] = $ComposePath
    $startInfo.Environment['BUNKFY_BROWSER_ENVIRONMENT_PATH'] = $EnvironmentPath
    $startInfo.Environment['BUNKFY_BROWSER_COMPOSE_PROJECT_NAME'] = $composeProjectName
    $startInfo.Environment['BUNKFY_BROWSER_RESULT_PATH'] = $nodeResultPath
    $startInfo.Environment['BUNKFY_BROWSER_FORCE'] = 'true'
    $startInfo.Environment['BUNKFY_BROWSER_HEADLESS'] = if ($Headed) { 'false' } else { 'true' }
    $startInfo.Environment['BUNKFY_BROWSER_EXERCISE_WORKER_RESTART'] = if ($SkipWorkerRestart) { 'false' } else { 'true' }
    $startInfo.Environment['BUNKFY_BROWSER_INCLUDE_CUSTOM_PROFILE_ADMINISTRATION'] = if ($IncludeCustomProfileAdministration) { 'true' } else { 'false' }
    $startInfo.Environment['BUNKFY_BROWSER_ALLOW_LOOPBACK_HTTP'] = if ($AllowLoopbackHttp) { 'true' } else { 'false' }
    $startInfo.Environment['BUNKFY_BROWSER_REQUEST_TIMEOUT_MS'] = [string]($RequestTimeoutSeconds * 1000)
    $startInfo.Environment['BUNKFY_BROWSER_CONVERGENCE_TIMEOUT_MS'] = [string]($ConvergenceTimeoutSeconds * 1000)
    $startInfo.Environment['BUNKFY_BROWSER_POLL_INTERVAL_MS'] = [string]$PollIntervalMilliseconds

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Unable to start the Preview browser rehearsal process.'
    }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($ProcessTimeoutSeconds * 1000)) {
        $childTimedOut = $true
        $process.Kill($true)
        $process.WaitForExit()
    }
    $childExitCode = if ($childTimedOut) { -1 } else { $process.ExitCode }
    [void]$stdout.GetAwaiter().GetResult()
    [void]$stderr.GetAwaiter().GetResult()
    $stdout = $null
    $stderr = $null
    $process.Dispose()
}
catch {
    $childExitCode = -1
}
finally {
    if (-not $SkipWorkerRestart) {
        try {
            $verifiedWorkerState = Restore-BrowserRehearsalWorker
            $parentWorkerStatus = "restored-$verifiedWorkerState-parent-verified"
        }
        catch {
            $parentWorkerStatus = 'failed'
            $parentCleanupFailures.Add('worker-restoration')
        }
    }
    if ($mailpitWindowOpened) {
        try {
            Close-BrowserRehearsalMailpit
            $parentMailpitStatus = 'purged-and-loopback-closed'
        }
        catch {
            $parentMailpitStatus = 'failed'
            $parentCleanupFailures.Add('captured-mail')
        }
    }
    $mailpitOrigin = $null
}

$evidence = $null
if (Test-Path -LiteralPath $nodeResultPath -PathType Leaf) {
    try {
        $evidence = Get-Content -LiteralPath $nodeResultPath -Raw |
            ConvertFrom-Json -Depth 20
        if ([int]$evidence.schemaVersion -ne 1 -or
            [string]$evidence.evidenceKind -cne 'bunkfy-preview-browser-onboarding-rehearsal' -or
            [string]$evidence.origin -cne $origin.GetLeftPart([UriPartial]::Authority) -or
            [string]$evidence.releaseId -cne $ExpectedReleaseId) {
            throw 'The browser process returned evidence outside the parent contract.'
        }
    }
    catch {
        $evidence = $null
    }
}
Remove-Item -LiteralPath $nodeResultPath -Force -ErrorAction SilentlyContinue

if ($null -eq $evidence) {
    $evidence = [pscustomobject][ordered]@{
        schemaVersion = 1
        evidenceKind = 'bunkfy-preview-browser-onboarding-rehearsal'
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        origin = $origin.GetLeftPart([UriPartial]::Authority)
        releaseId = $ExpectedReleaseId
        transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-preview' }
        result = 'proof-failed'
        failure = [pscustomobject][ordered]@{
            code = if ($childTimedOut) { 'BrowserProcess.Timeout' } else { 'BrowserProcess.NoResult' }
            stage = 'browser-process'
        }
        registrationAdapters = @()
        workspaceAccessAdministration = [pscustomobject]@{
            requested = [bool]$IncludeCustomProfileAdministration
            result = if ($IncludeCustomProfileAdministration) { 'browser-process-failed' } else { 'not-requested' }
        }
        browser = [pscustomobject]@{ automaticArtifacts = 'disabled' }
        identities = @()
        identifiers = [pscustomobject]@{}
        cleanup = [pscustomobject]@{}
        cleanupFailures = @()
        checks = @()
        limitations = @(
            'browser-process-did-not-return-a-complete-scrubbed-record')
    }
}

$workspaceAccessAdministration = $evidence.PSObject.Properties['workspaceAccessAdministration']
if ($null -eq $workspaceAccessAdministration -or
    [bool]$workspaceAccessAdministration.Value.requested -ne [bool]$IncludeCustomProfileAdministration -or
    ($IncludeCustomProfileAdministration -and
        [string]$evidence.result -ceq 'passed' -and
        [string]$workspaceAccessAdministration.Value.result -cne 'passed')) {
    $evidence.result = 'proof-failed'
    $evidence.failure = [pscustomobject][ordered]@{
        code = 'BrowserProcess.WorkspaceAccessContractMismatch'
        stage = 'browser-process'
    }
}

$evidence.cleanup | Add-Member `
    -NotePropertyName worker `
    -NotePropertyValue $parentWorkerStatus `
    -Force
$evidence.cleanup | Add-Member `
    -NotePropertyName capturedMail `
    -NotePropertyValue $parentMailpitStatus `
    -Force
$allCleanupFailures = @(
    @($evidence.cleanupFailures) +
    @($parentCleanupFailures) |
        Sort-Object -Unique)
$evidence.cleanupFailures = $allCleanupFailures
$checks = @($evidence.checks)
$checks += [pscustomobject][ordered]@{
    name = 'parent-operator-cleanup-complete'
    status = if ($parentCleanupFailures.Count -eq 0) { 'passed' } else { 'failed' }
}
$evidence.checks = $checks
$evidence | Add-Member `
    -NotePropertyName finalizedAtUtc `
    -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('O')) `
    -Force
if ($childExitCode -ne 0 -and [string]$evidence.result -ceq 'passed') {
    $evidence.result = 'proof-failed'
    $evidence.failure = [pscustomobject][ordered]@{
        code = if ($childTimedOut) { 'BrowserProcess.Timeout' } else { 'BrowserProcess.NonZeroExit' }
        stage = 'browser-process'
    }
}
elseif ($parentCleanupFailures.Count -gt 0 -and [string]$evidence.result -ceq 'passed') {
    $evidence.result = 'proof-passed-cleanup-partial'
}

$json = $evidence | ConvertTo-Json -Depth 20
Write-BunkFyLocalSensitiveTextFile `
    -Path $OutputPath `
    -Content ($json.Replace("`r`n", "`n") + "`n") `
    -Overwrite:$Force `
    -Description 'Preview browser onboarding evidence'

if ([string]$evidence.result -cne 'passed') {
    throw "Preview browser onboarding rehearsal did not pass cleanly. Review '$OutputPath'."
}

Write-Host "BunkFy Preview browser onboarding rehearsal passed $(@($evidence.checks).Count) checks."
Write-Host "Evidence: $OutputPath"
