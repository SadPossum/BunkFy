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
    param([Parameter(Mandatory = $true)][string] $Path)

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
    $index = [ordered]@{
        schemaVersion = 2
        manifests = @(
            [ordered]@{
                mediaType = 'application/vnd.oci.image.manifest.v1+json'
                digest = "sha256:$manifestHash"
                size = $manifestBytes.Length
                platform = [ordered]@{
                    architecture = 'amd64'
                    os = 'linux'
                }
            })
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
