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

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'image-candidate.common.ps1')

$resolvedEvidenceDirectory = Resolve-BunkFyCandidatePath `
    -RepositoryRoot $repositoryRoot `
    -Path $EvidenceDirectory
$resolvedBackendArchive = Resolve-BunkFyCandidatePath `
    -RepositoryRoot $repositoryRoot `
    -Path $BackendArchivePath
$resolvedWebArchive = Resolve-BunkFyCandidatePath `
    -RepositoryRoot $repositoryRoot `
    -Path $WebArchivePath
$resolvedOutputDirectory = Resolve-BunkFyCandidatePath `
    -RepositoryRoot $repositoryRoot `
    -Path $OutputDirectory
if ([IO.Directory]::Exists($resolvedOutputDirectory) -or
    [IO.File]::Exists($resolvedOutputDirectory)) {
    throw "Candidate bundle output already exists: '$resolvedOutputDirectory'."
}

$closedEvidence = Get-BunkFyClosedChecksumSet `
    -Directory $resolvedEvidenceDirectory `
    -MaximumPayloadBytes 250MB `
    -Context 'Image evidence'
$evidenceManifest = Read-BunkFyCandidateJson `
    -Path (Join-Path $resolvedEvidenceDirectory 'manifest.json') `
    -MaximumBytes 1MB `
    -Context 'image evidence manifest'
$approvedEvidence = Assert-BunkFyImageEvidenceManifest `
    -Manifest $evidenceManifest

$archives = [Collections.Generic.List[object]]::new()
foreach ($candidate in @(
        @{ Name = 'backend'; Path = $resolvedBackendArchive },
        @{ Name = 'web'; Path = $resolvedWebArchive })) {
    $image = @(
        $approvedEvidence.Images |
            Where-Object { $_.name -ceq $candidate.Name })[0]
    $archives.Add((Get-BunkFyOciArchiveEvidence `
        -Name $candidate.Name `
        -ArchivePath $candidate.Path `
        -ExpectedManifestDigest $image.manifestDigest))
}

$stagingDirectory = "$resolvedOutputDirectory.tmp-$([Guid]::NewGuid().ToString('N'))"
try {
    [IO.Directory]::CreateDirectory($stagingDirectory) | Out-Null
    $evidenceDestination = Join-Path $stagingDirectory 'evidence'
    foreach ($record in $closedEvidence.Files) {
        Copy-BunkFyCandidateFile `
            -Source $record.FullPath `
            -Destination (Join-Path $evidenceDestination $record.RelativePath) `
            -ExpectedSha256 $record.Sha256
    }
    Copy-BunkFyCandidateFile `
        -Source $closedEvidence.ChecksumsPath `
        -Destination (Join-Path $evidenceDestination 'checksums.sha256') `
        -ExpectedSha256 $closedEvidence.ChecksumsSha256

    foreach ($archive in $archives) {
        Copy-BunkFyCandidateFile `
            -Source $archive.SourcePath `
            -Destination (Join-Path $stagingDirectory "oci/$($archive.FileName)") `
            -ExpectedSha256 $archive.Sha256
    }

    $bundleManifest = [ordered]@{
        schemaVersion = 1
        bundleType = 'bunkfy-oci-promotion-candidate'
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        repository = 'SadPossum/BunkFy'
        sourceCommit = $approvedEvidence.SourceCommit
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
    Write-BunkFyCandidateJson `
        -Path (Join-Path $stagingDirectory 'candidate-bundle.json') `
        -Value $bundleManifest

    $bundleChecksumsPath = Join-Path $stagingDirectory 'checksums.sha256'
    $checksumLines = @(
        Get-ChildItem -LiteralPath $stagingDirectory -File -Recurse |
            Where-Object { $_.FullName -cne $bundleChecksumsPath } |
            Sort-Object {
                Get-BunkFyCandidateRelativePath `
                    -BasePath $stagingDirectory `
                    -Path $_.FullName
            } |
            ForEach-Object {
                $relativePath = Get-BunkFyCandidateRelativePath `
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
