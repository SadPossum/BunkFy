[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][Guid] $WorkspaceId,
    [Parameter(Mandatory = $true)][Guid] $PropertyId,
    [Parameter(Mandatory = $true)][Guid] $InventoryUnitId,
    [Parameter(Mandatory = $true)][string] $BackendImage,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $BackendSourceCommitSha,
    [Security.SecureString] $OperatorAccessToken,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [ValidateRange(120, 900)][int] $CycleTimeoutSeconds = 300,
    [ValidateRange(30, 300)][int] $ConvergenceTimeoutSeconds = 120,
    [ValidateRange(500, 5000)][int] $PollIntervalMilliseconds = 2000,
    [string] $UpsertEvidencePath,
    [string] $CancellationEvidencePath,
    [switch] $AllowLoopbackPublicHttp,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'deployed-public-edge.common.ps1')
. (Join-Path $PSScriptRoot 'deployed-authenticated-smoke.common.ps1')

$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackPublicHttp
$imagePattern =
    '^[a-z0-9]+(?:[._-][a-z0-9]+)*(?::[0-9]+)?(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+@(?<digest>sha256:[0-9a-f]{64})$'
$imageMatch = [Text.RegularExpressions.Regex]::Match(
    $BackendImage,
    $imagePattern,
    [Text.RegularExpressions.RegexOptions]::CultureInvariant)
if (-not $imageMatch.Success) {
    throw 'BackendImage must be an exact lowercase repository@sha256:<digest> reference.'
}
$imageDigest = $imageMatch.Groups['digest'].Value
foreach ($identity in ([ordered]@{
        WorkspaceId = $WorkspaceId
        PropertyId = $PropertyId
        InventoryUnitId = $InventoryUnitId
    }).GetEnumerator()) {
    if ([Guid]$identity.Value -eq [Guid]::Empty) {
        throw "$($identity.Key) must not be an empty GUID."
    }
}

$stamp = [DateTimeOffset]::UtcNow.ToString(
    'yyyyMMddTHHmmssZ',
    [Globalization.CultureInfo]::InvariantCulture)
if ([string]::IsNullOrWhiteSpace($UpsertEvidencePath)) {
    $UpsertEvidencePath = Join-BunkFyPath ".tmp/deployment-probes/preview-adapter-host-$stamp.upsert.json"
}
if ([string]::IsNullOrWhiteSpace($CancellationEvidencePath)) {
    $CancellationEvidencePath = Join-BunkFyPath ".tmp/deployment-probes/preview-adapter-host-$stamp.cancellation.json"
}
$UpsertEvidencePath = [IO.Path]::GetFullPath($UpsertEvidencePath)
$CancellationEvidencePath = [IO.Path]::GetFullPath($CancellationEvidencePath)
if ($UpsertEvidencePath -ceq $CancellationEvidencePath) {
    throw 'Upsert and cancellation evidence paths must be distinct.'
}

function Assert-AdapterEvidenceOutputAvailable {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The AdapterHost evidence path is not a regular file: '$Path'."
    }
    if (-not $Force) {
        throw "The AdapterHost evidence file already exists: '$Path'. Use -Force to replace it."
    }
}

Assert-AdapterEvidenceOutputAvailable -Path $UpsertEvidencePath
Assert-AdapterEvidenceOutputAvailable -Path $CancellationEvidencePath

$operatorToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $OperatorAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_INGESTION_OPERATOR_TOKEN' `
    -Prompt 'Preview AdapterHost operator access token'
if ([string]::IsNullOrWhiteSpace($operatorToken)) {
    throw 'The Preview AdapterHost operator access token is required.'
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
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Preview-AdapterHost-Rehearsal/1')

$batchId = [Guid]::NewGuid().ToString('N')
$connectionId = [Guid]::Empty
$credentialId = [Guid]::Empty
$workerId = [Guid]::NewGuid()
$issuedToken = $null
$containerName = "bunkfy-preview-adapter-$($batchId.Substring(0, 12))"
$materialVolume = "$containerName-material"
$fileDropVolume = "$containerName-file-drop"
$containerCreated = $false
$materialVolumeCreated = $false
$fileDropVolumeCreated = $false
$proofError = $null
$cleanupFailures = [Collections.Generic.List[string]]::new()

function Invoke-AdapterRehearsalApi {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^/api/')][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string] $Method,
        [AllowNull()][object] $Body
    )

    return Invoke-BunkFyAuthenticatedJsonRequest `
        -Client $client `
        -Origin $origin `
        -Path $Path `
        -Method $Method `
        -TenantId $WorkspaceId.ToString('D') `
        -AccessToken $operatorToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body $Body
}

function Read-AdapterRehearsalJson {
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

function Invoke-AdapterDocker {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    $output = @(& docker @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed."
    }
    return $output
}

function Invoke-AdapterDockerWithInput {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $InputText,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command docker -ErrorAction Stop).Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "$Operation could not start Docker."
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            throw "$Operation exceeded its 60-second timeout."
        }
        $stdout.GetAwaiter().GetResult() | Out-Null
        $stderr.GetAwaiter().GetResult() | Out-Null
        if ($process.ExitCode -ne 0) {
            throw "$Operation failed."
        }
    }
    finally {
        $process.Dispose()
    }
}

function Initialize-AdapterVolume {
    param([Parameter(Mandatory = $true)][string] $Name)

    [void](Invoke-AdapterDocker `
            -Arguments @(
                'volume', 'create',
                '--label', 'bunkfy.preview.adapter-host=true',
                '--label', "bunkfy.preview.release-id=$ExpectedReleaseId",
                $Name) `
            -Operation "Create AdapterHost volume '$Name'")
    if ($Name -ceq $materialVolume) {
        $script:materialVolumeCreated = $true
    }
    elseif ($Name -ceq $fileDropVolume) {
        $script:fileDropVolumeCreated = $true
    }
    [void](Invoke-AdapterDocker `
            -Arguments @(
                'run', '--rm',
                '--network', 'none',
                '--read-only',
                '--user', '0:0',
                '--cap-drop', 'ALL',
                '--cap-add', 'CHOWN',
                '--security-opt', 'no-new-privileges:true',
                '--pids-limit', '32',
                '--volume', "${Name}:/volume",
                '--entrypoint', 'chown',
                $BackendImage,
                '1654:1654', '/volume') `
            -Operation "Initialize AdapterHost volume '$Name'")
}

function Write-AdapterMaterialFile {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9.-]+$')][string] $Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Content
    )

    Invoke-AdapterDockerWithInput `
        -Arguments @(
            'run', '--rm', '--interactive',
            '--network', 'none',
            '--read-only',
            '--user', '1654:1654',
            '--cap-drop', 'ALL',
            '--security-opt', 'no-new-privileges:true',
            '--pids-limit', '32',
            '--volume', "${materialVolume}:/material",
            '--entrypoint', '/bin/sh',
            $BackendImage,
            '-c', "umask 077; cat > /material/$Name") `
        -InputText $Content `
        -Operation "Write AdapterHost material '$Name'"
}

function Write-AdapterProviderRecord {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]{3}-[0-9a-f]{32}\.json$')][string] $Name,
        [Parameter(Mandatory = $true)][string] $Envelope
    )

    $connectionDirectory = $connectionId.ToString('N')
    Invoke-AdapterDockerWithInput `
        -Arguments @(
            'run', '--rm', '--interactive',
            '--network', 'none',
            '--read-only',
            '--user', '1654:1654',
            '--cap-drop', 'ALL',
            '--security-opt', 'no-new-privileges:true',
            '--pids-limit', '32',
            '--volume', "${fileDropVolume}:/drop",
            '--entrypoint', '/bin/sh',
            $BackendImage,
            '-c', "umask 077; mkdir -p /drop/$connectionDirectory/pending; cat > /drop/$connectionDirectory/pending/$Name") `
        -InputText $Envelope `
        -Operation 'Seed the synthetic AdapterHost provider record'
}

function Wait-AdapterHostReady {
    param([Parameter(Mandatory = $true)][Uri] $AdapterHostOrigin)

    $healthHandler = [Net.Http.HttpClientHandler]::new()
    $healthHandler.AllowAutoRedirect = $false
    $healthHandler.UseCookies = $false
    $healthClient = [Net.Http.HttpClient]::new($healthHandler, $true)
    $healthClient.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    try {
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
        do {
            $request = [Net.Http.HttpRequestMessage]::new(
                [Net.Http.HttpMethod]::Get,
                [Uri]::new($AdapterHostOrigin, '/health/ready'))
            $cancellation = [Threading.CancellationTokenSource]::new(
                [TimeSpan]::FromSeconds($RequestTimeoutSeconds))
            try {
                $response = $healthClient.SendAsync(
                    $request,
                    [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                    $cancellation.Token).GetAwaiter().GetResult()
                try {
                    if ([int]$response.StatusCode -eq 200) {
                        return
                    }
                }
                finally {
                    $response.Dispose()
                }
            }
            catch [Net.Http.HttpRequestException] {
                # The container may still be starting.
            }
            catch [OperationCanceledException] {
                # The bounded outer readiness deadline remains authoritative.
            }
            finally {
                $cancellation.Dispose()
                $request.Dispose()
            }
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
    }
    finally {
        $healthClient.Dispose()
    }

    throw 'The connection-scoped AdapterHost did not become ready before the timeout.'
}

function Start-AdapterHostContainer {
    $serviceBaseAddress = $origin.AbsoluteUri
    if (-not $serviceBaseAddress.EndsWith('/')) {
        $serviceBaseAddress += '/'
    }
    $approvalRelease = $ExpectedReleaseId
    if ($approvalRelease.Length -gt 80) {
        $approvalRelease = $approvalRelease.Substring(0, 80)
    }
    $approvalReference =
        "preview-adapter-host/$approvalRelease/$($batchId.Substring(0, 12))"
    $environment = [ordered]@{
        DOTNET_ENVIRONMENT = 'Production'
        AdapterHost__AdapterType = 'json.file-drop'
        AdapterHost__TenantId = $WorkspaceId.ToString('D')
        AdapterHost__PropertyId = $PropertyId.ToString('D')
        AdapterHost__ConnectionId = $connectionId.ToString('D')
        AdapterHost__CoordinationMode = 'server-lease'
        AdapterHost__WorkerId = $workerId.ToString('D')
        AdapterHost__ServiceBaseAddress = $serviceBaseAddress
        AdapterHost__ConfigurationFilePath = '/run/bunkfy-adapter/configuration.json'
        AdapterHost__ConfigurationContentType = 'application/json'
        AdapterHost__IngressTokenEnvironmentVariable = ''
        AdapterHost__IngressTokenFilePath = '/run/bunkfy-adapter/ingress-token'
        AdapterHost__PollInterval = '00:01:00'
        AdapterHost__MaximumRunDuration = '00:02:00'
        AdapterHost__RemoteLeaseDuration = '00:02:00'
        AdapterHost__RetryBaseDelay = '00:00:05'
        AdapterHost__RetryMaxDelay = '00:00:30'
        AdapterHost__RunOnStart = 'false'
        AdapterHost__AllowInsecureLoopback = 'false'
        AdapterHost__ListenUrl = 'http://0.0.0.0:8088'
        AdapterHost__JsonFileDropRoot = '/var/lib/bunkfy/file-drop'
        AdapterHost__ProductionAdmission__ApprovalState = 'Approved'
        AdapterHost__ProductionAdmission__ApprovalReference = $approvalReference
        AdapterHost__ProductionAdmission__DeploymentProfile = 'Hosted'
        AdapterHost__ProductionAdmission__Runtime = 'Container'
        AdapterHost__ProductionAdmission__SourceCommitSha = $BackendSourceCommitSha
        AdapterHost__ProductionAdmission__ContainerImageDigest = $imageDigest
        AdapterHost__ProductionAdmission__ApprovedAdapterType = 'json.file-drop'
        AdapterHost__ProductionAdmission__ApprovedServiceBaseAddress = $serviceBaseAddress
        AdapterHost__ProductionAdmission__StatusEndpointExposure = 'Disabled'
    }
    $arguments = @(
        'run', '--detach',
        '--name', $containerName,
        '--label', 'bunkfy.preview.adapter-host=true',
        '--label', "bunkfy.preview.release-id=$ExpectedReleaseId",
        '--label', "bunkfy.preview.connection-id=$($connectionId.ToString('D'))",
        '--read-only',
        '--init',
        '--cap-drop', 'ALL',
        '--security-opt', 'no-new-privileges:true',
        '--pids-limit', '128',
        '--memory', '512m',
        '--cpus', '1',
        '--stop-timeout', '30',
        '--log-driver', 'local',
        '--log-opt', 'max-size=5m',
        '--log-opt', 'max-file=2',
        '--tmpfs', '/tmp:rw,noexec,nosuid,nodev,size=67108864,mode=1777',
        '--publish', '127.0.0.1::8088',
        '--mount', "type=volume,source=$materialVolume,target=/run/bunkfy-adapter,readonly",
        '--mount', "type=volume,source=$fileDropVolume,target=/var/lib/bunkfy/file-drop",
        '--workdir', '/opt/bunkfy/adapter-host',
        '--entrypoint', 'dotnet')
    foreach ($entry in $environment.GetEnumerator()) {
        $arguments += @('--env', "$($entry.Key)=$($entry.Value)")
    }
    $arguments += @(
        $BackendImage,
        '/opt/bunkfy/adapter-host/BunkFy.AdapterHost.dll')

    $runOutput = @(Invoke-AdapterDocker `
            -Arguments $arguments `
            -Operation 'Start the connection-scoped AdapterHost container')
    $script:containerCreated = $true
    if (@($runOutput | Where-Object { [string]$_ -cmatch '^[0-9a-f]{64}$' }).Count -ne 1) {
        throw 'Docker did not return one AdapterHost container identifier.'
    }
    $portOutput = @(Invoke-AdapterDocker `
            -Arguments @('port', $containerName, '8088/tcp') `
            -Operation 'Resolve the AdapterHost loopback health port')
    $portLines = @($portOutput | ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($portLines.Count -ne 1 -or
        $portLines[0] -cnotmatch '^127\.0\.0\.1:(?<port>[0-9]{1,5})$') {
        throw 'AdapterHost health was not published to exactly one IPv4 loopback port.'
    }
    $port = [int]$Matches['port']
    if ($port -lt 1 -or $port -gt 65535) {
        throw 'AdapterHost health resolved an invalid loopback port.'
    }
    $adapterHostOrigin = [Uri]"http://127.0.0.1:$port"
    Wait-AdapterHostReady -AdapterHostOrigin $adapterHostOrigin
    return $adapterHostOrigin
}

function Invoke-AdapterProbeWithSeed {
    param(
        [Parameter(Mandatory = $true)][Uri] $AdapterHostOrigin,
        [Parameter(Mandatory = $true)][string] $EvidencePath,
        [Parameter(Mandatory = $true)][string] $ExternalIdSha256,
        [Parameter(Mandatory = $true)][string] $RecordFileName,
        [Parameter(Mandatory = $true)][string] $Envelope
    )

    $probePath = Join-Path $PSScriptRoot 'verify-deployed-adapter-host.ps1'
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $arguments = @(
        '-NoLogo', '-NoProfile', '-File', $probePath,
        '-PublicOrigin', $origin.GetLeftPart([UriPartial]::Authority),
        '-ExpectedReleaseId', $ExpectedReleaseId,
        '-AdapterHostOrigin', $AdapterHostOrigin.GetLeftPart([UriPartial]::Authority),
        '-WorkspaceId', $WorkspaceId.ToString('D'),
        '-PropertyId', $PropertyId.ToString('D'),
        '-ConnectionId', $connectionId.ToString('D'),
        '-ExpectedAdapterType', 'json.file-drop',
        '-ExpectedWorkerId', $workerId.ToString('D'),
        '-ExpectedExternalIdSha256', $ExternalIdSha256,
        '-ExpectedSourceRecordType', 'reservation.v1',
        '-StatusEndpointExposure', 'Disabled',
        '-RequestTimeoutSeconds', [string]$RequestTimeoutSeconds,
        '-CycleTimeoutSeconds', [string]$CycleTimeoutSeconds,
        '-ReceiptConvergenceTimeoutSeconds', [string]$ConvergenceTimeoutSeconds,
        '-PollIntervalMilliseconds', [string]$PollIntervalMilliseconds,
        '-OutputPath', $EvidencePath)
    if ($AllowLoopbackPublicHttp) {
        $arguments += '-AllowLoopbackPublicHttp'
    }
    if ($Force) {
        $arguments += '-Force'
    }
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment['BUNKFY_SMOKE_INGESTION_OPERATOR_TOKEN'] = $operatorToken

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $processStarted = $false
    try {
        if (-not $process.Start()) {
            throw 'The deployed AdapterHost probe process could not start.'
        }
        $processStarted = $true
        [void]$startInfo.Environment.Remove('BUNKFY_SMOKE_INGESTION_OPERATOR_TOKEN')
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $marker = 'Waiting for the deployed AdapterHost to ingest the synthetic source record...'
        $markerDeadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
        $markerObserved = $false
        $lineTask = $process.StandardOutput.ReadLineAsync()
        while (-not $markerObserved -and [DateTimeOffset]::UtcNow -lt $markerDeadline) {
            if ($lineTask.Wait(500)) {
                $line = $lineTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    break
                }
                if ($line -ceq $marker) {
                    $markerObserved = $true
                    break
                }
                $lineTask = $process.StandardOutput.ReadLineAsync()
            }
            elseif ($process.HasExited) {
                break
            }
        }
        if (-not $markerObserved) {
            if (-not $process.HasExited) {
                $process.Kill($true)
            }
            $process.WaitForExit()
            $stderrTask.GetAwaiter().GetResult() | Out-Null
            throw 'The deployed AdapterHost probe did not reach its provider-seeding boundary.'
        }

        Write-AdapterProviderRecord `
            -Name $RecordFileName `
            -Envelope $Envelope
        $remainingOutput = $process.StandardOutput.ReadToEndAsync()
        $maximumProcessSeconds =
            $CycleTimeoutSeconds + $ConvergenceTimeoutSeconds + 120
        if (-not $process.WaitForExit($maximumProcessSeconds * 1000)) {
            $process.Kill($true)
            throw 'The deployed AdapterHost probe exceeded its bounded process timeout.'
        }
        $remainingOutput.GetAwaiter().GetResult() | Out-Null
        $stderrTask.GetAwaiter().GetResult() | Out-Null
        if ($process.ExitCode -ne 0) {
            throw "The deployed AdapterHost probe failed with exit code $($process.ExitCode)."
        }
    }
    finally {
        [void]$startInfo.Environment.Remove('BUNKFY_SMOKE_INGESTION_OPERATOR_TOKEN')
        if ($processStarted -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }

    if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
        throw 'The deployed AdapterHost probe did not write evidence.'
    }
    $evidence = Get-Content -LiteralPath $EvidencePath -Raw |
        ConvertFrom-Json -Depth 12
    if ([int]$evidence.schemaVersion -ne 1 -or
        [string]$evidence.evidenceKind -cne 'bunkfy-deployed-adapter-host-probe' -or
        [string]$evidence.result -cne 'passed' -or
        [string]$evidence.releaseId -cne $ExpectedReleaseId -or
        [Guid]$evidence.workspaceId -ne $WorkspaceId -or
        [Guid]$evidence.propertyId -ne $PropertyId -or
        [Guid]$evidence.connectionId -ne $connectionId -or
        [Guid]$evidence.workerId -ne $workerId -or
        [string]$evidence.statusEndpointExposure -cne 'Disabled') {
        throw 'The deployed AdapterHost probe evidence does not match the rehearsal identity.'
    }
}

function Stop-AdapterHostContainer {
    if (-not $containerCreated) {
        return
    }
    $existing = @(Invoke-AdapterDocker `
            -Arguments @('container', 'inspect', '--format', '{{.State.Running}}', $containerName) `
            -Operation 'Inspect the AdapterHost container for cleanup')
    if (@($existing | Where-Object { [string]$_ -ceq 'true' }).Count -eq 1) {
        [void](Invoke-AdapterDocker `
                -Arguments @('stop', '--time', '30', $containerName) `
                -Operation 'Stop the AdapterHost container')
    }
    [void](Invoke-AdapterDocker `
            -Arguments @('rm', '--force', $containerName) `
            -Operation 'Remove the AdapterHost container')
    $script:containerCreated = $false
}

function Disable-AdapterConnection {
    if ($connectionId -eq [Guid]::Empty) {
        return
    }
    $connection = Read-AdapterRehearsalJson `
        -Response (Invoke-AdapterRehearsalApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read the AdapterHost connection for cleanup'
    if ([int]$connection.status -eq 2) {
        return
    }
    if ([int]$connection.status -ne 1) {
        throw 'The AdapterHost connection has an unsupported cleanup status.'
    }
    $receipt = Read-AdapterRehearsalJson `
        -Response (Invoke-AdapterRehearsalApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/disable" `
            -Method POST `
            -Body ([ordered]@{
                    operationId = [Guid]::NewGuid()
                    expectedVersion = [long]$connection.version
                })) `
        -ExpectedStatus 200 `
        -Operation 'Disable the AdapterHost connection'
    if ([Guid]$receipt.connectionId -ne $connectionId -or
        [int]$receipt.status -ne 2) {
        throw 'The AdapterHost connection disable receipt is invalid.'
    }
}

function Revoke-AdapterCredential {
    if ($connectionId -eq [Guid]::Empty -or $credentialId -eq [Guid]::Empty) {
        return
    }
    $credentials = Read-AdapterRehearsalJson `
        -Response (Invoke-AdapterRehearsalApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/credentials?page=1&pageSize=100" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'List AdapterHost credentials for cleanup'
    $matching = @($credentials.credentials | Where-Object {
            [Guid]$_.credentialId -eq $credentialId
        })
    if ($matching.Count -ne 1) {
        throw 'The AdapterHost credential is not uniquely visible for cleanup.'
    }
    if ([int]$matching[0].status -eq 2) {
        return
    }
    if ([int]$matching[0].status -ne 1) {
        throw 'The AdapterHost credential has an unsupported cleanup status.'
    }
    $receipt = Read-AdapterRehearsalJson `
        -Response (Invoke-AdapterRehearsalApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/credentials/$($credentialId.ToString('D'))/revoke" `
            -Method POST `
            -Body ([ordered]@{
                    operationId = [Guid]::NewGuid()
                    expectedVersion = [long]$matching[0].version
                })) `
        -ExpectedStatus 200 `
        -Operation 'Revoke the AdapterHost ingress credential'
    if ([Guid]$receipt.credentialId -ne $credentialId -or
        [int]$receipt.status -ne 2) {
        throw 'The AdapterHost credential revoke receipt is invalid.'
    }
}

function Remove-AdapterVolume {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][bool] $Created
    )

    if (-not $Created) {
        return
    }
    [void](Invoke-AdapterDocker `
            -Arguments @('volume', 'rm', $Name) `
            -Operation "Remove AdapterHost volume '$Name'")
}

if (-not $PSCmdlet.ShouldProcess(
        "$($origin.GetLeftPart([UriPartial]::Authority)) workspace $WorkspaceId property $PropertyId",
        'create a transient remote adapter connection, launch one exact-digest AdapterHost, ingest and cancel a synthetic reservation, then remove runtime state')) {
    $client.Dispose()
    $operatorToken = $null
    return
}

try {
    $releaseBefore = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds

    $ingressPreflightConnectionId = [Guid]::NewGuid()
    $ingressPreflightResponse = Invoke-AdapterRehearsalApi `
        -Path "/api/ingestion/adapter-ingress/connections/$($ingressPreflightConnectionId.ToString('D'))/remote-leases/claim" `
        -Method POST `
        -Body ([ordered]@{
                claimId = [Guid]::NewGuid()
                workerId = [Guid]::NewGuid()
                adapterType = 'json.file-drop'
                protocolVersion = 1
                configurationSchemaVersion = 1
                requestedLeaseSeconds = 120
            })
    Assert-BunkFyAuthenticatedStatus `
        -Response $ingressPreflightResponse `
        -ExpectedStatus 401 `
        -Operation 'Verify Preview adapter ingress is enabled and independently authenticated'

    $connectionReceipt = Read-AdapterRehearsalJson `
        -Response (Invoke-AdapterRehearsalApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections" `
            -Method POST `
            -Body ([ordered]@{
                    operationId = [Guid]::NewGuid()
                    adapterType = 'json.file-drop'
                    executionMode = 4
                    conflictPolicy = 2
                    configurationReference = "preview://adapter-host/$batchId/configuration"
                    secretReference = $null
                })) `
        -ExpectedStatus 200 `
        -Operation 'Create the Preview AdapterHost connection'
    $connectionId = [Guid]$connectionReceipt.connectionId
    if ($connectionId -eq [Guid]::Empty -or
        [int]$connectionReceipt.status -ne 1) {
        throw 'The Preview AdapterHost connection receipt is invalid.'
    }

    $credentialResponse = Read-AdapterRehearsalJson `
        -Response (Invoke-AdapterRehearsalApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/credentials" `
            -Method POST `
            -Body ([ordered]@{
                    operationId = [Guid]::NewGuid()
                    label = 'Preview AdapterHost rehearsal'
                    expiresAtUtc = [DateTimeOffset]::UtcNow.AddHours(2).ToString('O')
                    sourceSystem = 'preview.adapter-host-rehearsal'
                })) `
        -ExpectedStatus 200 `
        -Operation 'Issue the Preview AdapterHost ingress credential'
    $credentialId = [Guid]$credentialResponse.credential.credentialId
    $issuedToken = [string]$credentialResponse.token
    if ($credentialId -eq [Guid]::Empty -or
        [int]$credentialResponse.credential.status -ne 1 -or
        [int]$credentialResponse.outcome -ne 1 -or
        [string]::IsNullOrWhiteSpace($issuedToken) -or
        $issuedToken.Length -gt 512 -or
        @($issuedToken.ToCharArray() | Where-Object {
                [char]::IsWhiteSpace($_) -or [char]::IsControl($_)
            }).Count -gt 0) {
        throw 'The Preview AdapterHost ingress credential response is invalid.'
    }

    Initialize-AdapterVolume -Name $materialVolume
    Initialize-AdapterVolume -Name $fileDropVolume
    Write-AdapterMaterialFile -Name 'configuration.json' -Content '{}'
    Write-AdapterMaterialFile -Name 'ingress-token' -Content $issuedToken
    $issuedToken = $null

    $adapterHostOrigin = Start-AdapterHostContainer
    $externalId = "preview-adapter-$batchId"
    $externalIdHash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.UTF8Encoding]::new($false).GetBytes($externalId))).ToLowerInvariant()
    $arrival = [DateTime]::UtcNow.Date.AddDays(45)
    $departure = $arrival.AddDays(2)
    $upsertEnvelope = [ordered]@{
        schemaVersion = 1
        recordType = 'reservation.v1'
        externalRecordId = $externalId
        sourceRevision = '1'
        sourceUpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        payload = [ordered]@{
            operation = 'upsert'
            sourceSequence = 1
            arrival = $arrival.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            departure = $departure.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            inventoryUnitIds = @($InventoryUnitId.ToString('D'))
            primaryGuestName = 'Preview AdapterHost smoke'
            guestCount = 1
        }
    } | ConvertTo-Json -Depth 8 -Compress
    Invoke-AdapterProbeWithSeed `
        -AdapterHostOrigin $adapterHostOrigin `
        -EvidencePath $UpsertEvidencePath `
        -ExternalIdSha256 $externalIdHash `
        -RecordFileName "001-$batchId.json" `
        -Envelope $upsertEnvelope

    $cancellationEnvelope = [ordered]@{
        schemaVersion = 1
        recordType = 'reservation.v1'
        externalRecordId = $externalId
        sourceRevision = '2'
        sourceUpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        payload = [ordered]@{
            operation = 'cancel'
            sourceSequence = 2
        }
    } | ConvertTo-Json -Depth 8 -Compress
    Invoke-AdapterProbeWithSeed `
        -AdapterHostOrigin $adapterHostOrigin `
        -EvidencePath $CancellationEvidencePath `
        -ExternalIdSha256 $externalIdHash `
        -RecordFileName "002-$batchId.json" `
        -Envelope $cancellationEnvelope

    $releaseAfter = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds
    if ($releaseAfter -cne $releaseBefore) {
        throw 'The public API release identity changed during the Preview AdapterHost rehearsal.'
    }
}
catch {
    $proofError = $_.Exception
}
finally {
    foreach ($cleanup in @(
            [pscustomobject]@{ Name = 'container'; Action = { Stop-AdapterHostContainer } },
            [pscustomobject]@{ Name = 'connection'; Action = { Disable-AdapterConnection } },
            [pscustomobject]@{ Name = 'credential'; Action = { Revoke-AdapterCredential } },
            [pscustomobject]@{
                Name = 'material-volume'
                Action = { Remove-AdapterVolume -Name $materialVolume -Created $materialVolumeCreated }
            },
            [pscustomobject]@{
                Name = 'file-drop-volume'
                Action = { Remove-AdapterVolume -Name $fileDropVolume -Created $fileDropVolumeCreated }
            })) {
        try {
            & $cleanup.Action
        }
        catch {
            $cleanupFailures.Add([string]$cleanup.Name)
        }
    }
    $issuedToken = $null
    $operatorToken = $null
    $client.Dispose()
}

if ($null -ne $proofError) {
    throw $proofError
}
if ($cleanupFailures.Count -gt 0) {
    throw "Preview AdapterHost proof passed, but cleanup failed for: $($cleanupFailures -join ', ')."
}

Write-Host 'Preview AdapterHost upsert and cancellation proofs passed; runtime state was removed.'
Write-Host "Upsert evidence: $UpsertEvidencePath"
Write-Host "Cancellation evidence: $CancellationEvidencePath"
