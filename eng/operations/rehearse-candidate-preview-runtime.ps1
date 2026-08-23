[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $BundleDirectory,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSourceCommit,
    [ValidateRange(0, 65535)][int] $PublicPort = 0,
    [ValidateRange(0, 65535)][int] $AdminPort = 0,
    [string] $OutputPath,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'local-sensitive-state.common.ps1')

$repositoryRoot = Get-BunkFyRepositoryRoot
$candidateVerifier = Join-Path $PSScriptRoot '..\verify-image-candidate.ps1'
$newPreviewEnvironment = Join-Path $PSScriptRoot '..\new-preview-env.ps1'
$preview = Join-Path $PSScriptRoot '..\preview.ps1'
$previewIsolation = Join-Path $PSScriptRoot 'verify-preview-isolation.ps1'
$publicEdgeVerifier = Join-Path $PSScriptRoot 'verify-deployed-public-edge.ps1'
$composeFile = Join-BunkFyPath 'deploy\preview\compose.yaml'

if ($ExpectedSourceCommit -ceq ('0' * 40)) {
    throw 'ExpectedSourceCommit must not be the all-zero placeholder.'
}
foreach ($requestedPort in @($PublicPort, $AdminPort)) {
    if ($requestedPort -ne 0 -and $requestedPort -lt 1024) {
        throw 'Explicit candidate rehearsal ports must be 1024 or greater.'
    }
}
if ($PublicPort -ne 0 -and $PublicPort -eq $AdminPort) {
    throw 'PublicPort and AdminPort must be distinct.'
}

$resolvedBundleDirectory = if ([IO.Path]::IsPathRooted($BundleDirectory)) {
    [IO.Path]::GetFullPath($BundleDirectory)
}
else {
    [IO.Path]::GetFullPath((Join-Path $repositoryRoot $BundleDirectory))
}
$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$nonce = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$sourcePrefix = $ExpectedSourceCommit.Substring(0, 12)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-BunkFyPath (
        ".tmp\candidate-runtime-rehearsals\$stamp-candidate-$sourcePrefix-$nonce.json")
}
$resolvedOutputPath = if ([IO.Path]::IsPathRooted($OutputPath)) {
    [IO.Path]::GetFullPath($OutputPath)
}
else {
    [IO.Path]::GetFullPath((Join-Path $repositoryRoot $OutputPath))
}
if (Test-Path -LiteralPath $resolvedOutputPath) {
    throw "Candidate runtime evidence already exists: '$resolvedOutputPath'."
}

$workingDirectory = Join-BunkFyPath (
    ".tmp\candidate-runtime-rehearsals\.working-$sourcePrefix-$nonce")
$environmentPath = Join-Path $workingDirectory 'preview.env'
$publicEdgeEvidencePath = Join-Path $workingDirectory 'public-edge.json'
$projectName = "bunkfy-candidate-$sourcePrefix-$nonce"
$volumePrefix = $projectName
$releaseId = "candidate-$ExpectedSourceCommit"
$backendReference = "bunkfy/backend:candidate-$ExpectedSourceCommit"
$webReference = "bunkfy/web:candidate-$ExpectedSourceCommit"

function Invoke-BunkFyCandidateDocker {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [int] $TimeoutSeconds = 900
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'docker'
    $startInfo.WorkingDirectory = $repositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Unable to start Docker.'
    }

    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        $process.WaitForExit()
        $process.Dispose()
        throw "Docker exceeded the $TimeoutSeconds second candidate-runtime budget."
    }

    $capturedStandardOutput = $standardOutput.GetAwaiter().GetResult().TrimEnd()
    $capturedStandardError = $standardError.GetAwaiter().GetResult().TrimEnd()
    $output = @($capturedStandardOutput, $capturedStandardError) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $exitCode = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutput = $capturedStandardOutput
        StandardError = $capturedStandardError
        Output = $output -join [Environment]::NewLine
    }
}

function Assert-BunkFyCandidateDockerSuccess {
    param(
        [Parameter(Mandatory = $true)][object] $Result,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Result.ExitCode -ne 0) {
        throw "$Context failed with exit code $($Result.ExitCode).`n$($Result.Output)"
    }
}

function Get-BunkFyAvailableLoopbackPort {
    param(
        [int] $RequestedPort,
        [int[]] $ExcludedPorts = @()
    )

    do {
        $listener = [Net.Sockets.TcpListener]::new(
            [Net.IPAddress]::Loopback,
            $RequestedPort)
        try {
            $listener.Start()
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        }
        catch {
            if ($RequestedPort -ne 0) {
                throw "Loopback port $RequestedPort is not available."
            }
            throw
        }
        finally {
            $listener.Stop()
        }
        if ($RequestedPort -ne 0 -and $ExcludedPorts -contains $port) {
            throw "Loopback port $port is already reserved by this rehearsal."
        }
    } while ($ExcludedPorts -contains $port)

    return $port
}

function Set-BunkFyCandidateEnvironmentSettings {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][Collections.IDictionary] $Settings
    )

    [string[]]$lines = [IO.File]::ReadAllLines($Path)

    foreach ($entry in $Settings.GetEnumerator()) {
        $key = [string]$entry.Key
        $replacement = "$key=$([string]$entry.Value)"
        $matches = @(
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match "^$([Regex]::Escape($key))=") {
                    $index
                }
            })
        if ($matches.Count -gt 1) {
            throw "Preview environment contains duplicate setting '$key'."
        }
        if ($matches.Count -eq 1) {
            $lines[$matches[0]] = $replacement
        }
        else {
            $lines += $replacement
        }
    }

    Write-BunkFyLocalSensitiveTextFile `
        -Path $Path `
        -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine) `
        -Overwrite `
        -Description 'Candidate Preview environment'
}

function Import-BunkFyCandidateImage {
    param(
        [Parameter(Mandatory = $true)][object] $Candidate,
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][string] $Reference
    )

    $existing = Invoke-BunkFyCandidateDocker -Arguments @(
        'image', 'inspect', $Reference)
    if ($existing.ExitCode -eq 0) {
        throw "Candidate image '$Reference' already exists locally; refusing to replace it."
    }

    $script:loadedReferences.Add($Reference)
    $load = Invoke-BunkFyCandidateDocker -Arguments @(
        'image', 'load', '--input', $ArchivePath)
    Assert-BunkFyCandidateDockerSuccess `
        -Result $load `
        -Context "Loading candidate image '$Reference'"
    if (-not $load.Output.Contains(
            "Loaded image: $Reference",
            [StringComparison]::Ordinal)) {
        throw "Docker did not report the expected candidate image '$Reference'."
    }

    $inspect = Invoke-BunkFyCandidateDocker -Arguments @(
        'image', 'inspect', $Reference)
    Assert-BunkFyCandidateDockerSuccess `
        -Result $inspect `
        -Context "Inspecting candidate image '$Reference'"
    $records = @(ConvertFrom-Json -InputObject $inspect.Output)
    if ($records.Count -ne 1) {
        throw "Candidate image '$Reference' did not resolve to exactly one image."
    }

    $expectedRepositoryDigest = "$($Reference.Split(':', 2)[0])@$($Candidate.ManifestDigest)"
    $repositoryDigests = @(
        $records[0].RepoDigests |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique)
    $repositoryTags = @(
        $records[0].RepoTags |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique)
    $imageId = [string]$records[0].Id
    if ($imageId -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $repositoryDigests.Count -ne 1 -or
        $repositoryDigests[0] -cne $expectedRepositoryDigest -or
        $repositoryTags.Count -ne 1 -or
        $repositoryTags[0] -cne $Reference) {
        throw "Candidate image '$Reference' does not match its attested manifest."
    }

    return [pscustomobject]@{
        Name = [string]$Candidate.Name
        Reference = $Reference
        ArchiveSha256 = [string]$Candidate.Sha256
        ManifestDigest = [string]$Candidate.ManifestDigest
        ImageId = $imageId
    }
}

function Get-BunkFyComposeArguments {
    param([string[]] $Tail = @())

    return @(
        'compose',
        '--env-file', $environmentPath,
        '-f', $composeFile,
        '--profile', 'operations') + $Tail
}

function Assert-BunkFyServiceImageBinding {
    param(
        [Parameter(Mandatory = $true)][string] $Service,
        [Parameter(Mandatory = $true)][string] $ExpectedImageId,
        [Parameter(Mandatory = $true)][ValidateSet('running', 'completed')]
        [string] $ExpectedState,
        [switch] $RequireHealthy
    )

    $containerQuery = Invoke-BunkFyCandidateDocker -Arguments (
        Get-BunkFyComposeArguments @('ps', '--all', '--quiet', $Service))
    Assert-BunkFyCandidateDockerSuccess `
        -Result $containerQuery `
        -Context "Resolving candidate service '$Service'"
    $containerIds = @(
        $containerQuery.StandardOutput -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($containerIds.Count -ne 1) {
        throw "Candidate service '$Service' must have exactly one container."
    }

    $inspect = Invoke-BunkFyCandidateDocker -Arguments @(
        'container', 'inspect', $containerIds[0])
    Assert-BunkFyCandidateDockerSuccess `
        -Result $inspect `
        -Context "Inspecting candidate service '$Service'"
    $container = @(ConvertFrom-Json -InputObject $inspect.Output)[0]
    if ([string]$container.Image -cne $ExpectedImageId) {
        throw "Candidate service '$Service' is not using the attested image identity."
    }

    $state = [string]$container.State.Status
    $exitCode = [int]$container.State.ExitCode
    if (($ExpectedState -eq 'running' -and
            ($state -cne 'running' -or -not $container.State.Running)) -or
        ($ExpectedState -eq 'completed' -and
            ($state -cne 'exited' -or $exitCode -ne 0))) {
        throw "Candidate service '$Service' is in unexpected state '$state' with exit code $exitCode."
    }

    $healthProperty = $container.State.PSObject.Properties['Health']
    $health = if ($null -eq $healthProperty) {
        'not-configured'
    }
    else {
        [string]$healthProperty.Value.Status
    }
    if ($RequireHealthy -and $health -cne 'healthy') {
        throw "Candidate service '$Service' is not healthy."
    }

    return [ordered]@{
        service = $Service
        image = if ($ExpectedImageId -ceq $script:backendImage.ImageId) {
            'backend'
        }
        else {
            'web'
        }
        state = $state
        health = $health
    }
}

function Get-BunkFyProjectResourceIds {
    param([Parameter(Mandatory = $true)][ValidateSet('container', 'network', 'volume')]
        [string] $ResourceType)

    $arguments = switch ($ResourceType) {
        'container' {
            @('container', 'ls', '--all', '--quiet', '--filter',
                "label=com.docker.compose.project=$projectName")
        }
        'network' {
            @('network', 'ls', '--quiet', '--filter',
                "label=com.docker.compose.project=$projectName")
        }
        'volume' {
            @('volume', 'ls', '--quiet', '--filter',
                "label=com.docker.compose.project=$projectName")
        }
    }
    $query = Invoke-BunkFyCandidateDocker -Arguments $arguments -TimeoutSeconds 120
    Assert-BunkFyCandidateDockerSuccess `
        -Result $query `
        -Context "Inspecting candidate $ResourceType resources"
    return @(
        $query.StandardOutput -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Add-BunkFyCleanupFailure {
    param(
        [Parameter(Mandatory = $true)][Management.Automation.ErrorRecord] $CleanupError
    )

    if ($null -eq $script:failure) {
        $script:failure = $CleanupError
        return
    }

    $script:failure = [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new(
            "$($script:failure.Exception.Message) Cleanup also failed: $($CleanupError.Exception.Message)",
            $script:failure.Exception),
        'CandidateRuntimeCleanupFailed',
        [Management.Automation.ErrorCategory]::InvalidOperation,
        $null)
}

$verification = @(& $candidateVerifier `
        -BundleDirectory $resolvedBundleDirectory `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -PassThru)
if ($verification.Count -ne 1 -or -not $verification[0].AttestationsVerified) {
    throw 'The OCI candidate bundle did not produce one attested verification result.'
}
$backendCandidates = @(
    $verification[0].Images |
        Where-Object { $_.Name -ceq 'backend' })
$webCandidates = @(
    $verification[0].Images |
        Where-Object { $_.Name -ceq 'web' })
if ($backendCandidates.Count -ne 1 -or $webCandidates.Count -ne 1) {
    throw 'The OCI candidate bundle must contain exactly one backend and one web image.'
}

$backendArchive = Join-Path $resolvedBundleDirectory 'oci\backend.oci.tar'
$webArchive = Join-Path $resolvedBundleDirectory 'oci\web.oci.tar'
$selectedPublicPort = Get-BunkFyAvailableLoopbackPort -RequestedPort $PublicPort
$selectedAdminPort = Get-BunkFyAvailableLoopbackPort `
    -RequestedPort $AdminPort `
    -ExcludedPorts @($selectedPublicPort)
$publicOrigin = [Uri]"http://127.0.0.1:$selectedPublicPort/"

$script:backendImage = $null
$webImage = $null
$script:loadedReferences = [Collections.Generic.List[string]]::new()
$serviceBindings = @()
$resolvedImages = @()
$publicEdgeEvidence = $null
$publicEdgeEvidenceSha256 = $null
$workingDirectoryCreated = $false
$environmentGenerated = $false
$stackMayExist = $false
$stackRemoved = $false
$candidateResourcesRemoved = $false
$environmentRemoved = $false
$importedImagesRemoved = $false
$script:failure = $null

try {
    foreach ($resourceType in @('container', 'network', 'volume')) {
        if (@(Get-BunkFyProjectResourceIds -ResourceType $resourceType).Count -ne 0) {
            throw "Candidate Compose project '$projectName' already owns Docker resources."
        }
    }

    New-BunkFyLocalSensitiveDirectory `
        -Path $workingDirectory `
        -Description 'Candidate runtime working directory'
    $workingDirectoryCreated = $true

    & $newPreviewEnvironment -OutputPath $environmentPath
    $environmentGenerated = $true
    Set-BunkFyCandidateEnvironmentSettings `
        -Path $environmentPath `
        -Settings ([ordered]@{
            BUNKFY_PUBLIC_PORT = $selectedPublicPort
            BUNKFY_ADMIN_PORT = $selectedAdminPort
            BUNKFY_PUBLIC_URL = $publicOrigin.GetLeftPart([UriPartial]::Authority)
            BUNKFY_ALLOWED_HOSTS = '127.0.0.1;localhost'
            BUNKFY_COMPOSE_PROJECT_NAME = $projectName
            BUNKFY_VOLUME_PREFIX = $volumePrefix
            BUNKFY_RELEASE_ID = $releaseId
            BUNKFY_BACKEND_IMAGE = $backendReference
            BUNKFY_WEB_IMAGE = $webReference
        })

    Write-Host "Loading attested candidate '$ExpectedSourceCommit'."
    $script:backendImage = Import-BunkFyCandidateImage `
        -Candidate $backendCandidates[0] `
        -ArchivePath $backendArchive `
        -Reference $backendReference
    $webImage = Import-BunkFyCandidateImage `
        -Candidate $webCandidates[0] `
        -ArchivePath $webArchive `
        -Reference $webReference

    & $preview config -EnvironmentPath $environmentPath

    $imageConfiguration = Invoke-BunkFyCandidateDocker -Arguments (
        Get-BunkFyComposeArguments @('config', '--images'))
    Assert-BunkFyCandidateDockerSuccess `
        -Result $imageConfiguration `
        -Context 'Resolving candidate Preview images'
    $resolvedImages = @(
        $imageConfiguration.StandardOutput -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique)
    if ($resolvedImages.Count -lt 7 -or
        $resolvedImages -notcontains $backendReference -or
        $resolvedImages -notcontains $webReference) {
        throw 'Candidate Preview did not resolve the expected first-party and dependency images.'
    }
    foreach ($image in $resolvedImages) {
        $localImage = Invoke-BunkFyCandidateDocker -Arguments @(
            'image', 'inspect', $image) -TimeoutSeconds 120
        if ($localImage.ExitCode -ne 0) {
            throw "Resolved image '$image' is not available locally; candidate rehearsal will not pull it."
        }
    }

    $stackMayExist = $true
    & $preview up `
        -EnvironmentPath $environmentPath `
        -Operations `
        -NoBuild `
        -NoPull

    $serviceBindings = @(
        Assert-BunkFyServiceImageBinding `
            -Service 'tenant-termination-replay-init' `
            -ExpectedImageId $script:backendImage.ImageId `
            -ExpectedState completed
        Assert-BunkFyServiceImageBinding `
            -Service 'migrations' `
            -ExpectedImageId $script:backendImage.ImageId `
            -ExpectedState completed
        Assert-BunkFyServiceImageBinding `
            -Service 'api' `
            -ExpectedImageId $script:backendImage.ImageId `
            -ExpectedState running `
            -RequireHealthy
        Assert-BunkFyServiceImageBinding `
            -Service 'worker' `
            -ExpectedImageId $script:backendImage.ImageId `
            -ExpectedState running
        Assert-BunkFyServiceImageBinding `
            -Service 'admin-api' `
            -ExpectedImageId $script:backendImage.ImageId `
            -ExpectedState running `
            -RequireHealthy
        Assert-BunkFyServiceImageBinding `
            -Service 'web' `
            -ExpectedImageId $webImage.ImageId `
            -ExpectedState running `
            -RequireHealthy)

    & $publicEdgeVerifier `
        -PublicOrigin $publicOrigin `
        -ExpectedReleaseId $releaseId `
        -OutputPath $publicEdgeEvidencePath `
        -AllowLoopbackHttp
    $publicEdgeEvidence = ConvertFrom-Json -InputObject (
        [IO.File]::ReadAllText($publicEdgeEvidencePath))
    if ($publicEdgeEvidence.result -cne 'passed' -or
        $publicEdgeEvidence.releaseId -cne $releaseId -or
        $publicEdgeEvidence.transport -cne 'loopback-http-fixture') {
        throw 'Public-edge evidence does not bind the expected local candidate release.'
    }
    $publicEdgeEvidenceSha256 = (
        Get-FileHash -LiteralPath $publicEdgeEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()

    & $previewIsolation -EnvironmentFile $environmentPath
}
catch {
    $script:failure = $_
}

if ($environmentGenerated -and $stackMayExist) {
    try {
        & $preview down `
            -EnvironmentPath $environmentPath `
            -RemoveVolumes
        $stackRemoved = $true
    }
    catch {
        Add-BunkFyCleanupFailure -CleanupError $_
    }
}
elseif (-not $stackMayExist) {
    $stackRemoved = $true
}

try {
    $remainingResources = [ordered]@{}
    foreach ($resourceType in @('container', 'network', 'volume')) {
        $remainingResources[$resourceType] = @(
            Get-BunkFyProjectResourceIds -ResourceType $resourceType)
    }
    if (@($remainingResources.Values | ForEach-Object { $_ }).Count -ne 0) {
        throw "Candidate Compose project '$projectName' left Docker resources behind."
    }
    $candidateResourcesRemoved = $true
}
catch {
    Add-BunkFyCleanupFailure -CleanupError $_
}

for ($index = $script:loadedReferences.Count - 1; $index -ge 0; $index--) {
    try {
        $reference = $script:loadedReferences[$index]
        $remove = Invoke-BunkFyCandidateDocker -Arguments @(
            'image', 'rm', $reference) -TimeoutSeconds 120
        if ($remove.ExitCode -ne 0 -and
            -not $remove.Output.Contains(
                'No such image',
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Candidate image cleanup failed for '$reference'.`n$($remove.Output)"
        }
    }
    catch {
        Add-BunkFyCleanupFailure -CleanupError $_
    }
}
try {
    foreach ($reference in @($backendReference, $webReference)) {
        $remaining = Invoke-BunkFyCandidateDocker -Arguments @(
            'image', 'inspect', $reference) -TimeoutSeconds 120
        if ($remaining.ExitCode -eq 0) {
            throw "Imported candidate tag '$reference' remains after cleanup."
        }
    }
    $importedImagesRemoved = $true
}
catch {
    Add-BunkFyCleanupFailure -CleanupError $_
}

if ($workingDirectoryCreated) {
    try {
        Remove-Item -LiteralPath $workingDirectory -Recurse -Force
        if (Test-Path -LiteralPath $workingDirectory) {
            throw 'Candidate runtime working directory remains after cleanup.'
        }
        $environmentRemoved = $true
    }
    catch {
        Add-BunkFyCleanupFailure -CleanupError $_
    }
}
else {
    $environmentRemoved = $true
}

if ($null -ne $script:failure) {
    throw $script:failure
}

$outputParent = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    New-BunkFyLocalSensitiveDirectory `
        -Path $outputParent `
        -Description 'Candidate runtime evidence directory'
}
$evidence = [ordered]@{
    schemaVersion = 1
    evidenceKind = 'bunkfy-candidate-preview-runtime-rehearsal'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    repository = 'SadPossum/BunkFy'
    sourceCommit = $ExpectedSourceCommit
    result = 'passed'
    candidate = [ordered]@{
        bundleChecksumsSha256 = $verification[0].BundleChecksumsSha256
        attestationsVerified = $verification[0].AttestationsVerified
        backend = [ordered]@{
            archiveSha256 = $script:backendImage.ArchiveSha256
            manifestDigest = $script:backendImage.ManifestDigest
            imageId = $script:backendImage.ImageId
        }
        web = [ordered]@{
            archiveSha256 = $webImage.ArchiveSha256
            manifestDigest = $webImage.ManifestDigest
            imageId = $webImage.ImageId
        }
    }
    runtime = [ordered]@{
        profile = 'Preview'
        releaseId = $releaseId
        transport = 'loopback-http-fixture'
        composeProject = $projectName
        resolvedImageCount = $resolvedImages.Count
        serviceBindings = $serviceBindings
        publicEdge = [ordered]@{
            result = [string]$publicEdgeEvidence.result
            checkCount = @($publicEdgeEvidence.checks).Count
            checks = @($publicEdgeEvidence.checks | ForEach-Object { [string]$_.name })
            evidenceSha256 = $publicEdgeEvidenceSha256
        }
        managementIsolation = 'passed'
    }
    cleanup = [ordered]@{
        stackRemoved = $stackRemoved
        composeResourcesRemoved = $candidateResourcesRemoved
        generatedEnvironmentRemoved = $environmentRemoved
        importedCandidateTagsRemoved = $importedImagesRemoved
    }
    limitations = @(
        'local-preview-fixture-only',
        'registry-promotion-not-observed',
        'trusted-tls-not-exercised',
        'authenticated-workflows-not-executed',
        'hosted-rollback-not-exercised'
    )
}
Write-BunkFyLocalSensitiveTextFile `
    -Path $resolvedOutputPath `
    -Content (($evidence | ConvertTo-Json -Depth 12) + [Environment]::NewLine) `
    -Description 'Candidate runtime rehearsal evidence'

$result = [pscustomobject]@{
    Repository = 'SadPossum/BunkFy'
    SourceCommit = $ExpectedSourceCommit
    CandidateBundleChecksumsSha256 = $verification[0].BundleChecksumsSha256
    BackendManifestDigest = $script:backendImage.ManifestDigest
    WebManifestDigest = $webImage.ManifestDigest
    AttestationsVerified = $verification[0].AttestationsVerified
    ReleaseId = $releaseId
    RuntimeEvidencePath = $resolvedOutputPath
    ImportedImagesRemoved = $importedImagesRemoved
    ComposeResourcesRemoved = $candidateResourcesRemoved
}
if ($PassThru) {
    return $result
}

Write-Host "Attested candidate Preview runtime rehearsal passed: $resolvedOutputPath"
