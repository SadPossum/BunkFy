[CmdletBinding()]
param([string] $RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$packager = Join-Path $root 'eng/package-image-candidate.ps1'
if (-not [IO.File]::Exists($packager)) {
    throw "Missing image candidate packager '$packager'."
}
$verifier = Join-Path $root 'eng/verify-image-candidate.ps1'
if (-not [IO.File]::Exists($verifier)) {
    throw "Missing image candidate verifier '$verifier'."
}
$promoter = Join-Path $root 'eng/operations/promote-image-candidate.ps1'
if (-not [IO.File]::Exists($promoter)) {
    throw "Missing image candidate promoter '$promoter'."
}
$promotionVerifier = Join-Path $root 'eng/verify-image-promotion.ps1'
if (-not [IO.File]::Exists($promotionVerifier)) {
    throw "Missing image promotion verifier '$promotionVerifier'."
}

function Write-TestJson {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][object] $Value
    )

    $json = $Value | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText(
        $Path,
        ($json.Replace("`r`n", "`n").TrimEnd() + "`n"),
        [Text.UTF8Encoding]::new($false))
}

function Get-TestSha256 {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)

    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Add-TestTarEntry {
    param(
        [Parameter(Mandatory = $true)][Formats.Tar.TarWriter] $Writer,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][byte[]] $Bytes
    )

    $data = [IO.MemoryStream]::new($Bytes, $false)
    try {
        $entry = [Formats.Tar.PaxTarEntry]::new(
            [Formats.Tar.TarEntryType]::RegularFile,
            $Name)
        $entry.DataStream = $data
        $Writer.WriteEntry($entry)
    }
    finally {
        $data.Dispose()
    }
}

function New-TestOciArchive {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $IncludeAdditionalDescriptor
    )

    $encoding = [Text.UTF8Encoding]::new($false)
    $configBytes = $encoding.GetBytes('{}')
    $configHash = Get-TestSha256 -Bytes $configBytes
    $manifest = [ordered]@{
        schemaVersion = 2
        mediaType = 'application/vnd.oci.image.manifest.v1+json'
        config = [ordered]@{
            mediaType = 'application/vnd.oci.image.config.v1+json'
            digest = "sha256:$configHash"
            size = $configBytes.Length
        }
        layers = @()
    }
    $manifestBytes = $encoding.GetBytes(
        (($manifest | ConvertTo-Json -Depth 8 -Compress) + "`n"))
    $manifestHash = Get-TestSha256 -Bytes $manifestBytes
    $descriptors = @(
        [ordered]@{
            mediaType = 'application/vnd.oci.image.manifest.v1+json'
            digest = "sha256:$manifestHash"
            size = $manifestBytes.Length
            platform = [ordered]@{
                architecture = 'amd64'
                os = 'linux'
            }
        })
    $additionalManifestBytes = $null
    $additionalManifestHash = $null
    if ($IncludeAdditionalDescriptor) {
        $additionalManifest = [ordered]@{
            schemaVersion = 2
            mediaType = 'application/vnd.oci.image.manifest.v1+json'
            config = $manifest.config
            layers = @()
            annotations = [ordered]@{ 'fixture.kind' = 'unexpected' }
        }
        $additionalManifestBytes = $encoding.GetBytes(
            (($additionalManifest | ConvertTo-Json -Depth 8 -Compress) + "`n"))
        $additionalManifestHash = Get-TestSha256 -Bytes $additionalManifestBytes
        $descriptors += [ordered]@{
            mediaType = 'application/vnd.oci.image.manifest.v1+json'
            digest = "sha256:$additionalManifestHash"
            size = $additionalManifestBytes.Length
            platform = [ordered]@{
                architecture = 'amd64'
                os = 'linux'
            }
        }
    }
    $index = [ordered]@{
        schemaVersion = 2
        manifests = $descriptors
    }
    $layoutBytes = $encoding.GetBytes("{`"imageLayoutVersion`":`"1.0.0`"}`n")
    $indexBytes = $encoding.GetBytes(
        (($index | ConvertTo-Json -Depth 8 -Compress) + "`n"))

    $archive = [IO.File]::Open(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    try {
        $writer = [Formats.Tar.TarWriter]::new(
            $archive,
            [Formats.Tar.TarEntryFormat]::Pax,
            $true)
        try {
            Add-TestTarEntry -Writer $writer -Name 'oci-layout' -Bytes $layoutBytes
            Add-TestTarEntry -Writer $writer -Name 'index.json' -Bytes $indexBytes
            Add-TestTarEntry `
                -Writer $writer `
                -Name "blobs/sha256/$configHash" `
                -Bytes $configBytes
            Add-TestTarEntry `
                -Writer $writer `
                -Name "blobs/sha256/$manifestHash" `
                -Bytes $manifestBytes
            if ($IncludeAdditionalDescriptor) {
                Add-TestTarEntry `
                    -Writer $writer `
                    -Name "blobs/sha256/$additionalManifestHash" `
                    -Bytes $additionalManifestBytes
            }
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }

    return "sha256:$manifestHash"
}

function Get-TestRelativePath {
    param(
        [Parameter(Mandatory = $true)][string] $BasePath,
        [Parameter(Mandatory = $true)][string] $Path
    )

    return [IO.Path]::GetRelativePath($BasePath, $Path).Replace('\', '/')
}

function Write-TestChecksums {
    param([Parameter(Mandatory = $true)][string] $Directory)

    $checksumsPath = Join-Path $Directory 'checksums.sha256'
    [IO.File]::Delete($checksumsPath)
    $lines = @(
        Get-ChildItem -LiteralPath $Directory -File -Recurse |
            Sort-Object {
                Get-TestRelativePath -BasePath $Directory -Path $_.FullName
            } |
            ForEach-Object {
                $relativePath = Get-TestRelativePath `
                    -BasePath $Directory `
                    -Path $_.FullName
                $hash = (
                    Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
                ).Hash.ToLowerInvariant()
                "$hash  $relativePath"
            })
    [IO.File]::WriteAllText(
        $checksumsPath,
        (($lines -join "`n").TrimEnd() + "`n"),
        [Text.UTF8Encoding]::new($false))
}

function Assert-TestClosedChecksums {
    param([Parameter(Mandatory = $true)][string] $Directory)

    $checksumsPath = Join-Path $Directory 'checksums.sha256'
    $recorded = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($line in [IO.File]::ReadAllLines($checksumsPath)) {
        $match = [regex]::Match($line, '^(?<hash>[a-f0-9]{64})  (?<path>.+)$')
        if (-not $match.Success -or -not $recorded.Add($match.Groups['path'].Value)) {
            throw 'Candidate fixture produced invalid or duplicate checksums.'
        }
        $path = Join-Path $Directory $match.Groups['path'].Value
        if (-not [IO.File]::Exists($path)) {
            throw "Candidate fixture checksum file is missing '$path'."
        }
        $actual = (
            Get-FileHash -LiteralPath $path -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($actual -cne $match.Groups['hash'].Value) {
            throw "Candidate fixture checksum mismatch for '$path'."
        }
    }
    $actualPaths = @(
        Get-ChildItem -LiteralPath $Directory -File -Recurse |
            Where-Object { $_.FullName -cne $checksumsPath } |
            ForEach-Object {
                Get-TestRelativePath -BasePath $Directory -Path $_.FullName
            })
    if ($recorded.Count -ne $actualPaths.Count -or
        @($actualPaths | Where-Object { -not $recorded.Contains($_) }).Count -ne 0) {
        throw 'Candidate fixture checksums do not close the bundle.'
    }
}

function Invoke-TestExpectedFailure {
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [Parameter(Mandatory = $true)][hashtable] $Arguments,
        [Parameter(Mandatory = $true)][string] $MessagePattern,
        [Parameter(Mandatory = $true)][string] $Context
    )

    try {
        & $ScriptPath @Arguments | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "Unexpected $Context rejection: $($_.Exception.Message)"
        }
        return
    }
    throw "$Context did not reject '$MessagePattern'."
}

$temporaryRoot = Join-Path (
    [IO.Path]::GetTempPath()) (
    "bunkfy-image-candidate-test-$([Guid]::NewGuid().ToString('N'))")
try {
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $evidenceDirectory = Join-Path $temporaryRoot 'evidence'
    [IO.Directory]::CreateDirectory($evidenceDirectory) | Out-Null
    $backendArchive = Join-Path $temporaryRoot 'backend.oci.tar'
    $webArchive = Join-Path $temporaryRoot 'web.oci.tar'
    $backendDigest = New-TestOciArchive -Path $backendArchive
    $webDigest = New-TestOciArchive -Path $webArchive
    $sourceCommit = '1234567890abcdef1234567890abcdef12345678'
    $evidenceManifest = [ordered]@{
        schemaVersion = 1
        repository = 'SadPossum/BunkFy'
        candidate = [ordered]@{ sourceCommit = $sourceCommit }
        gateStatus = 'passed'
        images = @(
            [ordered]@{
                name = 'backend'
                platform = 'linux/amd64'
                sourceCommit = $sourceCommit
                manifestDigest = $backendDigest
                scanStatus = 'passed'
                published = $false
            },
            [ordered]@{
                name = 'web'
                platform = 'linux/amd64'
                sourceCommit = $sourceCommit
                manifestDigest = $webDigest
                scanStatus = 'passed'
                published = $false
            })
        publication = [ordered]@{
            enabled = $false
            registry = $null
            imageReferences = @()
        }
    }
    Write-TestJson `
        -Path (Join-Path $evidenceDirectory 'manifest.json') `
        -Value $evidenceManifest
    [IO.File]::WriteAllText(
        (Join-Path $evidenceDirectory 'source.txt'),
        "fixture`n",
        [Text.UTF8Encoding]::new($false))
    Write-TestChecksums -Directory $evidenceDirectory

    $bundleDirectory = Join-Path $temporaryRoot 'bundle'
    & $packager `
        -EvidenceDirectory $evidenceDirectory `
        -BackendArchivePath $backendArchive `
        -WebArchivePath $webArchive `
        -OutputDirectory $bundleDirectory 6>$null |
        Out-Null
    Assert-TestClosedChecksums -Directory $bundleDirectory

    $bundleManifest = [IO.File]::ReadAllText(
        (Join-Path $bundleDirectory 'candidate-bundle.json')) |
        ConvertFrom-Json
    $bundleImages = @($bundleManifest.images)
    if ($bundleManifest.schemaVersion -ne 1 -or
        $bundleManifest.bundleType -ne 'bunkfy-oci-promotion-candidate' -or
        $bundleManifest.sourceCommit -cne $sourceCommit -or
        $bundleManifest.publication.registryPublished -ne $false -or
        $bundleManifest.publication.deployableReference -ne $false -or
        $bundleImages.Count -ne 2) {
        throw 'Candidate bundle manifest does not preserve the closed contract.'
    }
    foreach ($candidate in @(
            @{ Name = 'backend'; Archive = $backendArchive; Digest = $backendDigest },
            @{ Name = 'web'; Archive = $webArchive; Digest = $webDigest })) {
        $record = @($bundleImages | Where-Object { $_.name -ceq $candidate.Name })
        $copiedArchive = Join-Path $bundleDirectory "oci/$($candidate.Name).oci.tar"
        if ($record.Count -ne 1 -or
            $record[0].manifestDigest -cne $candidate.Digest -or
            $record[0].sha256 -cne (
                Get-FileHash -LiteralPath $candidate.Archive -Algorithm SHA256
            ).Hash.ToLowerInvariant() -or
            -not [IO.File]::Exists($copiedArchive)) {
            throw "Candidate bundle does not preserve '$($candidate.Name)' bytes."
        }
    }

    $verifiedBundle = & $verifier `
        -BundleDirectory $bundleDirectory `
        -ExpectedSourceCommit $sourceCommit `
        -AllowUnattested `
        -PassThru
    if ($verifiedBundle.SourceCommit -cne $sourceCommit -or
        @($verifiedBundle.Images).Count -ne 2 -or
        $verifiedBundle.AttestationsVerified) {
        throw 'Candidate verifier did not return the admitted bundle identity.'
    }

    $releaseId = 'release-fixture-001'
    $fixtureRegistry = Join-Path $temporaryRoot 'fixture-registry'
    $promotionDirectory = Join-Path $temporaryRoot 'promotion'
    $dryRunRegistry = Join-Path $temporaryRoot 'dry-run-registry'
    $dryRunPromotion = Join-Path $temporaryRoot 'dry-run-promotion'
    $dryRunResult = @(& $promoter `
            -BundleDirectory $bundleDirectory `
            -ExpectedSourceCommit $sourceCommit `
            -ReleaseId $releaseId `
            -BackendDestination "registry.fixture.invalid/bunkfy/backend:$releaseId" `
            -WebDestination "registry.fixture.invalid/bunkfy/web:$releaseId" `
            -OutputDirectory $dryRunPromotion `
            -FixtureRegistryDirectory $dryRunRegistry `
            -AllowUnattested `
            -PassThru `
            -WhatIf 6>$null)
    if ($dryRunResult.Count -ne 0 -or
        [IO.Directory]::Exists($dryRunRegistry) -or
        [IO.Directory]::Exists($dryRunPromotion) -or
        [IO.File]::Exists($dryRunRegistry) -or
        [IO.File]::Exists($dryRunPromotion)) {
        throw 'Candidate promotion dry-run created registry or evidence output.'
    }

    $promotion = & $promoter `
        -BundleDirectory $bundleDirectory `
        -ExpectedSourceCommit $sourceCommit `
        -ReleaseId $releaseId `
        -BackendDestination "registry.fixture.invalid/bunkfy/backend:$releaseId" `
        -WebDestination "registry.fixture.invalid/bunkfy/web:$releaseId" `
        -OutputDirectory $promotionDirectory `
        -FixtureRegistryDirectory $fixtureRegistry `
        -AllowUnattested `
        -PassThru `
        -Confirm:$false
    Assert-TestClosedChecksums -Directory $promotionDirectory
    $verifiedPromotion = & $promotionVerifier `
        -PromotionDirectory $promotionDirectory `
        -ExpectedReleaseId $releaseId `
        -ExpectedSourceCommit $sourceCommit `
        -AllowFixtureEvidence `
        -PassThru
    $promotionImages = @($promotion.images)
    if ($promotion.schemaVersion -ne 1 -or
        $promotion.evidenceKind -cne 'bunkfy-image-promotion' -or
        $promotion.result -cne 'passed' -or
        $promotion.releaseId -cne $releaseId -or
        $promotion.sourceCommit -cne $sourceCommit -or
        $promotion.candidate.attestationsVerified -ne $false -or
        $promotion.promotionEvidenceReference -cnotmatch '^promotion:[0-9a-f]{32}$' -or
        $promotionImages.Count -ne 2 -or
        @($promotionImages | Where-Object { $_.outcome -cne 'published' }).Count -ne 0) {
        throw 'Candidate promotion fixture emitted invalid evidence.'
    }
    if ($verifiedPromotion.PromotionEvidenceReference -cne
        $promotion.promotionEvidenceReference -or
        @($verifiedPromotion.Images).Count -ne 2) {
        throw 'Image promotion verifier did not preserve the promotion identity.'
    }
    foreach ($image in $promotionImages) {
        $candidateImage = @(
            $verifiedBundle.Images |
                Where-Object { $_.Name -ceq $image.name })
        $fixtureArchive = Join-Path $fixtureRegistry "$($image.name).oci.tar"
        if ($candidateImage.Count -ne 1 -or
            $image.sourceManifestDigest -cne $candidateImage[0].ManifestDigest -or
            $image.digestReference -cne
                "registry.fixture.invalid/bunkfy/$($image.name)@$($candidateImage[0].ManifestDigest)" -or
            -not [IO.File]::Exists($fixtureArchive) -or
            (Get-FileHash -LiteralPath $fixtureArchive -Algorithm SHA256).Hash.ToLowerInvariant() -cne
                $candidateImage[0].Sha256) {
            throw "Candidate promotion did not preserve '$($image.name)' identity."
        }
    }

    $idempotentDirectory = Join-Path $temporaryRoot 'promotion-idempotent'
    $idempotent = & $promoter `
        -BundleDirectory $bundleDirectory `
        -ExpectedSourceCommit $sourceCommit `
        -ReleaseId $releaseId `
        -BackendDestination "registry.fixture.invalid/bunkfy/backend:$releaseId" `
        -WebDestination "registry.fixture.invalid/bunkfy/web:$releaseId" `
        -OutputDirectory $idempotentDirectory `
        -FixtureRegistryDirectory $fixtureRegistry `
        -AllowUnattested `
        -PassThru `
        -Confirm:$false
    if (@($idempotent.images | Where-Object {
                $_.outcome -cne 'already-present' }).Count -ne 0) {
        throw 'Candidate promotion fixture was not idempotent for identical bytes.'
    }
    Invoke-TestExpectedFailure `
        -ScriptPath $promoter `
        -Arguments @{
            BundleDirectory = $bundleDirectory
            ExpectedSourceCommit = $sourceCommit
            ReleaseId = $releaseId
            BackendDestination = 'registry.fixture.invalid/bunkfy/backend:wrong-tag'
            WebDestination = "registry.fixture.invalid/bunkfy/web:$releaseId"
            OutputDirectory = (Join-Path $temporaryRoot 'rejected-tag')
            FixtureRegistryDirectory = $fixtureRegistry
            AllowUnattested = $true
            Confirm = $false
        } `
        -MessagePattern 'exact release id' `
        -Context 'candidate promoter'
    Invoke-TestExpectedFailure `
        -ScriptPath $promoter `
        -Arguments @{
            BundleDirectory = $bundleDirectory
            ExpectedSourceCommit = $sourceCommit
            ReleaseId = $releaseId
            BackendDestination = "registry.example.test/bunkfy/backend:$releaseId"
            WebDestination = "registry.example.test/bunkfy/web:$releaseId"
            OutputDirectory = (Join-Path $temporaryRoot 'rejected-unattested')
            AllowUnattested = $true
            Confirm = $false
        } `
        -MessagePattern 'restricted to the local fixture' `
        -Context 'candidate promoter'
    Invoke-TestExpectedFailure `
        -ScriptPath $promoter `
        -Arguments @{
            BundleDirectory = $bundleDirectory
            ExpectedSourceCommit = $sourceCommit
            ReleaseId = $releaseId
            BackendDestination = "localhost:5000/bunkfy/backend:$releaseId"
            WebDestination = "registry.fixture.invalid:5000/bunkfy/web:$releaseId"
            OutputDirectory = (Join-Path $temporaryRoot 'rejected-loopback')
            Confirm = $false
        } `
        -MessagePattern 'fixture or loopback registry' `
        -Context 'hosted candidate promoter loopback destination'
    Invoke-TestExpectedFailure `
        -ScriptPath $promoter `
        -Arguments @{
            BundleDirectory = $bundleDirectory
            ExpectedSourceCommit = $sourceCommit
            ReleaseId = $releaseId
            BackendDestination = "registry.fixture.invalid/bunkfy/backend:$releaseId"
            WebDestination = "registry.fixture.invalid/bunkfy/web:$releaseId"
            OutputDirectory = (Join-Path $bundleDirectory 'promotion-evidence')
            FixtureRegistryDirectory = $fixtureRegistry
            AllowUnattested = $true
            Confirm = $false
        } `
        -MessagePattern 'must not overlap' `
        -Context 'candidate promoter'
    Invoke-TestExpectedFailure `
        -ScriptPath $promotionVerifier `
        -Arguments @{
            PromotionDirectory = $promotionDirectory
            ExpectedReleaseId = $releaseId
            ExpectedSourceCommit = $sourceCommit
        } `
        -MessagePattern 'fixture or loopback registry' `
        -Context 'image promotion verifier'

    $attestedFixtureDirectory = Join-Path $temporaryRoot 'attested-fixture-promotion'
    Copy-Item -LiteralPath $promotionDirectory `
        -Destination $attestedFixtureDirectory `
        -Recurse
    $attestedFixturePath = Join-Path $attestedFixtureDirectory 'promotion.json'
    $attestedFixture = [IO.File]::ReadAllText($attestedFixturePath) |
        ConvertFrom-Json -DateKind String
    $attestedFixture.candidate.attestationsVerified = $true
    Write-TestJson -Path $attestedFixturePath -Value $attestedFixture
    Write-TestChecksums -Directory $attestedFixtureDirectory
    Invoke-TestExpectedFailure `
        -ScriptPath $promotionVerifier `
        -Arguments @{
            PromotionDirectory = $attestedFixtureDirectory
            ExpectedReleaseId = $releaseId
            ExpectedSourceCommit = $sourceCommit
        } `
        -MessagePattern 'fixture or loopback registry' `
        -Context 'attested fixture promotion verifier'

    $attestedLoopbackDirectory = Join-Path $temporaryRoot 'attested-loopback-promotion'
    Copy-Item -LiteralPath $attestedFixtureDirectory `
        -Destination $attestedLoopbackDirectory `
        -Recurse
    $attestedLoopbackPath = Join-Path $attestedLoopbackDirectory 'promotion.json'
    $attestedLoopback = [IO.File]::ReadAllText($attestedLoopbackPath) |
        ConvertFrom-Json -DateKind String
    foreach ($image in @($attestedLoopback.images)) {
        $repository = "127.0.0.1:5000/bunkfy/$($image.name)"
        $image.tagReference = "$repository`:$releaseId"
        $image.digestReference = "$repository@$($image.sourceManifestDigest)"
    }
    Write-TestJson -Path $attestedLoopbackPath -Value $attestedLoopback
    Write-TestChecksums -Directory $attestedLoopbackDirectory
    Invoke-TestExpectedFailure `
        -ScriptPath $promotionVerifier `
        -Arguments @{
            PromotionDirectory = $attestedLoopbackDirectory
            ExpectedReleaseId = $releaseId
            ExpectedSourceCommit = $sourceCommit
        } `
        -MessagePattern 'fixture or loopback registry' `
        -Context 'attested loopback promotion verifier'
    Invoke-TestExpectedFailure `
        -ScriptPath $promotionVerifier `
        -Arguments @{
            PromotionDirectory = $promotionDirectory
            ExpectedReleaseId = 'release-fixture-other'
            ExpectedSourceCommit = $sourceCommit
            AllowFixtureEvidence = $true
        } `
        -MessagePattern 'expected release identity' `
        -Context 'image promotion verifier'

    Invoke-TestExpectedFailure `
        -ScriptPath $verifier `
        -Arguments @{
            BundleDirectory = $bundleDirectory
            ExpectedSourceCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            AllowUnattested = $true
        } `
        -MessagePattern 'expected unpublished BunkFy release' `
        -Context 'candidate verifier'

    $unlistedBundlePath = Join-Path $bundleDirectory 'unlisted.txt'
    [IO.File]::WriteAllText($unlistedBundlePath, "unlisted`n")
    Invoke-TestExpectedFailure `
        -ScriptPath $verifier `
        -Arguments @{
            BundleDirectory = $bundleDirectory
            ExpectedSourceCommit = $sourceCommit
            AllowUnattested = $true
        } `
        -MessagePattern 'closed checksummed file set' `
        -Context 'candidate verifier'
    [IO.File]::Delete($unlistedBundlePath)

    [IO.File]::AppendAllText(
        (Join-Path $bundleDirectory 'evidence/source.txt'),
        "tampered`n")
    Write-TestChecksums -Directory $bundleDirectory
    Invoke-TestExpectedFailure `
        -ScriptPath $verifier `
        -Arguments @{
            BundleDirectory = $bundleDirectory
            ExpectedSourceCommit = $sourceCommit
            AllowUnattested = $true
        } `
        -MessagePattern 'does not match checksums' `
        -Context 'candidate verifier'

    $unlistedPath = Join-Path $evidenceDirectory 'unlisted.txt'
    [IO.File]::WriteAllText($unlistedPath, "unlisted`n")
    $unlistedOutput = Join-Path $temporaryRoot 'rejected-unlisted'
    Invoke-TestExpectedFailure `
        -ScriptPath $packager `
        -Arguments @{
            EvidenceDirectory = $evidenceDirectory
            BackendArchivePath = $backendArchive
            WebArchivePath = $webArchive
            OutputDirectory = $unlistedOutput
        } `
        -MessagePattern 'closed checksummed file set' `
        -Context 'candidate packager'
    if ([IO.Directory]::Exists($unlistedOutput)) {
        throw 'Rejected unlisted evidence left a candidate bundle.'
    }
    [IO.File]::Delete($unlistedPath)

    $ambiguousArchive = Join-Path $temporaryRoot 'ambiguous.oci.tar'
    $ambiguousDigest = New-TestOciArchive `
        -Path $ambiguousArchive `
        -IncludeAdditionalDescriptor
    if ($ambiguousDigest -cne $backendDigest) {
        throw 'Ambiguous OCI fixture changed the expected manifest digest.'
    }
    $ambiguousOutput = Join-Path $temporaryRoot 'rejected-ambiguous-archive'
    Invoke-TestExpectedFailure `
        -ScriptPath $packager `
        -Arguments @{
            EvidenceDirectory = $evidenceDirectory
            BackendArchivePath = $ambiguousArchive
            WebArchivePath = $webArchive
            OutputDirectory = $ambiguousOutput
        } `
        -MessagePattern 'exactly one top-level manifest descriptor' `
        -Context 'candidate packager'
    if ([IO.Directory]::Exists($ambiguousOutput)) {
        throw 'Rejected ambiguous OCI archive left a candidate bundle.'
    }

    $evidenceManifest.images[0].manifestDigest = 'sha256:' + ('f' * 64)
    Write-TestJson `
        -Path (Join-Path $evidenceDirectory 'manifest.json') `
        -Value $evidenceManifest
    Write-TestChecksums -Directory $evidenceDirectory
    $digestOutput = Join-Path $temporaryRoot 'rejected-digest'
    Invoke-TestExpectedFailure `
        -ScriptPath $packager `
        -Arguments @{
            EvidenceDirectory = $evidenceDirectory
            BackendArchivePath = $backendArchive
            WebArchivePath = $webArchive
            OutputDirectory = $digestOutput
        } `
        -MessagePattern 'required metadata' `
        -Context 'candidate packager'
    if ([IO.Directory]::Exists($digestOutput)) {
        throw 'Rejected manifest mismatch left a candidate bundle.'
    }
}
finally {
    if ([IO.Directory]::Exists($temporaryRoot)) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}

Write-Host 'OCI candidate bundle fixture passed.'
