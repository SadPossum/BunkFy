[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $BundleDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSourceCommit,

    [switch] $AllowUnattested,

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'image-candidate.common.ps1')

if ($ExpectedSourceCommit -ceq ('0' * 40)) {
    throw 'Expected source commit must not be the all-zero placeholder.'
}
$resolvedBundleDirectory = Resolve-BunkFyCandidatePath `
    -RepositoryRoot $repositoryRoot `
    -Path $BundleDirectory
$closedBundle = Get-BunkFyClosedChecksumSet `
    -Directory $resolvedBundleDirectory `
    -MaximumPayloadBytes 5GB `
    -Context 'OCI candidate bundle'

$bundleManifestPath = Join-Path $resolvedBundleDirectory 'candidate-bundle.json'
$bundleManifest = Read-BunkFyCandidateJson `
    -Path $bundleManifestPath `
    -MaximumBytes 1MB `
    -Context 'OCI candidate bundle manifest'
Assert-BunkFyCandidateProperties `
    -Value $bundleManifest `
    -ExpectedProperties @(
        'schemaVersion',
        'bundleType',
        'generatedAtUtc',
        'repository',
        'sourceCommit',
        'platform',
        'evidenceManifest',
        'images',
        'publication') `
    -Context 'OCI candidate bundle manifest'
Assert-BunkFyCandidateProperties `
    -Value $bundleManifest.publication `
    -ExpectedProperties @(
        'registryPublished',
        'deployableReference',
        'purpose') `
    -Context 'OCI candidate publication record'

$rawManifest = [Text.Json.JsonDocument]::Parse(
    [IO.File]::ReadAllText($bundleManifestPath))
try {
    $generatedAtElement = $rawManifest.RootElement.GetProperty('generatedAtUtc')
    if ($generatedAtElement.ValueKind -ne [Text.Json.JsonValueKind]::String) {
        throw 'OCI candidate bundle has a non-string generation timestamp.'
    }
    $generatedAtText = $generatedAtElement.GetString()
}
finally {
    $rawManifest.Dispose()
}
$generatedAt = [DateTimeOffset]::MinValue
if (-not [DateTimeOffset]::TryParseExact(
        $generatedAtText,
        'O',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$generatedAt) -or
    $generatedAt.Offset -ne [TimeSpan]::Zero) {
    throw 'OCI candidate bundle has an invalid UTC generation timestamp.'
}
if ($generatedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
    throw 'OCI candidate bundle generation timestamp is in the future.'
}
if ($bundleManifest.schemaVersion -ne 1 -or
    $bundleManifest.bundleType -ne 'bunkfy-oci-promotion-candidate' -or
    $bundleManifest.repository -ne 'SadPossum/BunkFy' -or
    $bundleManifest.sourceCommit -cne $ExpectedSourceCommit -or
    $bundleManifest.platform -ne 'linux/amd64' -or
    $bundleManifest.evidenceManifest -ne 'evidence/manifest.json' -or
    $bundleManifest.publication.registryPublished -ne $false -or
    $bundleManifest.publication.deployableReference -ne $false -or
    $bundleManifest.publication.purpose -ne
        'Exact-byte input for an independently approved promotion channel.') {
    throw 'OCI candidate bundle does not match the expected unpublished BunkFy release.'
}

$bundleImages = @($bundleManifest.images)
$bundleImageNames = @($bundleImages.name | Sort-Object -Unique)
if ($bundleImages.Count -ne 2 -or
    ($bundleImageNames -join "`n") -cne "backend`nweb") {
    throw 'OCI candidate bundle must contain exactly backend and web images.'
}
foreach ($image in $bundleImages) {
    Assert-BunkFyCandidateProperties `
        -Value $image `
        -ExpectedProperties @(
            'name',
            'archive',
            'bytes',
            'sha256',
            'manifestDigest') `
        -Context "OCI candidate image '$($image.name)'"
    $expectedArchive = "oci/$($image.name).oci.tar"
    if ($image.archive -cne $expectedArchive -or
        ($image.bytes -isnot [int] -and $image.bytes -isnot [long]) -or
        [long]$image.bytes -le 0 -or
        [long]$image.bytes -gt 2GB -or
        $image.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $image.sha256 -ceq ('0' * 64) -or
        $image.manifestDigest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $image.manifestDigest -ceq ('sha256:' + ('0' * 64))) {
        throw "OCI candidate image '$($image.name)' has invalid archive metadata."
    }
}

$evidenceDirectory = Join-Path $resolvedBundleDirectory 'evidence'
$closedEvidence = Get-BunkFyClosedChecksumSet `
    -Directory $evidenceDirectory `
    -MaximumPayloadBytes 250MB `
    -Context 'Image evidence'
$evidenceManifest = Read-BunkFyCandidateJson `
    -Path (Join-Path $evidenceDirectory 'manifest.json') `
    -MaximumBytes 1MB `
    -Context 'image evidence manifest'
$approvedEvidence = Assert-BunkFyImageEvidenceManifest `
    -Manifest $evidenceManifest
if ($approvedEvidence.SourceCommit -cne $ExpectedSourceCommit) {
    throw 'Image evidence and expected source commit do not match.'
}

$expectedBundleFiles = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
$expectedBundleFiles.Add('candidate-bundle.json') | Out-Null
$expectedBundleFiles.Add('evidence/checksums.sha256') | Out-Null
foreach ($record in $closedEvidence.Files) {
    $expectedBundleFiles.Add("evidence/$($record.RelativePath)") | Out-Null
}
foreach ($image in $bundleImages) {
    $expectedBundleFiles.Add($image.archive) | Out-Null
}
$actualBundleFiles = @($closedBundle.Files.RelativePath | Sort-Object)
$expectedFiles = @($expectedBundleFiles | Sort-Object)
if ($actualBundleFiles.Count -ne $expectedFiles.Count -or
    ($actualBundleFiles -join "`n") -cne ($expectedFiles -join "`n")) {
    throw 'OCI candidate bundle contains files outside its declared contract.'
}

$verifiedImages = [Collections.Generic.List[object]]::new()
foreach ($image in $bundleImages) {
    $archiveRecord = @(
        $closedBundle.Files |
            Where-Object { $_.RelativePath -ceq $image.archive })
    $evidenceImage = @(
        $approvedEvidence.Images |
            Where-Object { $_.name -ceq $image.name })
    if ($archiveRecord.Count -ne 1 -or
        $evidenceImage.Count -ne 1 -or
        $archiveRecord[0].Length -ne [long]$image.bytes -or
        $archiveRecord[0].Sha256 -cne $image.sha256 -or
        $evidenceImage[0].manifestDigest -cne $image.manifestDigest) {
        throw "OCI candidate image '$($image.name)' does not match its closed evidence."
    }
    $archive = Get-BunkFyOciArchiveEvidence `
        -Name $image.name `
        -ArchivePath $archiveRecord[0].FullPath `
        -ExpectedManifestDigest $image.manifestDigest `
        -VerifiedArchiveSha256 $archiveRecord[0].Sha256
    $verifiedImages.Add([pscustomobject]@{
        Name = $archive.Name
        Bytes = $archive.Length
        Sha256 = $archive.Sha256
        ManifestDigest = $archive.ManifestDigest
    })
}

$attestationsVerified = $false
if (-not $AllowUnattested) {
    $github = Get-Command gh -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $attestedFiles = @(
        'candidate-bundle.json',
        'evidence/checksums.sha256',
        'oci/backend.oci.tar',
        'oci/web.oci.tar')
    foreach ($relativePath in $attestedFiles) {
        $attestedPath = Join-Path $resolvedBundleDirectory $relativePath
        $null = @(
            & $github.Source `
                'attestation' `
                'verify' `
                $attestedPath `
                '--repo' `
                'SadPossum/BunkFy' `
                '--signer-workflow' `
                'SadPossum/BunkFy/.github/workflows/image-evidence.yml' `
                '--signer-digest' `
                $ExpectedSourceCommit `
                '--source-digest' `
                $ExpectedSourceCommit `
                '--deny-self-hosted-runners' 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "GitHub attestation verification failed for '$relativePath'."
        }
    }
    $attestationsVerified = $true
}

$result = [pscustomobject]@{
    Repository = 'SadPossum/BunkFy'
    SourceCommit = $ExpectedSourceCommit
    GeneratedAtUtc = $generatedAt.ToUniversalTime()
    BundleChecksumsSha256 = $closedBundle.ChecksumsSha256
    AttestationsVerified = $attestationsVerified
    Images = @($verifiedImages.ToArray())
}
if ($PassThru) {
    return $result
}

Write-Host (
    "Verified unpublished OCI candidate bundle for '$ExpectedSourceCommit'.")
