function Resolve-BunkFyCandidatePath {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $Path
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Path))
}

function Read-BunkFyCandidateJson {
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

function Write-BunkFyCandidateJson {
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

function Get-BunkFyCandidateRelativePath {
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

function Assert-BunkFyCandidateRegularFile {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo] $File,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (($File.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context '$($File.FullName)' must not be a link."
    }
}

function Assert-BunkFyCandidateProperties {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string[]] $ExpectedProperties,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $actualProperties = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($ExpectedProperties | Sort-Object)
    $differences = @(
        Compare-Object `
            -ReferenceObject $expected `
            -DifferenceObject $actualProperties)
    if ($actualProperties.Count -ne $expected.Count -or
        $differences.Count -ne 0) {
        throw "$Context contains an unsupported property set."
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

function Get-BunkFyClosedChecksumSet {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][long] $MaximumPayloadBytes,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not [IO.Directory]::Exists($Directory)) {
        throw "$Context directory is missing: '$Directory'."
    }
    $directoryInfo = [IO.DirectoryInfo]::new($Directory)
    if (($directoryInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context directory '$Directory' must not be a link."
    }
    foreach ($childDirectory in Get-ChildItem -LiteralPath $Directory -Directory -Recurse) {
        if (($childDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context contains linked directory '$($childDirectory.FullName)'."
        }
    }

    $checksumsPath = Join-Path $Directory 'checksums.sha256'
    if (-not [IO.File]::Exists($checksumsPath)) {
        throw "$Context is missing checksums.sha256."
    }
    $checksumsFile = [IO.FileInfo]::new($checksumsPath)
    Assert-BunkFyCandidateRegularFile `
        -File $checksumsFile `
        -Context "$Context checksum file"
    if ($checksumsFile.Length -le 0 -or $checksumsFile.Length -gt 1MB) {
        throw "$Context checksums.sha256 has an invalid size."
    }

    $records = [Collections.Generic.List[object]]::new()
    $seenPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($line in [IO.File]::ReadAllLines($checksumsPath)) {
        $match = [regex]::Match(
            $line,
            '^(?<hash>[a-f0-9]{64})  (?<path>[^\\]+)$')
        if (-not $match.Success) {
            throw "$Context checksums.sha256 contains an invalid record."
        }
        $relativePath = $match.Groups['path'].Value
        if ($relativePath.StartsWith('/', [StringComparison]::Ordinal) -or
            $relativePath -match '(^|/)\.\.($|/)' -or
            $relativePath -eq 'checksums.sha256' -or
            -not $seenPaths.Add($relativePath)) {
            throw "$Context checksum path '$relativePath' is unsafe or duplicated."
        }
        $fullPath = [IO.Path]::GetFullPath(
            (Join-Path $Directory $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        $actualRelativePath = Get-BunkFyCandidateRelativePath `
            -BasePath $Directory `
            -Path $fullPath
        if ($actualRelativePath -cne $relativePath -or
            -not [IO.File]::Exists($fullPath)) {
            throw "$Context file '$relativePath' is missing."
        }
        $file = [IO.FileInfo]::new($fullPath)
        Assert-BunkFyCandidateRegularFile -File $file -Context "$Context file"
        $actualHash = (
            Get-FileHash -LiteralPath $fullPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($actualHash -cne $match.Groups['hash'].Value) {
            throw "$Context file '$relativePath' does not match checksums.sha256."
        }
        $records.Add([pscustomobject]@{
            RelativePath = $relativePath
            FullPath = $fullPath
            Length = $file.Length
            Sha256 = $actualHash
        })
    }
    if ($records.Count -eq 0) {
        throw "$Context checksums.sha256 must list at least one file."
    }

    $actualFiles = @(
        Get-ChildItem -LiteralPath $Directory -File -Recurse |
            Where-Object { $_.FullName -cne $checksumsPath } |
            ForEach-Object {
                Assert-BunkFyCandidateRegularFile -File $_ -Context "$Context file"
                Get-BunkFyCandidateRelativePath `
                    -BasePath $Directory `
                    -Path $_.FullName
            } |
            Sort-Object)
    $recordedFiles = @($records.RelativePath | Sort-Object)
    $fileDifferences = @(
        Compare-Object `
            -ReferenceObject $recordedFiles `
            -DifferenceObject $actualFiles)
    if ($actualFiles.Count -ne $recordedFiles.Count -or
        $fileDifferences.Count -ne 0) {
        throw "$Context is not a closed checksummed file set."
    }
    $recordedDirectories = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($relativePath in $recordedFiles) {
        $parent = $relativePath
        while ($parent.Contains('/')) {
            $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
            $recordedDirectories.Add($parent) | Out-Null
        }
    }
    $actualDirectories = @(
        Get-ChildItem -LiteralPath $Directory -Directory -Recurse |
            ForEach-Object {
                Get-BunkFyCandidateRelativePath `
                    -BasePath $Directory `
                    -Path $_.FullName
            } |
            Sort-Object)
    $expectedDirectories = @($recordedDirectories | Sort-Object)
    if ($actualDirectories.Count -ne $expectedDirectories.Count -or
        ($actualDirectories -join "`n") -cne
            ($expectedDirectories -join "`n")) {
        throw "$Context contains an unlisted or missing directory."
    }
    $payloadBytes = [long](
        $records | Measure-Object -Property Length -Sum).Sum
    if ($payloadBytes -gt $MaximumPayloadBytes) {
        throw "$Context exceeds the payload size limit."
    }

    return [pscustomobject]@{
        Directory = $Directory
        ChecksumsPath = $checksumsPath
        ChecksumsSha256 = (
            Get-FileHash -LiteralPath $checksumsPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        PayloadBytes = $payloadBytes
        Files = @($records.ToArray())
    }
}

function Get-BunkFyOciArchiveEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][string] $ExpectedManifestDigest,
        [string] $VerifiedArchiveSha256
    )

    if ($ExpectedManifestDigest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $ExpectedManifestDigest -ceq ('sha256:' + ('0' * 64))) {
        throw "Image '$Name' has an invalid manifest digest."
    }
    if (-not [IO.File]::Exists($ArchivePath)) {
        throw "OCI archive for '$Name' is missing: '$ArchivePath'."
    }
    $archive = [IO.FileInfo]::new($ArchivePath)
    Assert-BunkFyCandidateRegularFile `
        -File $archive `
        -Context "OCI archive for '$Name'"
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

        $layout = Read-BunkFyCandidateJson `
            -Path $layoutPath `
            -MaximumBytes 64KB `
            -Context "OCI layout for '$Name'"
        $index = Read-BunkFyCandidateJson `
            -Path $indexPath `
            -MaximumBytes 1MB `
            -Context "OCI index for '$Name'"
        if ($layout.imageLayoutVersion -ne '1.0.0' -or $index.schemaVersion -ne 2) {
            throw "OCI archive for '$Name' has an unsupported layout."
        }
        $descriptors = @($index.manifests)
        if ($descriptors.Count -ne 1) {
            throw "OCI archive for '$Name' must contain exactly one top-level manifest descriptor."
        }
        $matchingDescriptors = @(
            $descriptors |
                Where-Object { $_.digest -ceq $ExpectedManifestDigest })
        if ($matchingDescriptors.Count -ne 1) {
            throw "OCI archive for '$Name' does not contain its recorded manifest digest."
        }
        $manifestBlob = [IO.FileInfo]::new($manifestBlobPath)
        Assert-BunkFyCandidateRegularFile `
            -File $manifestBlob `
            -Context "OCI manifest for '$Name'"
        if ($manifestBlob.Length -le 0 -or $manifestBlob.Length -gt 16MB) {
            throw "OCI manifest for '$Name' has an invalid size."
        }
        $descriptorSize = $matchingDescriptors[0].size
        if (($descriptorSize -isnot [int] -and $descriptorSize -isnot [long]) -or
            [long]$descriptorSize -ne $manifestBlob.Length) {
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

    if ([string]::IsNullOrWhiteSpace($VerifiedArchiveSha256)) {
        $archiveSha256 = (
            Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }
    elseif ($VerifiedArchiveSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $VerifiedArchiveSha256 -ceq ('0' * 64)) {
        throw "OCI archive for '$Name' has an invalid verified SHA-256."
    }
    else {
        $archiveSha256 = $VerifiedArchiveSha256
    }

    return [pscustomobject]@{
        Name = $Name
        SourcePath = $ArchivePath
        FileName = "$Name.oci.tar"
        Length = $archive.Length
        Sha256 = $archiveSha256
        ManifestDigest = $ExpectedManifestDigest
    }
}

function Copy-BunkFyCandidateFile {
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

function Assert-BunkFyImageEvidenceManifest {
    param([Parameter(Mandatory = $true)][object] $Manifest)

    if ($Manifest.schemaVersion -ne 1 -or
        $Manifest.repository -ne 'SadPossum/BunkFy' -or
        $Manifest.gateStatus -ne 'passed' -or
        $Manifest.candidate.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
        $Manifest.candidate.sourceCommit -ceq ('0' * 40)) {
        throw 'Image evidence manifest is not an approved BunkFy candidate.'
    }
    if ($Manifest.publication.enabled -ne $false -or
        $null -ne $Manifest.publication.registry -or
        @($Manifest.publication.imageReferences).Count -ne 0) {
        throw 'Image evidence already declares a publication channel.'
    }

    $imageRecords = @($Manifest.images)
    $imageNames = @($imageRecords.name | Sort-Object -Unique)
    $imageNameDifferences = @(
        Compare-Object `
            -ReferenceObject @('backend', 'web') `
            -DifferenceObject $imageNames)
    if ($imageRecords.Count -ne 2 -or
        $imageNameDifferences.Count -ne 0) {
        throw 'Image evidence must contain exactly the backend and web candidates.'
    }
    foreach ($name in @('backend', 'web')) {
        $image = @($imageRecords | Where-Object { $_.name -ceq $name })
        if ($image.Count -ne 1 -or
            $image[0].platform -ne 'linux/amd64' -or
            $image[0].sourceCommit -cne $Manifest.candidate.sourceCommit -or
            $image[0].scanStatus -ne 'passed' -or
            $image[0].published -ne $false -or
            $image[0].manifestDigest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            $image[0].manifestDigest -ceq ('sha256:' + ('0' * 64))) {
            throw "Image evidence for '$name' is not promotion-eligible."
        }
    }

    return [pscustomobject]@{
        SourceCommit = $Manifest.candidate.sourceCommit
        Images = $imageRecords
    }
}
