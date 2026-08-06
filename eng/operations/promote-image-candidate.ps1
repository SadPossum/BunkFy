[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string] $BundleDirectory,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSourceCommit,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ReleaseId,
    [Parameter(Mandatory = $true)][string] $BackendDestination,
    [Parameter(Mandatory = $true)][string] $WebDestination,
    [string] $OutputDirectory,
    [string] $SkopeoPath = 'skopeo',
    [string] $FixtureRegistryDirectory,
    [switch] $AllowUnattested,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot '..\image-candidate.common.ps1')

$root = Get-BunkFyRepositoryRoot
$candidateVerifier = Join-Path $PSScriptRoot '..\verify-image-candidate.ps1'
if ($ExpectedSourceCommit -ceq ('0' * 40)) {
    throw 'Expected source commit must not be the all-zero placeholder.'
}
if ($AllowUnattested -and [string]::IsNullOrWhiteSpace($FixtureRegistryDirectory)) {
    throw 'AllowUnattested is restricted to the local fixture registry mode.'
}
if (-not $AllowUnattested -and -not [string]::IsNullOrWhiteSpace(
        $FixtureRegistryDirectory)) {
    throw 'Fixture registry mode requires AllowUnattested.'
}

function Resolve-BunkFyPromotionDestination {
    param(
        [Parameter(Mandatory = $true)][string] $Value,
        [Parameter(Mandatory = $true)][string] $ExpectedTag,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($Value.Length -gt 512 -or
        $Value -cne $Value.Trim() -or
        $Value -match '[\s\\@?#]' -or
        $Value.Contains('://', [StringComparison]::Ordinal)) {
        throw "$Name destination must be a credential-free tagged OCI registry reference."
    }
    $lastSlash = $Value.LastIndexOf('/')
    $lastColon = $Value.LastIndexOf(':')
    if ($lastSlash -lt 1 -or $lastColon -le $lastSlash) {
        throw "$Name destination must include a registry, repository, and tag."
    }

    $repository = $Value.Substring(0, $lastColon)
    $tag = $Value.Substring($lastColon + 1)
    if ($tag -cne $ExpectedTag -or
        $repository -cnotmatch
            '^(?:localhost|[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?)(?::[0-9]{1,5})?/[a-z0-9]+(?:[._/-][a-z0-9]+)*$') {
        throw "$Name destination must use the exact release id as its tag and a lowercase OCI repository."
    }

    return [pscustomobject]@{
        TagReference = $Value
        Repository = $repository
    }
}

function Assert-BunkFyDisjointPromotionPaths {
    param(
        [Parameter(Mandatory = $true)][string] $LeftPath,
        [Parameter(Mandatory = $true)][string] $LeftName,
        [Parameter(Mandatory = $true)][string] $RightPath,
        [Parameter(Mandatory = $true)][string] $RightName
    )

    $separator = [IO.Path]::DirectorySeparatorChar
    $comparison = [StringComparison]::OrdinalIgnoreCase
    $left = [IO.Path]::GetFullPath($LeftPath).TrimEnd('\', '/')
    $right = [IO.Path]::GetFullPath($RightPath).TrimEnd('\', '/')
    $leftPrefix = $left + $separator
    $rightPrefix = $right + $separator
    if ($left.Equals($right, $comparison) -or
        $left.StartsWith($rightPrefix, $comparison) -or
        $right.StartsWith($leftPrefix, $comparison)) {
        throw "$LeftName and $RightName must not overlap."
    }
}

function Invoke-BunkFySkopeo {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [switch] $AllowFailure
    )

    $output = @(& $script:Skopeo.Source @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw 'Skopeo failed while publishing or verifying the candidate image.'
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { [string]$_ })
    }
}

function Get-BunkFyRemoteImageDigest {
    param([Parameter(Mandatory = $true)][string] $Destination)

    $result = Invoke-BunkFySkopeo `
        -Arguments @('inspect', '--format', '{{.Digest}}', "docker://$Destination") `
        -AllowFailure
    if ($result.ExitCode -ne 0) {
        return $null
    }
    $digests = @(
        $result.Output |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -cmatch '^sha256:[0-9a-f]{64}$' })
    if ($digests.Count -ne 1) {
        throw 'Skopeo returned an ambiguous registry digest.'
    }
    return $digests[0]
}

function Publish-BunkFyCandidateImage {
    param(
        [Parameter(Mandatory = $true)][object] $Image,
        [Parameter(Mandatory = $true)][object] $Destination
    )

    $archivePath = Join-Path $resolvedBundleDirectory "oci/$($Image.Name).oci.tar"
    $outcome = 'published'
    if ($fixtureMode) {
        [IO.Directory]::CreateDirectory($resolvedFixtureRegistry) | Out-Null
        $fixturePath = Join-Path $resolvedFixtureRegistry "$($Image.Name).oci.tar"
        if ([IO.File]::Exists($fixturePath)) {
            $existingHash = (
                Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            if ($existingHash -cne $Image.Sha256) {
                throw "Fixture registry already contains different '$($Image.Name)' bytes."
            }
            $outcome = 'already-present'
        }
        else {
            [IO.File]::Copy($archivePath, $fixturePath, $false)
            $copiedHash = (
                Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            if ($copiedHash -cne $Image.Sha256) {
                throw "Fixture registry copy for '$($Image.Name)' failed its SHA-256 check."
            }
        }
    }
    else {
        $existingDigest = Get-BunkFyRemoteImageDigest `
            -Destination $Destination.TagReference
        if ($null -ne $existingDigest) {
            if ($existingDigest -cne $Image.ManifestDigest) {
                throw "Registry tag '$($Destination.TagReference)' already points to different bytes."
            }
            $outcome = 'already-present'
        }
        else {
            $digestFile = Join-Path ([IO.Path]::GetTempPath()) (
                "bunkfy-promotion-$($Image.Name)-$([Guid]::NewGuid().ToString('N')).digest")
            try {
                [void](Invoke-BunkFySkopeo -Arguments @(
                        'copy',
                        '--preserve-digests',
                        '--retry-times', '3',
                        '--digestfile', $digestFile,
                        "oci-archive:$archivePath",
                        "docker://$($Destination.TagReference)"))
                if (-not [IO.File]::Exists($digestFile)) {
                    throw 'Skopeo did not write the resulting image digest.'
                }
                $copiedDigest = [IO.File]::ReadAllText($digestFile).Trim()
                if ($copiedDigest -cne $Image.ManifestDigest) {
                    throw "Published '$($Image.Name)' digest does not match the candidate."
                }
            }
            finally {
                [IO.File]::Delete($digestFile)
            }
        }

        $remoteDigest = Get-BunkFyRemoteImageDigest `
            -Destination $Destination.TagReference
        if ($remoteDigest -cne $Image.ManifestDigest) {
            throw "Registry verification for '$($Image.Name)' did not return the candidate digest."
        }
    }

    return [ordered]@{
        name = $Image.Name
        sourceArchiveSha256 = $Image.Sha256
        sourceManifestDigest = $Image.ManifestDigest
        tagReference = $Destination.TagReference
        digestReference = "$($Destination.Repository)@$($Image.ManifestDigest)"
        outcome = $outcome
    }
}

$backendTarget = Resolve-BunkFyPromotionDestination `
    -Value $BackendDestination `
    -ExpectedTag $ReleaseId `
    -Name 'Backend'
$webTarget = Resolve-BunkFyPromotionDestination `
    -Value $WebDestination `
    -ExpectedTag $ReleaseId `
    -Name 'Web'
if ($backendTarget.Repository -ceq $webTarget.Repository) {
    throw 'Backend and web must publish to distinct OCI repositories.'
}

$resolvedBundleDirectory = Resolve-BunkFyCandidatePath `
    -RepositoryRoot $root `
    -Path $BundleDirectory
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = ".tmp/promotions/$ReleaseId"
}
$resolvedOutputDirectory = Resolve-BunkFyCandidatePath `
    -RepositoryRoot $root `
    -Path $OutputDirectory
Assert-BunkFyDisjointPromotionPaths `
    -LeftPath $resolvedBundleDirectory `
    -LeftName 'Candidate bundle' `
    -RightPath $resolvedOutputDirectory `
    -RightName 'promotion evidence output'
if ([IO.Directory]::Exists($resolvedOutputDirectory) -or
    [IO.File]::Exists($resolvedOutputDirectory)) {
    throw "Promotion evidence already exists: '$resolvedOutputDirectory'."
}

$fixtureMode = -not [string]::IsNullOrWhiteSpace($FixtureRegistryDirectory)
$resolvedFixtureRegistry = $null
if ($fixtureMode) {
    $resolvedFixtureRegistry = Resolve-BunkFyCandidatePath `
        -RepositoryRoot $root `
        -Path $FixtureRegistryDirectory
    Assert-BunkFyDisjointPromotionPaths `
        -LeftPath $resolvedBundleDirectory `
        -LeftName 'Candidate bundle' `
        -RightPath $resolvedFixtureRegistry `
        -RightName 'fixture registry'
    Assert-BunkFyDisjointPromotionPaths `
        -LeftPath $resolvedOutputDirectory `
        -LeftName 'Promotion evidence output' `
        -RightPath $resolvedFixtureRegistry `
        -RightName 'fixture registry'
    foreach ($destination in @($backendTarget, $webTarget)) {
        if (-not $destination.Repository.StartsWith(
                'registry.fixture.invalid/',
                [StringComparison]::Ordinal)) {
            throw 'Fixture registry mode only accepts registry.fixture.invalid destinations.'
        }
    }
}
else {
    $script:Skopeo = Get-Command $SkopeoPath -CommandType Application `
        -ErrorAction Stop | Select-Object -First 1
}

$verificationArguments = @{
    BundleDirectory = $resolvedBundleDirectory
    ExpectedSourceCommit = $ExpectedSourceCommit
    PassThru = $true
}
if ($AllowUnattested) {
    $verificationArguments.AllowUnattested = $true
}
$candidate = & $candidateVerifier @verificationArguments
if (-not $fixtureMode -and -not $candidate.AttestationsVerified) {
    throw 'Registry promotion requires verified candidate attestations.'
}

if (-not $PSCmdlet.ShouldProcess(
        "$BackendDestination and $WebDestination",
        "Publish exact BunkFy candidate bytes for release '$ReleaseId'")) {
    return
}

$publishedImages = [Collections.Generic.List[object]]::new()
foreach ($entry in @(
        @{ Name = 'backend'; Target = $backendTarget },
        @{ Name = 'web'; Target = $webTarget })) {
    $image = @($candidate.Images | Where-Object { $_.Name -ceq $entry.Name })
    if ($image.Count -ne 1) {
        throw "Verified candidate is missing '$($entry.Name)'."
    }
    $publishedImages.Add((Publish-BunkFyCandidateImage `
            -Image $image[0] `
            -Destination $entry.Target))
}

$promotionId = [Guid]::NewGuid()
$promotionReference = "promotion:$($promotionId.ToString('N'))"
$record = [ordered]@{
    schemaVersion = 1
    evidenceKind = 'bunkfy-image-promotion'
    promotionId = $promotionId.ToString('D')
    promotionEvidenceReference = $promotionReference
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    result = 'passed'
    repository = 'SadPossum/BunkFy'
    releaseId = $ReleaseId
    sourceCommit = $candidate.SourceCommit
    platform = 'linux/amd64'
    candidate = [ordered]@{
        bundleChecksumsSha256 = $candidate.BundleChecksumsSha256
        attestationsVerified = [bool]$candidate.AttestationsVerified
    }
    images = @($publishedImages)
    limitations = @(
        'registry-tag-immutability-policy-not-observed',
        'deployment-not-observed',
        'rollback-not-executed'
    )
}

$stagingDirectory = "$resolvedOutputDirectory.tmp-$([Guid]::NewGuid().ToString('N'))"
try {
    [IO.Directory]::CreateDirectory($stagingDirectory) | Out-Null
    $recordPath = Join-Path $stagingDirectory 'promotion.json'
    Write-BunkFyCandidateJson -Path $recordPath -Value $record
    $recordHash = (
        Get-FileHash -LiteralPath $recordPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $stagingDirectory 'checksums.sha256'),
        "$recordHash  promotion.json`n",
        [Text.UTF8Encoding]::new($false))
    [IO.Directory]::CreateDirectory((Split-Path -Parent $resolvedOutputDirectory)) |
        Out-Null
    [IO.Directory]::Move($stagingDirectory, $resolvedOutputDirectory)
}
finally {
    if ([IO.Directory]::Exists($stagingDirectory)) {
        [IO.Directory]::Delete($stagingDirectory, $true)
    }
}

if ($PassThru) {
    return [pscustomobject]$record
}
Write-Host "BunkFy candidate '$ReleaseId' published with immutable digest references."
Write-Host "Promotion evidence: $resolvedOutputDirectory"
Write-Host "Production admission reference: $promotionReference"
