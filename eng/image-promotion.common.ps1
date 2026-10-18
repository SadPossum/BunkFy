. (Join-Path $PSScriptRoot 'image-candidate.common.ps1')

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

function Test-BunkFyLocalOrFixturePromotionRepository {
    param([Parameter(Mandatory = $true)][string] $Repository)

    $separator = $Repository.IndexOf('/')
    if ($separator -le 0) {
        throw 'Promotion repository must include a registry authority.'
    }

    $registryAuthority = $Repository.Substring(0, $separator)
    $portSeparator = $registryAuthority.LastIndexOf(':')
    $registryHost = if ($portSeparator -gt 0) {
        $registryAuthority.Substring(0, $portSeparator)
    }
    else {
        $registryAuthority
    }

    [Net.IPAddress] $registryAddress = $null
    $isLocalAddress = [Net.IPAddress]::TryParse(
        $registryHost,
        [ref]$registryAddress) -and (
        [Net.IPAddress]::IsLoopback($registryAddress) -or
        $registryAddress.Equals([Net.IPAddress]::Any) -or
        $registryAddress.Equals([Net.IPAddress]::IPv6Any))
    $isLocalName = $registryHost -ceq 'localhost' -or
        $registryHost.EndsWith('.localhost', [StringComparison]::Ordinal)
    $isFixtureRegistry = $registryHost -ceq 'registry.fixture.invalid'

    return $isLocalAddress -or $isLocalName -or $isFixtureRegistry
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

function Get-BunkFyVerifiedImagePromotion {
    param(
        [Parameter(Mandatory = $true)][string] $PromotionDirectory,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
        [string] $ExpectedReleaseId,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9a-f]{40}$')]
        [string] $ExpectedSourceCommit,
        [switch] $AllowFixtureEvidence
    )

    if ($ExpectedSourceCommit -ceq ('0' * 40)) {
        throw 'Expected source commit must not be the all-zero placeholder.'
    }
    $resolvedDirectory = [IO.Path]::GetFullPath($PromotionDirectory)
    $closed = Get-BunkFyClosedChecksumSet `
        -Directory $resolvedDirectory `
        -MaximumPayloadBytes 2MB `
        -Context 'Image promotion evidence'
    if ($closed.Files.Count -ne 1 -or
        $closed.Files[0].RelativePath -cne 'promotion.json') {
        throw 'Image promotion evidence must contain only promotion.json and checksums.sha256.'
    }

    $recordPath = Join-Path $resolvedDirectory 'promotion.json'
    $record = Read-BunkFyCandidateJson `
        -Path $recordPath `
        -MaximumBytes 1MB `
        -Context 'image promotion record'
    Assert-BunkFyCandidateProperties `
        -Value $record `
        -ExpectedProperties @(
            'schemaVersion',
            'evidenceKind',
            'promotionId',
            'promotionEvidenceReference',
            'generatedAtUtc',
            'result',
            'repository',
            'releaseId',
            'sourceCommit',
            'platform',
            'candidate',
            'images',
            'limitations') `
        -Context 'image promotion record'
    Assert-BunkFyCandidateProperties `
        -Value $record.candidate `
        -ExpectedProperties @('bundleChecksumsSha256', 'attestationsVerified') `
        -Context 'image promotion candidate identity'

    $promotionId = [Guid]::Empty
    if ($record.schemaVersion -ne 1 -or
        $record.evidenceKind -cne 'bunkfy-image-promotion' -or
        $record.result -cne 'passed' -or
        $record.repository -cne 'SadPossum/BunkFy' -or
        $record.releaseId -cne $ExpectedReleaseId -or
        $record.sourceCommit -cne $ExpectedSourceCommit -or
        $record.platform -cne 'linux/amd64' -or
        -not [Guid]::TryParseExact(
            [string]$record.promotionId,
            'D',
            [ref]$promotionId) -or
        $promotionId -eq [Guid]::Empty -or
        $record.promotionEvidenceReference -cne
            "promotion:$($promotionId.ToString('N'))" -or
        $record.candidate.bundleChecksumsSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $record.candidate.bundleChecksumsSha256 -ceq ('0' * 64) -or
        $record.candidate.attestationsVerified -isnot [bool]) {
        throw 'Image promotion evidence does not match the expected release identity.'
    }

    $rawRecord = [Text.Json.JsonDocument]::Parse(
        [IO.File]::ReadAllText($recordPath))
    try {
        $generatedAtElement = $rawRecord.RootElement.GetProperty('generatedAtUtc')
        if ($generatedAtElement.ValueKind -ne [Text.Json.JsonValueKind]::String) {
            throw 'Image promotion evidence has a non-string generation timestamp.'
        }
        $generatedAtText = $generatedAtElement.GetString()
    }
    finally {
        $rawRecord.Dispose()
    }
    $generatedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
            $generatedAtText,
            'O',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$generatedAt) -or
        $generatedAt.Offset -ne [TimeSpan]::Zero -or
        $generatedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        throw 'Image promotion evidence has an invalid UTC generation timestamp.'
    }

    $expectedLimitations = @(
        'registry-tag-immutability-policy-not-observed',
        'deployment-not-observed',
        'rollback-not-executed')
    if ((@($record.limitations) -join "`n") -cne
        ($expectedLimitations -join "`n")) {
        throw 'Image promotion evidence has unsupported limitations.'
    }

    $images = @($record.images)
    $imageNames = @($images.name | Sort-Object -Unique)
    if ($images.Count -ne 2 -or
        ($imageNames -join "`n") -cne "backend`nweb") {
        throw 'Image promotion evidence must contain exactly backend and web images.'
    }

    $verifiedImages = [Collections.Generic.List[object]]::new()
    foreach ($image in $images) {
        Assert-BunkFyCandidateProperties `
            -Value $image `
            -ExpectedProperties @(
                'name',
                'sourceArchiveSha256',
                'sourceManifestDigest',
                'tagReference',
                'digestReference',
                'outcome') `
            -Context "image promotion '$($image.name)'"
        $destination = Resolve-BunkFyPromotionDestination `
            -Value ([string]$image.tagReference) `
            -ExpectedTag $ExpectedReleaseId `
            -Name ([string]$image.name)
        if ($image.sourceArchiveSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $image.sourceArchiveSha256 -ceq ('0' * 64) -or
            $image.sourceManifestDigest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            $image.sourceManifestDigest -ceq ('sha256:' + ('0' * 64)) -or
            $image.digestReference -cne
                "$($destination.Repository)@$($image.sourceManifestDigest)" -or
            @('published', 'already-present') -cnotcontains $image.outcome) {
            throw "Image promotion '$($image.name)' has invalid immutable identity."
        }
        $verifiedImages.Add([pscustomobject]@{
            Name = [string]$image.name
            Repository = $destination.Repository
            TagReference = [string]$image.tagReference
            DigestReference = [string]$image.digestReference
            ArchiveSha256 = [string]$image.sourceArchiveSha256
            ManifestDigest = [string]$image.sourceManifestDigest
            Outcome = [string]$image.outcome
        })
    }
    if ($verifiedImages[0].Repository -ceq $verifiedImages[1].Repository) {
        throw 'Image promotion backend and web repositories must be distinct.'
    }

    $localOrFixtureReferences = @($verifiedImages | Where-Object {
            Test-BunkFyLocalOrFixturePromotionRepository `
                -Repository $_.Repository
        })
    if (-not $AllowFixtureEvidence -and
        $localOrFixtureReferences.Count -ne 0) {
        throw 'Hosted image promotion evidence cannot target a fixture or loopback registry.'
    }

    $attestationsVerified = [bool]$record.candidate.attestationsVerified
    if (-not $attestationsVerified) {
        $fixtureReferences = @($verifiedImages | Where-Object {
                -not $_.Repository.StartsWith(
                    'registry.fixture.invalid/',
                    [StringComparison]::Ordinal)
            })
        if (-not $AllowFixtureEvidence -or $fixtureReferences.Count -ne 0) {
            throw 'Image promotion evidence requires attested candidate bytes.'
        }
    }

    return [pscustomobject]@{
        Directory = $resolvedDirectory
        ChecksumsSha256 = $closed.ChecksumsSha256
        PromotionId = $promotionId
        PromotionEvidenceReference = [string]$record.promotionEvidenceReference
        GeneratedAtUtc = $generatedAt.ToUniversalTime()
        ReleaseId = [string]$record.releaseId
        SourceCommit = [string]$record.sourceCommit
        BundleChecksumsSha256 = [string]$record.candidate.bundleChecksumsSha256
        AttestationsVerified = $attestationsVerified
        Images = @($verifiedImages.ToArray())
    }
}
