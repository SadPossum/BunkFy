[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $SourceSetPath,

    [Parameter(Mandatory = $true)]
    [string] $BackendMetadataPath,

    [Parameter(Mandatory = $true)]
    [string] $WebMetadataPath,

    [Parameter(Mandatory = $true)]
    [string] $BackendScanSummaryPath,

    [Parameter(Mandatory = $true)]
    [string] $WebScanSummaryPath,

    [Parameter(Mandatory = $true)]
    [string] $BackendSbomPath,

    [Parameter(Mandatory = $true)]
    [string] $WebSbomPath,

    [string] $OutputDirectory = 'artifacts/image-evidence'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..'))
$resolvedOutputDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot $OutputDirectory))
[System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null

function Read-BoundedJsonDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [long] $MaximumBytes,

        [Parameter(Mandatory = $true)]
        [string] $Context
    )

    $resolvedPath = [System.IO.Path]::GetFullPath(
        (Join-Path $repositoryRoot $Path))
    if (-not [System.IO.File]::Exists($resolvedPath)) {
        throw "Missing $Context '$Path'."
    }

    $file = [System.IO.FileInfo]::new($resolvedPath)
    if ($file.Length -gt $MaximumBytes) {
        throw "$Context '$Path' exceeds its size limit."
    }

    try {
        $document = [System.IO.File]::ReadAllText($resolvedPath) |
            ConvertFrom-Json
    }
    catch {
        throw "$Context '$Path' is not valid JSON."
    }

    if ($null -eq $document -or
        $document -is [string] -or
        $document -is [System.Array]) {
        throw "$Context '$Path' must contain an object."
    }

    return [pscustomobject]@{
        Path = $resolvedPath
        Document = $document
    }
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = & git -C $WorkingDirectory @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed in '$WorkingDirectory'."
    }

    return ($output -join "`n").Trim()
}

function Assert-CommitSha {
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [string] $Context
    )

    if ($Value -isnot [string] -or
        $Value -notmatch '^[0-9a-f]{40}$' -or
        $Value -eq ('0' * 40)) {
        throw "$Context is not an exact Git commit."
    }
}

function Get-BuildDigest {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Metadata,

        [Parameter(Mandatory = $true)]
        [string] $Context
    )

    $digest = $null
    foreach ($key in @(
            'containerimage.digest',
            'containerimage.descriptor.digest'
        )) {
        $property = $Metadata.PSObject.Properties[$key]
        if ($null -ne $property -and
            $property.Value -is [string] -and
            -not [string]::IsNullOrWhiteSpace($property.Value)) {
            $digest = $property.Value
            break
        }
    }

    if ($digest -notmatch '^sha256:[0-9a-f]{64}$' -or
        $digest -eq ('sha256:' + ('0' * 64))) {
        throw "$Context does not contain an immutable OCI manifest digest."
    }

    return $digest
}

function Get-RootRelativePath {
    param([Parameter(Mandatory = $true)][string] $Path)

    return Get-RelativePathUnder `
        -BasePath $repositoryRoot `
        -Path $Path
}

function Get-RelativePathUnder {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BasePath,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $normalizedBase = [System.IO.Path]::GetFullPath($BasePath)
    $normalizedBase = $normalizedBase.TrimEnd('\', '/')
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if ([string]::Equals(
            $normalizedBase,
            $resolvedPath,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        return '.'
    }

    $basePrefix = $normalizedBase + $separator
    if (-not $resolvedPath.StartsWith(
            $basePrefix,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Evidence path '$resolvedPath' is outside the repository."
    }

    return $resolvedPath.Substring($basePrefix.Length).Replace('\', '/')
}

function Write-JsonDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [object] $Value
    )

    $json = $Value |
        ConvertTo-Json -Depth 16
    $content = $json.Replace("`r`n", "`n").TrimEnd() + "`n"
    [System.IO.File]::WriteAllText(
        $Path,
        $content,
        [System.Text.UTF8Encoding]::new($false))
}

$releaseManifestResult = Read-BoundedJsonDocument `
    -Path '.gma/release-evidence.json' `
    -MaximumBytes 16KB `
    -Context 'release manifest'
$sourceSetResult = Read-BoundedJsonDocument `
    -Path $SourceSetPath `
    -MaximumBytes 5MB `
    -Context 'recursive source set'
$backendMetadataResult = Read-BoundedJsonDocument `
    -Path $BackendMetadataPath `
    -MaximumBytes 5MB `
    -Context 'backend build metadata'
$webMetadataResult = Read-BoundedJsonDocument `
    -Path $WebMetadataPath `
    -MaximumBytes 5MB `
    -Context 'web build metadata'
$backendScanResult = Read-BoundedJsonDocument `
    -Path $BackendScanSummaryPath `
    -MaximumBytes 1MB `
    -Context 'backend scan summary'
$webScanResult = Read-BoundedJsonDocument `
    -Path $WebScanSummaryPath `
    -MaximumBytes 1MB `
    -Context 'web scan summary'
$backendSbomResult = Read-BoundedJsonDocument `
    -Path $BackendSbomPath `
    -MaximumBytes 100MB `
    -Context 'backend SBOM'
$webSbomResult = Read-BoundedJsonDocument `
    -Path $WebSbomPath `
    -MaximumBytes 100MB `
    -Context 'web SBOM'

$releaseManifest = $releaseManifestResult.Document
$sourceSet = $sourceSetResult.Document
$backendScan = $backendScanResult.Document
$webScan = $webScanResult.Document

if ($releaseManifest.repository -ne 'SadPossum/BunkFy' -or
    $releaseManifest.releaseKind -ne 'composition') {
    throw 'Image evidence must be generated from the BunkFy composition.'
}

$rootCommit = Invoke-GitText `
    -WorkingDirectory $repositoryRoot `
    -Arguments @('rev-parse', 'HEAD')
$backendRoot = Join-Path $repositoryRoot 'apps/backend'
$webRoot = Join-Path $repositoryRoot 'apps/web'
$backendCommit = Invoke-GitText `
    -WorkingDirectory $backendRoot `
    -Arguments @('rev-parse', 'HEAD')
$webCommit = Invoke-GitText `
    -WorkingDirectory $webRoot `
    -Arguments @('rev-parse', 'HEAD')
Assert-CommitSha -Value $rootCommit -Context 'Root commit'
Assert-CommitSha -Value $backendCommit -Context 'Backend commit'
Assert-CommitSha -Value $webCommit -Context 'Web commit'

if ($sourceSet.schemaVersion -ne 2 -or
    $sourceSet.rootCommit -ne $rootCommit) {
    throw 'Recursive source set does not identify the current root commit.'
}

$sourceRepositories = @($sourceSet.repositories)
if ($sourceRepositories.Count -lt 3 -or
    @($sourceRepositories | Where-Object { $_.dirty }).Count -gt 0) {
    throw 'Recursive source set is incomplete or dirty.'
}
foreach ($component in @(
        @{ Path = 'apps/backend'; Commit = $backendCommit },
        @{ Path = 'apps/web'; Commit = $webCommit }
    )) {
    $record = @(
        $sourceRepositories |
            Where-Object { $_.path -eq $component.Path }
    )
    if ($record.Count -ne 1 -or
        $record[0].commit -ne $component.Commit) {
        throw "Recursive source set does not identify '$($component.Path)'."
    }
}

foreach ($scan in @(
        @{ Name = 'backend'; Value = $backendScan },
        @{ Name = 'web'; Value = $webScan }
    )) {
    if ($scan.Value.schemaVersion -ne 1 -or
        $scan.Value.artifactName -ne $scan.Name -or
        @('passed', 'blocked', 'error') -notcontains
            $scan.Value.gateStatus) {
        throw "$($scan.Name) scan summary is invalid."
    }
}

if ($backendSbomResult.Document.bomFormat -ne 'CycloneDX' -or
    $webSbomResult.Document.bomFormat -ne 'CycloneDX') {
    throw 'Image SBOM evidence must use CycloneDX.'
}

$backendDigest = Get-BuildDigest `
    -Metadata $backendMetadataResult.Document `
    -Context 'Backend build metadata'
$webDigest = Get-BuildDigest `
    -Metadata $webMetadataResult.Document `
    -Context 'Web build metadata'

$backendDockerfile = Join-Path $backendRoot 'Dockerfile'
$webDockerfile = Join-Path $webRoot 'Dockerfile'
$backendDockerfileHash = (
    Get-FileHash -LiteralPath $backendDockerfile -Algorithm SHA256
).Hash.ToLowerInvariant()
$webDockerfileHash = (
    Get-FileHash -LiteralPath $webDockerfile -Algorithm SHA256
).Hash.ToLowerInvariant()

$gateStatuses = @($backendScan.gateStatus, $webScan.gateStatus)
$gateStatus = if ($gateStatuses -contains 'error') {
    'error'
}
elseif ($gateStatuses -contains 'blocked') {
    'blocked'
}
else {
    'passed'
}

$manifestPath = Join-Path $resolvedOutputDirectory 'manifest.json'
$manifest = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    repository = $releaseManifest.repository
    candidate = [ordered]@{
        sourceCommit = $rootCommit
        sourceRef = if (
            [string]::IsNullOrWhiteSpace($env:GITHUB_REF)) {
            $null
        }
        else {
            $env:GITHUB_REF
        }
        workflowRunId = if (
            [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
            $null
        }
        else {
            $env:GITHUB_RUN_ID
        }
        sourceSet = Get-RootRelativePath $sourceSetResult.Path
    }
    gateStatus = $gateStatus
    images = @(
        [ordered]@{
            name = 'backend'
            localName = 'bunkfy/backend'
            platform = 'linux/amd64'
            sourceCommit = $rootCommit
            componentCommit = $backendCommit
            context = 'apps/backend'
            dockerfile = 'apps/backend/Dockerfile'
            dockerfileSha256 = $backendDockerfileHash
            target = 'backend'
            manifestDigest = $backendDigest
            buildMetadata = Get-RootRelativePath $backendMetadataResult.Path
            sbom = Get-RootRelativePath $backendSbomResult.Path
            scanSummary = Get-RootRelativePath $backendScanResult.Path
            scanStatus = $backendScan.gateStatus
            published = $false
        },
        [ordered]@{
            name = 'web'
            localName = 'bunkfy/web'
            platform = 'linux/amd64'
            sourceCommit = $rootCommit
            componentCommit = $webCommit
            context = 'apps/web'
            dockerfile = 'apps/web/Dockerfile'
            dockerfileSha256 = $webDockerfileHash
            target = 'web'
            manifestDigest = $webDigest
            buildMetadata = Get-RootRelativePath $webMetadataResult.Path
            sbom = Get-RootRelativePath $webSbomResult.Path
            scanSummary = Get-RootRelativePath $webScanResult.Path
            scanStatus = $webScan.gateStatus
            published = $false
        }
    )
    publication = [ordered]@{
        enabled = $false
        registry = $null
        imageReferences = @()
        reason = 'No approved immutable image publication channel is configured.'
    }
}
Write-JsonDocument -Path $manifestPath -Value $manifest

$checksumsPath = Join-Path $resolvedOutputDirectory 'checksums.sha256'
$checksumLines = @(
    Get-ChildItem -LiteralPath $resolvedOutputDirectory -File -Recurse |
        Where-Object { $_.FullName -ne $checksumsPath } |
        Sort-Object {
            Get-RelativePathUnder `
                -BasePath $resolvedOutputDirectory `
                -Path $_.FullName
        } |
        ForEach-Object {
            $relativePath = Get-RelativePathUnder `
                -BasePath $resolvedOutputDirectory `
                -Path $_.FullName
            $hash = (
                Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            "$hash  $relativePath"
        }
)
[System.IO.File]::WriteAllText(
    $checksumsPath,
    (($checksumLines -join "`n").TrimEnd() + "`n"),
    [System.Text.UTF8Encoding]::new($false))

Write-Host "Product image evidence written to '$resolvedOutputDirectory'."
