[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)][string] $CandidatePromotionDirectory,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $CandidateReleaseId,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $CandidateSourceCommit,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^admission:[0-9a-f]{32}$')]
    [string] $AdmissionEvidenceReference,
    [Parameter(Mandatory = $true)][string] $RollbackPromotionDirectory,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $RollbackReleaseId,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $RollbackSourceCommit,
    [string] $OutputDirectory,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [ValidateRange(1, 7200)][int] $TransitionTimeoutSeconds = 900,
    [ValidateRange(250, 30000)][int] $PollIntervalMilliseconds = 5000,
    [switch] $AllowLoopbackHttp,
    [switch] $AllowFixtureEvidence,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot '..\image-promotion.common.ps1')
. (Join-Path $PSScriptRoot 'deployed-public-edge.common.ps1')

$root = Get-BunkFyRepositoryRoot
$publicProbeScript = Join-Path $PSScriptRoot 'verify-deployed-public-edge.ps1'
$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackHttp
if ($AllowFixtureEvidence -and
    (-not $AllowLoopbackHttp -or
     -not (Test-BunkFyLoopbackHost -HostName $origin.Host))) {
    throw 'Fixture promotion evidence is restricted to an explicit loopback rehearsal.'
}
$admissionId = [Guid]::Empty
if (-not [Guid]::TryParseExact(
        $AdmissionEvidenceReference.Substring(10),
        'N',
        [ref]$admissionId) -or
    $admissionId -eq [Guid]::Empty) {
    throw 'AdmissionEvidenceReference must contain a non-empty admission identity.'
}

$candidatePromotion = Get-BunkFyVerifiedImagePromotion `
    -PromotionDirectory $CandidatePromotionDirectory `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedSourceCommit $CandidateSourceCommit `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$rollbackPromotion = Get-BunkFyVerifiedImagePromotion `
    -PromotionDirectory $RollbackPromotionDirectory `
    -ExpectedReleaseId $RollbackReleaseId `
    -ExpectedSourceCommit $RollbackSourceCommit `
    -AllowFixtureEvidence:$AllowFixtureEvidence

if ($candidatePromotion.ReleaseId -ceq $rollbackPromotion.ReleaseId -or
    $candidatePromotion.SourceCommit -ceq $rollbackPromotion.SourceCommit -or
    $candidatePromotion.PromotionEvidenceReference -ceq
        $rollbackPromotion.PromotionEvidenceReference) {
    throw 'Candidate and rollback promotions must identify distinct releases.'
}
$differentImageCount = 0
foreach ($name in @('backend', 'web')) {
    $candidateImage = @($candidatePromotion.Images | Where-Object { $_.Name -ceq $name })
    $rollbackImage = @($rollbackPromotion.Images | Where-Object { $_.Name -ceq $name })
    if ($candidateImage.Count -ne 1 -or $rollbackImage.Count -ne 1 -or
        $candidateImage[0].Repository -cne $rollbackImage[0].Repository) {
        throw "Candidate and rollback promotions do not use the same '$name' repository."
    }
    if ($candidateImage[0].ManifestDigest -cne $rollbackImage[0].ManifestDigest) {
        $differentImageCount++
    }
}
if ($differentImageCount -eq 0) {
    throw 'Candidate and rollback promotions resolve to the same image digests.'
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputDirectory = Join-BunkFyPath (
        ".tmp/rollback-rehearsals/$stamp-$([Guid]::NewGuid().ToString('N'))")
}
$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory, $root)
Assert-BunkFyDisjointPromotionPaths `
    -LeftPath $candidatePromotion.Directory `
    -LeftName 'Candidate promotion evidence' `
    -RightPath $resolvedOutputDirectory `
    -RightName 'rollback rehearsal output'
Assert-BunkFyDisjointPromotionPaths `
    -LeftPath $rollbackPromotion.Directory `
    -LeftName 'Rollback promotion evidence' `
    -RightPath $resolvedOutputDirectory `
    -RightName 'rollback rehearsal output'
if ([IO.Directory]::Exists($resolvedOutputDirectory) -or
    [IO.File]::Exists($resolvedOutputDirectory)) {
    throw "Rollback rehearsal output already exists: '$resolvedOutputDirectory'."
}

function Invoke-BunkFyRollbackPublicProbe {
    param(
        [Parameter(Mandatory = $true)][string] $ExpectedReleaseId,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $arguments = @{
        PublicOrigin = $origin
        ExpectedReleaseId = $ExpectedReleaseId
        OutputPath = $OutputPath
        TimeoutSeconds = $RequestTimeoutSeconds
    }
    if ($AllowLoopbackHttp) {
        $arguments.AllowLoopbackHttp = $true
    }
    & $publicProbeScript @arguments
}

function Assert-BunkFyRollbackProbeAdmissionIdentity {
    param([Parameter(Mandatory = $true)][string] $Path)

    try {
        $record = Get-Content -LiteralPath $Path -Raw |
            ConvertFrom-Json -Depth 8
    }
    catch {
        throw "Rollback public-edge evidence '$Path' is not valid JSON."
    }
    if ([string]$record.admissionEvidenceReference -cne
        $AdmissionEvidenceReference) {
        throw 'The deployed admission evidence reference changed during rollback rehearsal.'
    }
}

function Wait-BunkFyComposedRelease {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory = $true)][string] $ExpectedReleaseId,
        [Parameter(Mandatory = $true)][string] $Stage
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TransitionTimeoutSeconds)
    $lastObserved = $null
    $observedAdmissionEvidenceReference = $AdmissionEvidenceReference
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $observed = Get-BunkFyObservedComposedReleaseId `
            -Client $Client `
            -Origin $origin `
            -TimeoutSeconds $RequestTimeoutSeconds `
            -ObservedAdmissionEvidenceReference ([ref]$observedAdmissionEvidenceReference)
        if ($null -ne $observed -and $observed -cne $lastObserved) {
            Write-Host "Observed composed release '$observed' while waiting for $Stage."
            $lastObserved = $observed
        }
        if ($observed -ceq $ExpectedReleaseId) {
            return [DateTimeOffset]::UtcNow
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }

    $lastText = if ($null -eq $lastObserved) { 'none' } else { $lastObserved }
    throw "Timed out waiting for $Stage release '$ExpectedReleaseId'; last converged release was '$lastText'."
}

function ConvertTo-BunkFyRollbackPromotionIdentity {
    param([Parameter(Mandatory = $true)][object] $Promotion)

    return [ordered]@{
        releaseId = $Promotion.ReleaseId
        sourceCommit = $Promotion.SourceCommit
        promotionEvidenceReference = $Promotion.PromotionEvidenceReference
        promotionChecksumsSha256 = $Promotion.ChecksumsSha256
        images = @(
            $Promotion.Images |
                Sort-Object Name |
                ForEach-Object {
                    [ordered]@{
                        name = $_.Name
                        digestReference = $_.DigestReference
                    }
                })
    }
}

$rehearsalId = [Guid]::NewGuid()
$rollbackEvidenceReference = "rollback:$($rehearsalId.ToString('N'))"
$stagingDirectory = "$resolvedOutputDirectory.tmp-$([Guid]::NewGuid().ToString('N'))"
$startedAtUtc = [DateTimeOffset]::UtcNow
$client = $null
try {
    [IO.Directory]::CreateDirectory($stagingDirectory) | Out-Null
    $baselinePath = Join-Path $stagingDirectory 'candidate-baseline-public-edge.json'
    $rollbackPath = Join-Path $stagingDirectory 'rollback-public-edge.json'
    $restoredPath = Join-Path $stagingDirectory 'candidate-restored-public-edge.json'

    Write-Host "Verifying candidate release '$CandidateReleaseId' before rollback."
    Invoke-BunkFyRollbackPublicProbe `
        -ExpectedReleaseId $CandidateReleaseId `
        -OutputPath $baselinePath
    Assert-BunkFyRollbackProbeAdmissionIdentity -Path $baselinePath
    $baselineVerifiedAtUtc = [DateTimeOffset]::UtcNow

    $client = New-BunkFyPublicEdgeHttpClient `
        -UserAgent 'BunkFy-Deployed-Rollback-Rehearsal/1'
    Write-Host (
        "Deploy rollback digest references for '$RollbackReleaseId' now; " +
        'the rehearsal is waiting for web and API convergence.')
    $rollbackObservedAtUtc = Wait-BunkFyComposedRelease `
        -Client $client `
        -ExpectedReleaseId $RollbackReleaseId `
        -Stage 'rollback'
    Invoke-BunkFyRollbackPublicProbe `
        -ExpectedReleaseId $RollbackReleaseId `
        -OutputPath $rollbackPath
    Assert-BunkFyRollbackProbeAdmissionIdentity -Path $rollbackPath
    $rollbackVerifiedAtUtc = [DateTimeOffset]::UtcNow

    Write-Host (
        "Restore candidate digest references for '$CandidateReleaseId' now; " +
        'the rehearsal is waiting for web and API convergence.')
    $restoredObservedAtUtc = Wait-BunkFyComposedRelease `
        -Client $client `
        -ExpectedReleaseId $CandidateReleaseId `
        -Stage 'candidate restoration'
    Invoke-BunkFyRollbackPublicProbe `
        -ExpectedReleaseId $CandidateReleaseId `
        -OutputPath $restoredPath
    Assert-BunkFyRollbackProbeAdmissionIdentity -Path $restoredPath
    $completedAtUtc = [DateTimeOffset]::UtcNow

    $checks = @(
        [ordered]@{
            name = 'candidate-baseline-public-edge'
            result = 'passed'
            releaseId = $CandidateReleaseId
            evidenceFile = 'candidate-baseline-public-edge.json'
            evidenceSha256 = (Get-FileHash $baselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
        },
        [ordered]@{
            name = 'rollback-public-edge'
            result = 'passed'
            releaseId = $RollbackReleaseId
            evidenceFile = 'rollback-public-edge.json'
            evidenceSha256 = (Get-FileHash $rollbackPath -Algorithm SHA256).Hash.ToLowerInvariant()
        },
        [ordered]@{
            name = 'candidate-restored-public-edge'
            result = 'passed'
            releaseId = $CandidateReleaseId
            evidenceFile = 'candidate-restored-public-edge.json'
            evidenceSha256 = (Get-FileHash $restoredPath -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    $record = [ordered]@{
        schemaVersion = 2
        evidenceKind = 'bunkfy-deployed-release-rollback-rehearsal'
        rehearsalId = $rehearsalId.ToString('D')
        rollbackEvidenceReference = $rollbackEvidenceReference
        admissionEvidenceReference = $AdmissionEvidenceReference
        generatedAtUtc = $completedAtUtc.ToString('O')
        result = 'passed'
        origin = $origin.GetLeftPart([UriPartial]::Authority)
        candidate = ConvertTo-BunkFyRollbackPromotionIdentity $candidatePromotion
        rollback = ConvertTo-BunkFyRollbackPromotionIdentity $rollbackPromotion
        timing = [ordered]@{
            startedAtUtc = $startedAtUtc.ToString('O')
            baselineVerifiedAtUtc = $baselineVerifiedAtUtc.ToString('O')
            rollbackObservedAtUtc = $rollbackObservedAtUtc.ToString('O')
            rollbackVerifiedAtUtc = $rollbackVerifiedAtUtc.ToString('O')
            candidateRestoredObservedAtUtc = $restoredObservedAtUtc.ToString('O')
            completedAtUtc = $completedAtUtc.ToString('O')
            rollbackConvergenceMilliseconds = [long](
                $rollbackObservedAtUtc - $baselineVerifiedAtUtc).TotalMilliseconds
            restorationConvergenceMilliseconds = [long](
                $restoredObservedAtUtc - $rollbackVerifiedAtUtc).TotalMilliseconds
            totalDurationMilliseconds = [long](
                $completedAtUtc - $startedAtUtc).TotalMilliseconds
        }
        checks = $checks
        limitations = @(
            'deployment-control-plane-and-commands-not-observed',
            'worker-and-admin-release-identities-not-observed',
            'public-smoke-does-not-prove-all-schema-and-domain-compatibility',
            'registry-availability-and-immutability-not-reverified',
            'hosted-approval-alerting-and-traffic-drain-not-observed')
    }
    $recordPath = Join-Path $stagingDirectory 'rollback-rehearsal.json'
    Write-BunkFyCandidateJson -Path $recordPath -Value $record
    $checksumsPath = Join-Path $stagingDirectory 'checksums.sha256'
    $checksumLines = @(
        Get-ChildItem -LiteralPath $stagingDirectory -File |
            Sort-Object Name |
            ForEach-Object {
                $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                "$hash  $($_.Name)"
            })
    [IO.File]::WriteAllText(
        $checksumsPath,
        (($checksumLines -join "`n").TrimEnd() + "`n"),
        [Text.UTF8Encoding]::new($false))
    $closed = Get-BunkFyClosedChecksumSet `
        -Directory $stagingDirectory `
        -MaximumPayloadBytes 4MB `
        -Context 'Rollback rehearsal evidence'
    if ($closed.Files.Count -ne 4) {
        throw 'Rollback rehearsal evidence did not close the expected file set.'
    }

    [IO.Directory]::CreateDirectory((Split-Path -Parent $resolvedOutputDirectory)) |
        Out-Null
    [IO.Directory]::Move($stagingDirectory, $resolvedOutputDirectory)
}
finally {
    if ($null -ne $client) {
        $client.Dispose()
    }
    if ([IO.Directory]::Exists($stagingDirectory)) {
        [IO.Directory]::Delete($stagingDirectory, $true)
    }
}

if ($PassThru) {
    return [pscustomobject]$record
}
Write-Host "BunkFy deployed release rollback rehearsal passed."
Write-Host "Evidence: $resolvedOutputDirectory"
Write-Host "Production admission reference: $rollbackEvidenceReference"
