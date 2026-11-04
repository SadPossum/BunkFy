[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CandidateDirectory,
    [Parameter(Mandatory)][string] $BundleDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $ExpectedSourceCommit,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $ExpectedHarnessCommit,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [Parameter(Mandatory)][string] $PrivateDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$candidate = [IO.Path]::GetFullPath($CandidateDirectory)
$evidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
$privateDirectory = [IO.Path]::GetFullPath($PrivateDirectory)
$qualification = $PSScriptRoot
$operations = Join-Path $candidate 'eng/operations'
. (Join-Path $candidate 'eng/common.ps1')
. (Join-Path $operations 'local-sensitive-state.common.ps1')
. (Join-Path $operations 'preview-state.common.ps1')
. (Join-Path $operations 'preview-storage.common.ps1')
. (Join-Path $qualification 'runtime-hook.common.ps1')
$composePath = Join-Path $candidate 'deploy/preview/compose.yaml'
$composeWorkingDirectory = Split-Path -Parent $composePath
$mailpitOverlay = Join-Path $candidate 'deploy/preview/compose.mailpit-operator.yaml'
$stage = 'preflight'
$privateCreated = $false
$cleanupPassed = $false
$instrumentedPath = $null
$callbackCompleted = $false
$previousEnvironment = [ordered]@{}
$environmentSaved = $false

function Invoke-QualificationProcess {
    param([string] $Executable, [string[]] $Arguments, [hashtable] $Environment = @{}, [int] $TimeoutSeconds = 180)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = $candidate
    $info.UseShellExecute = $false
    foreach ($name in @('GH_TOKEN','GITHUB_TOKEN','ACTIONS_RUNTIME_TOKEN')) { [void]$info.Environment.Remove($name) }
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    foreach ($entry in $Environment.GetEnumerator()) { $info.Environment[$entry.Key] = [string]$entry.Value }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Cannot start a qualification child process.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Qualification child exceeded its bounded runtime.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $diagnostic = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            # This file stays under the private workspace and is never uploaded.
            [IO.File]::WriteAllText((Join-Path $privateDirectory 'last-child.log'), $output + "`n" + $diagnostic)
            throw 'Qualification child failed; response bodies and diagnostics remain private.'
        }
        return $output.Trim()
    }
    finally { $process.Dispose() }
}

function Invoke-QualificationDocker {
    param([string[]] $Arguments)
    return Invoke-QualificationProcess -Executable docker -Arguments $Arguments -TimeoutSeconds 300
}

function Get-QualificationCompose {
    param([string] $EnvironmentPath, [switch] $OperatorWindow, [string[]] $Tail)
    $arguments = @('compose', '--env-file', $EnvironmentPath, '-f', $composePath)
    if ($OperatorWindow) { $arguments += @('-f', $mailpitOverlay) }
    return Invoke-QualificationDocker -Arguments ($arguments + @('--profile', 'operations') + $Tail)
}

function Get-OwnedContainer {
    param([string] $EnvironmentPath, [string] $Project, [string] $Service)
    $ids = @(Get-QualificationCompose $EnvironmentPath -Tail @('ps', '--all', '--quiet', $Service))
    if ($ids.Count -ne 1 -or $ids[0] -cnotmatch '^[0-9a-f]{64}$') { throw 'Expected one owned service container.' }
    $container = @(ConvertFrom-Json (Invoke-QualificationDocker -Arguments @('inspect', $ids[0])))[0]
    if ($container.Config.Labels.'com.docker.compose.project' -cne $Project -or
        $container.Config.Labels.'com.docker.compose.service' -cne $Service -or
        $container.Config.Labels.'com.docker.compose.project.working_dir' -cne $composeWorkingDirectory) {
        throw 'Container is outside this exact candidate project.'
    }
    return $container
}

function Write-ProtocolConfiguration {
    param([string] $EnvironmentPath, [string] $Project, [string] $Name)
    $definition = Get-BunkFyPreviewComposeDefinition -Root $candidate -ComposePath $composePath -EnvironmentPath $EnvironmentPath
    if ([string]$definition.name -cne $Project) { throw 'Resolved protocol project differs from the owned project.' }
    $nats = Get-OwnedContainer $EnvironmentPath $Project nats
    $redis = Get-OwnedContainer $EnvironmentPath $Project redis
    $s3 = Get-OwnedContainer $EnvironmentPath $Project minio
    $addresses = @{}
    foreach ($entry in @{ nats = $nats; minio = $s3 }.GetEnumerator()) {
        $container = $entry.Value
        if ($null -ne $container.HostConfig.PortBindings -and
            @($container.HostConfig.PortBindings.PSObject.Properties).Count -gt 0) {
            throw 'Private protocol service unexpectedly publishes host ports.'
        }
        $networks = @($container.NetworkSettings.Networks.PSObject.Properties)
        if ($networks.Count -ne 1) { throw 'Protocol service must use one owned private backend network.' }
        $network = @(ConvertFrom-Json (Invoke-QualificationDocker -Arguments @('network', 'inspect', $networks[0].Value.NetworkID)))[0]
        if ($network.Labels.'com.docker.compose.project' -cne $Project -or -not $network.Internal) {
            throw 'Protocol service network is outside the private owned project.'
        }
        $address = [Net.IPAddress]::Parse([string]$networks[0].Value.IPAddress)
        if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            $address.ToString() -notmatch '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)') {
            throw 'Protocol service address is outside private IPv4.'
        }
        $addresses[$entry.Key] = $address.ToString()
    }
    # Read secrets from resolved Compose into a private file, never host argv or logs.
    $arguments = @($definition.services.nats.command)
    $user = @($arguments | Where-Object { $_ -clike '--user=*' })
    $password = @($arguments | Where-Object { $_ -clike '--pass=*' })
    if ($user.Count -ne 1 -or $password.Count -ne 1) { throw 'Unknown broker credential shape.' }
    $configuration = [ordered]@{
        candidateRoot = $candidate
        nats = @{ url = "nats://$($addresses.nats):4222"; user = $user[0].Substring(7); password = $password[0].Substring(7) }
        redisContainer = $redis.Id
        s3 = @{ endpoint = "http://$($addresses.minio):9000";
            key = $definition.services.minio.environment.MINIO_ROOT_USER
            password = $definition.services.minio.environment.MINIO_ROOT_PASSWORD }
    }
    $path = Join-Path $privateDirectory "$Name-protocol.json"
    Write-BunkFyLocalSensitiveTextFile -Path $path -Content ($configuration | ConvertTo-Json -Depth 5) -Description 'Private protocol configuration'
    return $path
}

function Invoke-Canary {
    param([string] $Mode, [Uri] $Origin, [string] $Release, [string] $MailpitOrigin = '')
    $output = Join-Path $evidenceDirectory "business-$Mode.json"
    [void](Invoke-QualificationProcess -Executable node -Arguments @((Join-Path $qualification 'business-canary.mjs'), $Mode) -Environment @{
        CANDIDATE_ROOT = $candidate; CANDIDATE_PROBE_PUBLIC_ORIGIN = $Origin.AbsoluteUri
        CANDIDATE_PROBE_RELEASE_ID = $Release; CANDIDATE_SOURCE_COMMIT = $ExpectedSourceCommit
        CANDIDATE_MAILPIT_ORIGIN = $MailpitOrigin
        CANDIDATE_CANARY_PRIVATE_STATE = (Join-Path $privateDirectory 'business-state.json')
        CANDIDATE_CANARY_EVIDENCE = $output
    } -TimeoutSeconds 900)
    if ((Get-Content $output -Raw | ConvertFrom-Json).result -cne 'passed') { throw 'Business canary failed.' }
}

function Invoke-ProtocolCanary {
    param([string] $Mode, [string] $Configuration)
    $output = Join-Path $evidenceDirectory "protocol-$Mode.json"
    [void](Invoke-QualificationProcess -Executable python3 -Arguments @((Join-Path $qualification 'protocol-canaries.py'), $Mode,
        $Configuration, (Join-Path $privateDirectory 'protocol-state.json'), $output) -TimeoutSeconds 120)
    $result = Get-Content $output -Raw | ConvertFrom-Json
    if ($result.result -cne 'passed' -or @($result.checks).Count -ne 3) { throw 'Protocol canary failed.' }
}

function Get-RecoveryResourceNames {
    param([ValidateSet('container','network','volume')][string] $Type)
    $arguments = if ($Type -ceq 'container') { @('container','ls','--all','--quiet') } else { @($Type,'ls','--quiet') }
    $ids = (Invoke-QualificationDocker -Arguments ($arguments + @('--filter','label=com.docker.compose.project'))) -split '\r?\n'
    foreach ($id in $ids | Where-Object { $_ }) {
        $item = @(ConvertFrom-Json (Invoke-QualificationDocker -Arguments @($Type,'inspect',$id)))[0]
        $labels = if ($Type -ceq 'container') { $item.Config.Labels } else { $item.Labels }
        $projectProperty = $labels.PSObject.Properties['com.docker.compose.project']
        if ($null -ne $projectProperty -and [string]$projectProperty.Value -cmatch '^bunkfy-recovery-[a-f0-9]{12}$') {
            # This harness requires an empty recovery namespace at preflight.
            # Later removal also checks the exact candidate working directory.
            [pscustomobject]@{ Id = $id; Item = $item; Project = [string]$projectProperty.Value }
        }
    }
}

function Remove-OwnedRecoveryResources {
    foreach ($type in @('container','network','volume')) {
        foreach ($resource in @(Get-RecoveryResourceNames $type)) {
            if ($type -ceq 'container') {
                if ($resource.Item.Config.Labels.'com.docker.compose.project.working_dir' -cne $composeWorkingDirectory) {
                    throw 'Refusing recovery cleanup outside the exact candidate working directory.'
                }
                [void](Invoke-QualificationDocker -Arguments @('container','rm','--force',$resource.Id))
            }
            elseif ($type -ceq 'volume') {
                if ([string]$resource.Item.Name -cnotmatch ('^' + [regex]::Escape($resource.Project) + '-')) {
                    throw 'Refusing recovery cleanup of a volume outside its unique prefix.'
                }
                [void](Invoke-QualificationDocker -Arguments @('volume','rm',$resource.Id))
            }
            else { [void](Invoke-QualificationDocker -Arguments @('network','rm',$resource.Id)) }
        }
    }
    foreach ($type in @('container','network','volume')) {
        if (@(Get-RecoveryResourceNames $type).Count -ne 0) { throw 'Owned recovery resources remain.' }
    }
}

function Close-QualificationMailpit {
    param([string] $EnvironmentPath, [string] $Project)
    Remove-Item Env:BUNKFY_MAILPIT_OPERATOR_PORT -ErrorAction SilentlyContinue
    [void](Get-QualificationCompose $EnvironmentPath -Tail @('up','--detach','--wait','--wait-timeout','180','--no-deps','--no-build','--pull','never','--force-recreate','mailpit'))
    $mailpit = Get-OwnedContainer $EnvironmentPath $Project mailpit
    if ((Invoke-QualificationDocker -Arguments @('port',$mailpit.Id)) -cne '') { throw 'Mailpit operator binding remained open.' }
    $ids = (Invoke-QualificationDocker -Arguments @('network','ls','--quiet','--filter',
        "label=com.docker.compose.project=$Project",'--filter','label=com.docker.compose.network=mailpit-operator')) -split '\r?\n'
    foreach ($id in $ids | Where-Object { $_ }) {
        $network = @(ConvertFrom-Json (Invoke-QualificationDocker -Arguments @('network','inspect',$id)))[0]
        if ($network.Labels.'com.docker.compose.project' -cne $Project -or
            $network.Labels.'com.docker.compose.network' -cne 'mailpit-operator' -or
            @($network.Containers.PSObject.Properties).Count -ne 0) {
            throw 'Refusing to remove an operator network outside the empty owned window.'
        }
        [void](Invoke-QualificationDocker -Arguments @('network','rm',$id))
    }
}

function Invoke-CodexExactCandidateCanaries {
    param([string] $EnvironmentPath, [Uri] $PublicOrigin, [string] $Project, [string] $Release,
        [string] $BackendReference, [string] $WebReference)
    $script:stage = 'real-onboarding-and-worker-restart'
    $env:BUNKFY_MAILPIT_OPERATOR_PORT = '0'
    try {
        [void](Get-QualificationCompose $EnvironmentPath -OperatorWindow -Tail @('up','--detach','--wait','--wait-timeout','180','--no-deps','--no-build','--pull','never','--force-recreate','mailpit'))
        $mailpit = Get-OwnedContainer $EnvironmentPath $Project mailpit
        $ports = Invoke-QualificationDocker -Arguments @('port',$mailpit.Id,'8025/tcp')
        if ($ports -cnotmatch '^127\.0\.0\.1:([0-9]{1,5})$') { throw 'Mailpit operator window must use exactly one loopback binding.' }
        $mailpitOrigin = "http://$ports/"
        $browserOutput = Join-Path $evidenceDirectory 'onboarding.json'
        [void](Invoke-QualificationProcess -Executable node -Arguments @((Join-Path $operations 'rehearse-preview-browser-onboarding.mjs')) -Environment @{
            BUNKFY_BROWSER_PUBLIC_ORIGIN = $PublicOrigin.AbsoluteUri
            BUNKFY_BROWSER_EXPECTED_RELEASE_ID = $Release; BUNKFY_BROWSER_MAILPIT_ORIGIN = $mailpitOrigin
            BUNKFY_BROWSER_COMPOSE_PATH = $composePath; BUNKFY_BROWSER_ENVIRONMENT_PATH = $EnvironmentPath
            BUNKFY_BROWSER_COMPOSE_PROJECT_NAME = $Project; BUNKFY_BROWSER_RESULT_PATH = $browserOutput
            BUNKFY_BROWSER_FORCE = 'true'; BUNKFY_BROWSER_HEADLESS = 'true'; BUNKFY_BROWSER_EXERCISE_WORKER_RESTART = 'true'
            BUNKFY_BROWSER_INCLUDE_CUSTOM_PROFILE_ADMINISTRATION = 'false'; BUNKFY_BROWSER_ALLOW_LOOPBACK_HTTP = 'true'
            BUNKFY_BROWSER_REQUEST_TIMEOUT_MS = '15000'; BUNKFY_BROWSER_CONVERGENCE_TIMEOUT_MS = '180000'
            BUNKFY_BROWSER_POLL_INTERVAL_MS = '1000'
        } -TimeoutSeconds 1800)
        if ((Get-Content $browserOutput -Raw | ConvertFrom-Json).result -cne 'passed') { throw 'Actual onboarding evidence did not pass.' }
        $script:stage = 'real-booking-tenant-and-protected-authenticator'
        Invoke-Canary create $PublicOrigin $Release $mailpitOrigin
        $script:stage = 'real-broker-cache-and-object-markers'
        Invoke-ProtocolCanary create (Write-ProtocolConfiguration $EnvironmentPath $Project 'source')
    }
    finally { Close-QualificationMailpit $EnvironmentPath $Project }
    $script:stage = 'actual-schema-seven-backup'
    $backup = Join-Path $privateDirectory 'backup'
    & (Join-Path $operations 'backup-preview.ps1') -EnvironmentPath $EnvironmentPath -OutputPath $backup -Confirm:$false
    $manifestPath = Join-Path $backup 'manifest.json'
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 7 -or @($manifest.artifacts).Count -ne 8 -or
        $manifest.repositoryCommit -cne $ExpectedSourceCommit -or $manifest.projectName -cne $Project) {
        throw 'Backup did not bind the current candidate and all eight state artifacts.'
    }
    $digest = (Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:stage = 'stop-original-stack-before-restore'
    & (Join-Path $candidate 'eng/preview.ps1') down -EnvironmentPath $EnvironmentPath
    $running = Get-QualificationCompose $EnvironmentPath -Tail @('ps','--status','running','--quiet')
    if ($running -cne '') { throw 'Original candidate remained running during cold recovery.' }
    try {
        $script:stage = 'actual-empty-target-recovery'
        $recoveryOutput = Join-Path $evidenceDirectory 'recovery-operator.json'
        & (Join-Path $operations 'rehearse-preview-recovery.ps1') -BackupPath $backup -ExpectedManifestSha256 $digest `
            -EnvironmentPath $EnvironmentPath -BackendImage $BackendReference -WebImage $WebReference `
            -OutputPath $recoveryOutput -KeepRestoredTarget -Confirm:$false
        $recovery = Get-Content $recoveryOutput -Raw | ConvertFrom-Json
        $shortId = ([Guid]$recovery.rehearsalId).ToString('N').Substring(0,12)
        if ($recovery.result -cne 'passed' -or $recovery.backup.manifestSha256 -cne $digest -or
            $recovery.target.projectName -cne "bunkfy-recovery-$shortId" -or -not $recovery.target.keptAfterRehearsal) {
            throw 'Recovery operator evidence did not bind the isolated target and verified backup.'
        }
        $recoveredEnvironment = Join-Path $privateDirectory 'recovered.env'
        $settings = [IO.File]::ReadAllText($EnvironmentPath)
        $overrides = [ordered]@{
            BUNKFY_COMPOSE_PROJECT_NAME = "bunkfy-recovery-$shortId"; BUNKFY_VOLUME_PREFIX = "bunkfy-recovery-$shortId"
            BUNKFY_PUBLIC_PORT = ([Uri]$recovery.target.publicOrigin).Port
            BUNKFY_ADMIN_PORT = ([Uri]$recovery.target.adminOrigin).Port; BUNKFY_RELEASE_ID = "recovery-$shortId"
        }
        foreach ($entry in $overrides.GetEnumerator()) {
            if ([regex]::Matches($settings, '(?m)^' + $entry.Key + '=').Count -ne 1) { throw 'Unexpected generated environment setting shape.' }
            $settings = [regex]::Replace($settings, '(?m)^' + $entry.Key + '=[^\r\n]*', [string]($entry.Key + '=' + $entry.Value))
        }
        Write-BunkFyLocalSensitiveTextFile $recoveredEnvironment $settings -Description 'Private recovered configuration'
        $script:stage = 'real-cold-restored-broker-cache-and-objects'
        Invoke-ProtocolCanary restore (Write-ProtocolConfiguration $recoveredEnvironment $recovery.target.projectName 'restored')
        $script:stage = 'real-cold-restored-ui-mfa-booking-and-tenant'
        Invoke-Canary restore ([Uri]$recovery.target.publicOrigin) "recovery-$shortId"
    }
    finally {
        # Release recovered consumers before the original runtime operator
        # verifies removal of its imported candidate image tags.
        Remove-OwnedRecoveryResources
    }
    $script:callbackCompleted = $true
}

$report = [ordered]@{ schemaVersion = 1; result = 'failed'; applicationSourceCommit = $ExpectedSourceCommit
    harnessCommit = $ExpectedHarnessCommit; stage = $stage; cleanup = @{}
    scope = 'Disposable exact OCI Preview qualification; no production deployment or cross-version migration acceptance.' }
try {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Linux' -or
        $env:GITHUB_REPOSITORY -cne 'SadPossum/BunkFy') {
        throw 'Full qualification requires the disposable Linux Actions runner for this repository.'
    }
    $actualSource = (& git -C $candidate rev-parse HEAD).Trim()
    $actualHarness = (& git -C (Join-Path $qualification '../..') rev-parse HEAD).Trim()
    if ($actualSource -cne $ExpectedSourceCommit -or $actualHarness -cne $ExpectedHarnessCommit) { throw 'Checkout identity mismatch.' }
    Assert-BunkFyGitWorktreeClean -RepositoryPath $candidate
    foreach ($type in @('container','network','volume')) {
        if (@(Get-RecoveryResourceNames $type).Count -ne 0) { throw 'Recovery namespace is not empty; refusing ownership ambiguity.' }
    }
    if (Test-Path $privateDirectory) { throw 'Private qualification directory already exists.' }
    New-BunkFyLocalSensitiveDirectory $privateDirectory -Description 'Private full qualification state'
    $privateCreated = $true
    foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -cmatch '^(BUNKFY_|COMPOSE_)' }) {
        $previousEnvironment[$item.Name] = $item.Value
        Remove-Item "Env:$($item.Name)"
    }
    $environmentSaved = $true
    $operator = Join-Path $operations 'rehearse-candidate-preview-runtime.ps1'
    $sourceText = [IO.File]::ReadAllText($operator)
    $hooked = New-CodexCandidateRuntimeHook $sourceText $operations
    $instrumentedPath = Join-Path $candidate ('.tmp/.qualified-runtime-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    Write-BunkFyLocalSensitiveTextFile $instrumentedPath $hooked -Description 'Test-only runtime hook'
    $report['instrumentation'] = [ordered]@{
        originalOperatorSha256 = (Get-FileHash $operator -Algorithm SHA256).Hash.ToLowerInvariant()
        instrumentedOperatorSha256 = (Get-FileHash $instrumentedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        checkedHookCount = 1; originalAssertionsPreserved = $true; trackedCandidateFilesChanged = $false
    }
    $script:stage = 'attested-image-startup-and-isolation'
    & $instrumentedPath -BundleDirectory $BundleDirectory -ExpectedSourceCommit $ExpectedSourceCommit `
        -OutputPath (Join-Path $evidenceDirectory 'runtime.json')
    if (-not $callbackCompleted) { throw 'Full candidate callback did not complete.' }
    $runtime = Get-Content (Join-Path $evidenceDirectory 'runtime.json') -Raw | ConvertFrom-Json
    if ($runtime.result -cne 'passed' -or $runtime.sourceCommit -cne $ExpectedSourceCommit -or
        -not $runtime.candidate.attestationsVerified -or $runtime.runtime.profile -cne 'Preview') {
        throw 'Basic runtime evidence failed its exact-source assertions.'
    }
    foreach ($flag in @('stackRemoved','composeResourcesRemoved','generatedEnvironmentRemoved','importedCandidateTagsRemoved')) {
        if ($runtime.cleanup.$flag -ne $true) { throw 'Original runtime cleanup assertion failed.' }
    }
    $report.result = 'passed'
}
catch {
    $report['failureType'] = $_.Exception.GetType().FullName
    $report['failureStage'] = $stage
    $report['safeFailure'] = Get-CodexSafeRuntimeFailure -Failure $_
}
finally {
    try {
        if ($privateCreated) { Remove-OwnedRecoveryResources }
    }
    catch { $report.result = 'failed'; $report['recoveryCleanupFailureType'] = $_.Exception.GetType().FullName }
    try {
        if ($null -ne $instrumentedPath -and (Test-Path $instrumentedPath)) { Remove-Item $instrumentedPath -Force }
        if ($privateCreated) { Remove-Item $privateDirectory -Recurse -Force }
        if ($privateCreated -and (Test-Path $privateDirectory)) { throw 'Private qualification material remains.' }
        $cleanupPassed = -not $report.Contains('recoveryCleanupFailureType')
    }
    catch { $report.result = 'failed'; $report['cleanupFailureType'] = $_.Exception.GetType().FullName }
    if ($environmentSaved) {
        foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -cmatch '^(BUNKFY_|COMPOSE_)' }) { Remove-Item "Env:$($item.Name)" }
        foreach ($name in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,[string]$previousEnvironment[$name]) }
    }
    $report.stage = $stage
    $report.cleanup = @{ recoveredResourcesAndPrivateMaterialRemoved = $cleanupPassed }
    $report | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidenceDirectory 'full-runtime.json')
}
if ($report.result -cne 'passed') { throw "Full candidate qualification failed during '$stage'; see minimized evidence." }
Write-Host 'Exact OCI onboarding, Worker, booking, tenant isolation, cold backup/recovery and protected MFA passed.'
