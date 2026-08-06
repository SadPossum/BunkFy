[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $EvidenceDirectory,

    [Parameter(Mandatory = $true)]
    [string] $BackendArchivePath,

    [Parameter(Mandatory = $true)]
    [string] $WebArchivePath,

    [string] $OutputDirectory = 'artifacts/image-candidate'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Resolve-BunkFyPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path))
}

function Read-BunkFyJson {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][long] $MaximumBytes,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not [IO.File]::Exists($Path)) {
        throw "Missing $Context '$Path'."
    }
    $file = [IO.FileInfo]::new($Path)
    if ($file.Length -le 0 -or $file.Length -gt $MaximumBytes) {
        throw "$Context '$Path' has an invalid size."
    }
    try {
        $document = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    }
    catch {
        throw "$Context '$Path' is not valid JSON."
    }
    if ($null -eq $document -or
        $document -is [string] -or
        $document -is [Array]) {
        throw "$Context '$Path' must contain an object."
    }
    return $document
}

function Write-BunkFyJson {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][object] $Value
    )

    $json = $Value | ConvertTo-Json -Depth 16
    $content = $json.Replace("`r`n", "`n").TrimEnd() + "`n"
    [IO.File]::WriteAllText(
        $Path,
        $content,
        [Text.UTF8Encoding]::new($false))
}

function Get-BunkFyRelativePath {
    param(
        [Parameter(Mandatory = $true)][string] $BasePath,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $relative = [IO.Path]::GetRelativePath($BasePath, $Path).Replace('\', '/')
    if ($relative -eq '..' -or
        $relative.StartsWith('../', [StringComparison]::Ordinal) -or
        [IO.Path]::IsPathRooted($relative)) {
        throw "Path '$Path' is outside '$BasePath'."
    }
    return $relative
}

function Assert-BunkFyRegularFile {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo] $File,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (($File.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context '$($File.FullName)' must not be a link."
    }
}

function Assert-BunkFySafeTarEntry {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][Formats.Tar.TarEntryType] $EntryType,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $trimmedName = $Name.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($trimmedName) -or
        $Name.Length -gt 4096 -or
        $Name.Contains('\') -or
        $Name.StartsWith('/', [StringComparison]::Ordinal) -or
        $trimmedName -match '(^|/)\.\.?($|/)' -or
        $trimmedName.Split('/') -contains '') {
        throw "$Context contains unsafe entry '$Name'."
    }
    if (@(
            [Formats.Tar.TarEntryType]::V7RegularFile,
            [Formats.Tar.TarEntryType]::RegularFile,
            [Formats.Tar.TarEntryType]::Directory
        ) -notcontains $EntryType) {
        throw "$Context contains unsupported entry '$Name' of type '$EntryType'."
    }
}

function Get-BunkFyClosedEvidenceFiles {
    param([Parameter(Mandatory = $true)][string] $Directory)

    if (-not [IO.Directory]::Exists($Directory)) {
        throw "Image evidence directory is missing: '$Directory'."
    }
    foreach ($childDirectory in Get-ChildItem -LiteralPath $Directory -Directory -Recurse) {
        if (($childDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Image evidence contains linked directory '$($childDirectory.FullName)'."
        }
    }

    $checksumsPath = Join-Path $Directory 'checksums.sha256'
    if (-not [IO.File]::Exists($checksumsPath)) {
        throw 'Image evidence is missing checksums.sha256.'
    }
    $checksumsFile = [IO.FileInfo]::new($checksumsPath)
    Assert-BunkFyRegularFile -File $checksumsFile -Context 'Evidence checksum file'
    if ($checksumsFile.Length -le 0 -or $checksumsFile.Length -gt 1MB) {
        throw 'Image evidence checksums.sha256 has an invalid size.'
    }

    $records = [Collections.Generic.List[object]]::new()
    $seenPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($line in [IO.File]::ReadAllLines($checksumsPath)) {
        $match = [regex]::Match(
            $line,
            '^(?<hash>[a-f0-9]{64})  (?<path>[^\\]+)$')
        if (-not $match.Success) {
            throw 'Image evidence checksums.sha256 contains an invalid record.'
        }
        $relativePath = $match.Groups['path'].Value
        if ($relativePath.StartsWith('/', [StringComparison]::Ordinal) -or
            $relativePath -match '(^|/)\.\.($|/)' -or
            $relativePath -eq 'checksums.sha256' -or
            -not $seenPaths.Add($relativePath)) {
            throw "Image evidence checksum path '$relativePath' is unsafe or duplicated."
        }
        $fullPath = [IO.Path]::GetFullPath(
            (Join-Path $Directory $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        $actualRelativePath = Get-BunkFyRelativePath -BasePath $Directory -Path $fullPath
        if ($actualRelativePath -cne $relativePath -or
            -not [IO.File]::Exists($fullPath)) {
            throw "Image evidence file '$relativePath' is missing."
        }
        $file = [IO.FileInfo]::new($fullPath)
        Assert-BunkFyRegularFile -File $file -Context 'Evidence file'
        $actualHash = (
            Get-FileHash -LiteralPath $fullPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($actualHash -cne $match.Groups['hash'].Value) {
            throw "Image evidence file '$relativePath' does not match checksums.sha256."
        }
        $records.Add([pscustomobject]@{
            RelativePath = $relativePath
            FullPath = $fullPath
            Length = $file.Length
            Sha256 = $actualHash
        })
    }

    $actualFiles = @(
        Get-ChildItem -LiteralPath $Directory -File -Recurse |
            Where-Object { $_.FullName -cne $checksumsPath } |
            ForEach-Object {
                Assert-BunkFyRegularFile -File $_ -Context 'Evidence file'
                Get-BunkFyRelativePath -BasePath $Directory -Path $_.FullName
            } |
            Sort-Object)
    $recordedFiles = @($records.RelativePath | Sort-Object)
    $fileDifferences = @(
        Compare-Object `
            -ReferenceObject $recordedFiles `
            -DifferenceObject $actualFiles)
    if ($actualFiles.Count -ne $recordedFiles.Count -or
        $fileDifferences.Count -ne 0) {
        throw 'Image evidence is not a closed checksummed file set.'
    }
    if (($records | Measure-Object -Property Length -Sum).Sum -gt 250MB) {
        throw 'Image evidence exceeds the bundle size limit.'
    }

    return [pscustomobject]@{
        ChecksumsPath = $checksumsPath
        ChecksumsSha256 = (
            Get-FileHash -LiteralPath $checksumsPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        Files = @($records.ToArray())
    }
}

function Get-BunkFyOciArchiveEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][string] $ExpectedManifestDigest
    )

    if ($ExpectedManifestDigest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $ExpectedManifestDigest -ceq ('sha256:' + ('0' * 64))) {
        throw "Image '$Name' has an invalid manifest digest."
    }
    if (-not [IO.File]::Exists($ArchivePath)) {
        throw "OCI archive for '$Name' is missing: '$ArchivePath'."
    }
    $archive = [IO.FileInfo]::new($ArchivePath)
    Assert-BunkFyRegularFile -File $archive -Context "OCI archive for '$Name'"
    if ($archive.Length -le 0 -or $archive.Length -gt 2GB) {
        throw "OCI archive for '$Name' has an invalid size."
    }

    $expandedDirectory = Join-Path (
        [IO.Path]::GetTempPath()) (
        "bunkfy-candidate-$Name-$([Guid]::NewGuid().ToString('N'))")
    try {
        [IO.Directory]::CreateDirectory($expandedDirectory) | Out-Null
        $layoutPath = Join-Path $expandedDirectory 'oci-layout'
        $indexPath = Join-Path $expandedDirectory 'index.json'
        $manifestHex = $ExpectedManifestDigest.Substring(7)
        $manifestBlobPath = Join-Path $expandedDirectory "blobs/sha256/$manifestHex"
        $requiredEntries = @{
            'oci-layout' = @{ Path = $layoutPath; MaximumBytes = 64KB }
            'index.json' = @{ Path = $indexPath; MaximumBytes = 1MB }
            "blobs/sha256/$manifestHex" = @{
                Path = $manifestBlobPath
                MaximumBytes = 16MB
            }
        }
        $seenRequiredEntries = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
        $archiveStream = [IO.File]::OpenRead($ArchivePath)
        try {
            $reader = [Formats.Tar.TarReader]::new($archiveStream, $true)
            try {
                $entryCount = 0
                while ($null -ne ($entry = $reader.GetNextEntry())) {
                    $entryCount++
                    if ($entryCount -gt 100000) {
                        throw "OCI archive for '$Name' contains too many entries."
                    }
                    Assert-BunkFySafeTarEntry `
                        -Name $entry.Name `
                        -EntryType $entry.EntryType `
                        -Context "OCI archive for '$Name'"

                    $requiredEntry = $requiredEntries[$entry.Name]
                    if ($null -eq $requiredEntry) {
                        continue
                    }
                    if (-not $seenRequiredEntries.Add($entry.Name)) {
                        throw "OCI archive for '$Name' duplicates '$($entry.Name)'."
                    }
                    if ($entry.EntryType -eq [Formats.Tar.TarEntryType]::Directory -or
                        $null -eq $entry.DataStream -or
                        $entry.Length -le 0 -or
                        $entry.Length -gt $requiredEntry.MaximumBytes) {
                        throw "OCI archive for '$Name' has invalid '$($entry.Name)'."
                    }
                    [IO.Directory]::CreateDirectory(
                        (Split-Path -Parent $requiredEntry.Path)) | Out-Null
                    $targetStream = [IO.File]::Open(
                        $requiredEntry.Path,
                        [IO.FileMode]::CreateNew,
                        [IO.FileAccess]::Write,
                        [IO.FileShare]::None)
                    try {
                        $entry.DataStream.CopyTo($targetStream)
                    }
                    finally {
                        $targetStream.Dispose()
                    }
                }
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $archiveStream.Dispose()
        }
        if ($seenRequiredEntries.Count -ne $requiredEntries.Count) {
            throw "OCI archive for '$Name' is missing required metadata."
        }

        $layout = Read-BunkFyJson `
            -Path $layoutPath `
            -MaximumBytes 64KB `
            -Context "OCI layout for '$Name'"
        $index = Read-BunkFyJson `
            -Path $indexPath `
            -MaximumBytes 1MB `
            -Context "OCI index for '$Name'"
        if ($layout.imageLayoutVersion -ne '1.0.0' -or $index.schemaVersion -ne 2) {
            throw "OCI archive for '$Name' has an unsupported layout."
        }
        $matchingDescriptors = @(
            @($index.manifests) |
                Where-Object { $_.digest -ceq $ExpectedManifestDigest })
        if ($matchingDescriptors.Count -ne 1) {
            throw "OCI archive for '$Name' does not contain its recorded manifest digest."
        }
        $manifestBlob = [IO.FileInfo]::new($manifestBlobPath)
        Assert-BunkFyRegularFile -File $manifestBlob -Context "OCI manifest for '$Name'"
        if ($manifestBlob.Length -le 0 -or $manifestBlob.Length -gt 16MB) {
            throw "OCI manifest for '$Name' has an invalid size."
        }
        if ($matchingDescriptors[0].size -ne $manifestBlob.Length) {
            throw "OCI archive for '$Name' has a mismatched manifest descriptor size."
        }
        $manifestBlobHash = (
            Get-FileHash -LiteralPath $manifestBlobPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ("sha256:$manifestBlobHash" -cne $ExpectedManifestDigest) {
            throw "OCI archive for '$Name' has a corrupt recorded manifest blob."
        }
    }
    finally {
        if ([IO.Directory]::Exists($expandedDirectory)) {
            [IO.Directory]::Delete($expandedDirectory, $true)
        }
    }

    return [pscustomobject]@{
        Name = $Name
        SourcePath = $ArchivePath
        FileName = "$Name.oci.tar"
        Length = $archive.Length
        Sha256 = (
            Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        ManifestDigest = $ExpectedManifestDigest
    }
}

function Copy-BunkFyFile {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [string] $ExpectedSha256
    )

    $parent = Split-Path -Parent $Destination
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    [IO.File]::Copy($Source, $Destination, $false)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $actualHash = (
            Get-FileHash -LiteralPath $Destination -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($actualHash -cne $ExpectedSha256) {
            throw "Copied candidate file '$Destination' failed its SHA-256 check."
        }
    }
}

$resolvedEvidenceDirectory = Resolve-BunkFyPath $EvidenceDirectory
$resolvedBackendArchive = Resolve-BunkFyPath $BackendArchivePath
$resolvedWebArchive = Resolve-BunkFyPath $WebArchivePath
$resolvedOutputDirectory = Resolve-BunkFyPath $OutputDirectory
if ([IO.Directory]::Exists($resolvedOutputDirectory) -or
    [IO.File]::Exists($resolvedOutputDirectory)) {
    throw "Candidate bundle output already exists: '$resolvedOutputDirectory'."
}

$closedEvidence = Get-BunkFyClosedEvidenceFiles -Directory $resolvedEvidenceDirectory
$evidenceManifest = Read-BunkFyJson `
    -Path (Join-Path $resolvedEvidenceDirectory 'manifest.json') `
    -MaximumBytes 1MB `
    -Context 'image evidence manifest'
if ($evidenceManifest.schemaVersion -ne 1 -or
    $evidenceManifest.repository -ne 'SadPossum/BunkFy' -or
    $evidenceManifest.gateStatus -ne 'passed' -or
    $evidenceManifest.candidate.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
    $evidenceManifest.candidate.sourceCommit -ceq ('0' * 40)) {
    throw 'Image evidence manifest is not an approved BunkFy candidate.'
}
if ($evidenceManifest.publication.enabled -ne $false -or
    @($evidenceManifest.publication.imageReferences).Count -ne 0) {
    throw 'Image evidence already declares a publication channel.'
}

$imageRecords = @($evidenceManifest.images)
$imageNames = @($imageRecords.name | Sort-Object -Unique)
$imageNameDifferences = @(
    Compare-Object `
        -ReferenceObject @('backend', 'web') `
        -DifferenceObject $imageNames)
if ($imageRecords.Count -ne 2 -or
    $imageNameDifferences.Count -ne 0) {
    throw 'Image evidence must contain exactly the backend and web candidates.'
}
$archives = [Collections.Generic.List[object]]::new()
foreach ($candidate in @(
        @{ Name = 'backend'; Path = $resolvedBackendArchive },
        @{ Name = 'web'; Path = $resolvedWebArchive })) {
    $image = @($imageRecords | Where-Object { $_.name -ceq $candidate.Name })
    if ($image.Count -ne 1 -or
        $image[0].platform -ne 'linux/amd64' -or
        $image[0].scanStatus -ne 'passed' -or
        $image[0].published -ne $false) {
        throw "Image evidence for '$($candidate.Name)' is not promotion-eligible."
    }
    $archives.Add((Get-BunkFyOciArchiveEvidence `
        -Name $candidate.Name `
        -ArchivePath $candidate.Path `
        -ExpectedManifestDigest $image[0].manifestDigest))
}

$stagingDirectory = "$resolvedOutputDirectory.tmp-$([Guid]::NewGuid().ToString('N'))"
try {
    [IO.Directory]::CreateDirectory($stagingDirectory) | Out-Null
    $evidenceDestination = Join-Path $stagingDirectory 'evidence'
    foreach ($record in $closedEvidence.Files) {
        Copy-BunkFyFile `
            -Source $record.FullPath `
            -Destination (Join-Path $evidenceDestination $record.RelativePath) `
            -ExpectedSha256 $record.Sha256
    }
    Copy-BunkFyFile `
        -Source $closedEvidence.ChecksumsPath `
        -Destination (Join-Path $evidenceDestination 'checksums.sha256') `
        -ExpectedSha256 $closedEvidence.ChecksumsSha256

    foreach ($archive in $archives) {
        Copy-BunkFyFile `
            -Source $archive.SourcePath `
            -Destination (Join-Path $stagingDirectory "oci/$($archive.FileName)") `
            -ExpectedSha256 $archive.Sha256
    }

    $bundleManifest = [ordered]@{
        schemaVersion = 1
        bundleType = 'bunkfy-oci-promotion-candidate'
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        repository = 'SadPossum/BunkFy'
        sourceCommit = $evidenceManifest.candidate.sourceCommit
        platform = 'linux/amd64'
        evidenceManifest = 'evidence/manifest.json'
        images = @(
            $archives | ForEach-Object {
                [ordered]@{
                    name = $_.Name
                    archive = "oci/$($_.FileName)"
                    bytes = $_.Length
                    sha256 = $_.Sha256
                    manifestDigest = $_.ManifestDigest
                }
            })
        publication = [ordered]@{
            registryPublished = $false
            deployableReference = $false
            purpose = 'Exact-byte input for an independently approved promotion channel.'
        }
    }
    Write-BunkFyJson `
        -Path (Join-Path $stagingDirectory 'candidate-bundle.json') `
        -Value $bundleManifest

    $bundleChecksumsPath = Join-Path $stagingDirectory 'checksums.sha256'
    $checksumLines = @(
        Get-ChildItem -LiteralPath $stagingDirectory -File -Recurse |
            Where-Object { $_.FullName -cne $bundleChecksumsPath } |
            Sort-Object {
                Get-BunkFyRelativePath `
                    -BasePath $stagingDirectory `
                    -Path $_.FullName
            } |
            ForEach-Object {
                $relativePath = Get-BunkFyRelativePath `
                    -BasePath $stagingDirectory `
                    -Path $_.FullName
                $hash = (
                    Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
                ).Hash.ToLowerInvariant()
                "$hash  $relativePath"
            })
    [IO.File]::WriteAllText(
        $bundleChecksumsPath,
        (($checksumLines -join "`n").TrimEnd() + "`n"),
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

Write-Host "Closed OCI candidate bundle written to '$resolvedOutputDirectory'."
