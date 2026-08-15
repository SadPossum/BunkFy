[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $BundleDirectory,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSourceCommit,
    [string] $PostgreSqlImage = 'postgres:17.5-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa',
    [string] $OutputPath,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path $PSScriptRoot '..\common.ps1')

$repositoryRoot = Get-BunkFyRepositoryRoot
$candidateVerifier = Join-Path $PSScriptRoot '..\verify-image-candidate.ps1'
$migrationRehearsal = Join-Path $PSScriptRoot 'rehearse-production-migrations.ps1'
if ($ExpectedSourceCommit -ceq ('0' * 40)) {
    throw 'ExpectedSourceCommit must not be the all-zero placeholder.'
}

$resolvedBundleDirectory = if ([IO.Path]::IsPathRooted($BundleDirectory)) {
    [IO.Path]::GetFullPath($BundleDirectory)
}
else {
    [IO.Path]::GetFullPath((Join-Path $repositoryRoot $BundleDirectory))
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $nonce = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $OutputPath = Join-BunkFyPath (
        ".tmp\migration-rehearsals\$stamp-candidate-$($ExpectedSourceCommit.Substring(0, 12))-$nonce.json")
}
$resolvedOutputPath = if ([IO.Path]::IsPathRooted($OutputPath)) {
    [IO.Path]::GetFullPath($OutputPath)
}
else {
    [IO.Path]::GetFullPath((Join-Path $repositoryRoot $OutputPath))
}
if ([IO.File]::Exists($resolvedOutputPath)) {
    throw "Migration rehearsal evidence already exists: '$resolvedOutputPath'."
}

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
        throw "Docker exceeded the $TimeoutSeconds second candidate-image budget."
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

$verification = @(& $candidateVerifier `
        -BundleDirectory $resolvedBundleDirectory `
        -ExpectedSourceCommit $ExpectedSourceCommit `
        -PassThru)
if ($verification.Count -ne 1 -or -not $verification[0].AttestationsVerified) {
    throw 'The OCI candidate bundle did not produce one attested verification result.'
}
$backendCandidate = @(
    $verification[0].Images |
        Where-Object { $_.Name -ceq 'backend' })
if ($backendCandidate.Count -ne 1) {
    throw 'The OCI candidate bundle does not contain exactly one backend image.'
}
$backendCandidate = $backendCandidate[0]
$backendArchive = Join-Path $resolvedBundleDirectory 'oci\backend.oci.tar'
$backendReference = "bunkfy/backend:candidate-$ExpectedSourceCommit"
$expectedRepositoryDigest = "bunkfy/backend@$($backendCandidate.ManifestDigest)"
$loadAttempted = $false
$failure = $null
$evidence = $null
$loadedImageId = $null

try {
    $existing = Invoke-BunkFyCandidateDocker -Arguments @(
        'image', 'inspect', $backendReference)
    if ($existing.ExitCode -eq 0) {
        throw "Candidate image '$backendReference' already exists locally; refusing to replace it."
    }

    Write-Host "Loading attested backend candidate '$ExpectedSourceCommit'."
    $loadAttempted = $true
    $load = Invoke-BunkFyCandidateDocker -Arguments @(
        'image', 'load', '--input', $backendArchive)
    Assert-BunkFyCandidateDockerSuccess -Result $load -Context 'Loading the backend OCI candidate'
    if (-not $load.Output.Contains(
            "Loaded image: $backendReference",
            [StringComparison]::Ordinal)) {
        throw 'Docker did not report the expected candidate image reference.'
    }

    $inspect = Invoke-BunkFyCandidateDocker -Arguments @(
        'image', 'inspect', $backendReference)
    Assert-BunkFyCandidateDockerSuccess -Result $inspect -Context 'Inspecting the loaded backend candidate'
    $records = @(ConvertFrom-Json -InputObject $inspect.Output)
    if ($records.Count -ne 1) {
        throw 'The loaded backend candidate did not resolve to exactly one image.'
    }
    $repositoryDigests = @(
        $records[0].RepoDigests |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique)
    $repositoryTags = @(
        $records[0].RepoTags |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique)
    $loadedImageId = [string]$records[0].Id
    if ($loadedImageId -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $repositoryDigests.Count -ne 1 -or
        $repositoryDigests[0] -cne $expectedRepositoryDigest -or
        $repositoryTags.Count -ne 1 -or
        $repositoryTags[0] -cne $backendReference) {
        throw 'The loaded backend image identity does not match the attested candidate manifest.'
    }

    & $migrationRehearsal `
        -BackendImage $backendReference `
        -PostgreSqlImage $PostgreSqlImage `
        -SourceCommitSha $ExpectedSourceCommit `
        -OutputPath $resolvedOutputPath

    if (-not [IO.File]::Exists($resolvedOutputPath)) {
        throw 'The migration rehearsal did not retain its minimized evidence.'
    }
    $evidence = ConvertFrom-Json -InputObject (
        [IO.File]::ReadAllText($resolvedOutputPath))
    if ($evidence.sourceCommitSha -cne $ExpectedSourceCommit -or
        $evidence.images.backend.reference -cne $backendReference -or
        $evidence.images.backend.imageId -cne $loadedImageId -or
        $evidence.images.backend.repositoryDigest -cne $backendCandidate.ManifestDigest -or
        $evidence.isolation.resourcesRemoved -ne $true) {
        throw 'Migration evidence does not bind the cleaned rehearsal to the attested candidate.'
    }
}
catch {
    $failure = $_
}

if ($loadAttempted) {
    $remove = Invoke-BunkFyCandidateDocker -Arguments @(
        'image', 'rm', $backendReference) -TimeoutSeconds 120
    if ($remove.ExitCode -ne 0 -and
        -not $remove.Output.Contains('No such image', [StringComparison]::OrdinalIgnoreCase)) {
        $cleanupMessage = "Candidate image cleanup failed.`n$($remove.Output)"
        if ($null -eq $failure) {
            $failure = [InvalidOperationException]::new($cleanupMessage)
        }
        else {
            $failure = [InvalidOperationException]::new(
                "$($failure.Exception.Message) $cleanupMessage",
                $failure.Exception)
        }
    }
}
if ($null -ne $failure) {
    throw $failure
}

$result = [pscustomobject]@{
    Repository = 'SadPossum/BunkFy'
    SourceCommit = $ExpectedSourceCommit
    CandidateBundleChecksumsSha256 = $verification[0].BundleChecksumsSha256
    BackendArchiveSha256 = $backendCandidate.Sha256
    BackendManifestDigest = $backendCandidate.ManifestDigest
    BackendImageId = $loadedImageId
    AttestationsVerified = $verification[0].AttestationsVerified
    MigrationEvidencePath = $resolvedOutputPath
    MigrationRunId = [string]$evidence.runId
    ImportedImageRemoved = $true
}
if ($PassThru) {
    return $result
}

Write-Host (
    "Attested candidate Production migration rehearsal passed: $resolvedOutputPath")
