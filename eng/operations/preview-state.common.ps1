Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BunkFyPreviewStateContractName = 'bunkfy-preview-state'
$script:BunkFyPreviewStateContractVersion = 1
$script:BunkFyPreviewManifestDigestFileName = 'manifest.sha256'
$script:BunkFyPreviewProtectedLedgerLogicalName = 'data-rights-ledger-delta'
$script:BunkFyPreviewStateArchives = [ordered]@{
    'minio-data' = 'minio-data.tar.gz'
    'nats-data' = 'nats-data.tar.gz'
    'redis-data' = 'redis-data.tar.gz'
    'data-protection' = 'data-protection.tar.gz'
    'adapter-file-drop' = 'adapter-file-drop.tar.gz'
    'data-rights-ledger-delta' = 'data-rights-ledger-delta.tar.gz'
}

function Get-BunkFyPreviewStateContract {
    param([Parameter(Mandatory = $true)][object] $Manifest)

    $schemaVersion = 0
    $schemaProperty = $Manifest.PSObject.Properties['schemaVersion']
    if ($null -eq $schemaProperty -or
        -not [int]::TryParse([string]$schemaProperty.Value, [ref]$schemaVersion)) {
        throw 'Backup manifest schema is missing or invalid.'
    }

    if ($schemaVersion -eq 2) {
        return [pscustomobject]@{
            Name = $script:BunkFyPreviewStateContractName
            Version = 1
        }
    }
    if ($schemaVersion -notin @(3, 4)) {
        throw "Backup manifest schema '$schemaVersion' is not supported."
    }

    $contractProperty = $Manifest.PSObject.Properties['stateContract']
    if ($null -eq $contractProperty -or $null -eq $contractProperty.Value) {
        throw 'Backup manifest state contract is missing.'
    }

    $contract = $contractProperty.Value
    $version = 0
    $nameProperty = $contract.PSObject.Properties['name']
    $versionProperty = $contract.PSObject.Properties['version']
    if ($null -eq $nameProperty -or
        [string]::IsNullOrWhiteSpace([string]$nameProperty.Value) -or
        $null -eq $versionProperty -or
        -not [int]::TryParse([string]$versionProperty.Value, [ref]$version) -or
        $version -lt 1) {
        throw 'Backup manifest state contract is invalid.'
    }

    return [pscustomobject]@{
        Name = [string]$nameProperty.Value
        Version = $version
    }
}

function Assert-BunkFyRegularFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description '$Path' does not exist."
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "$Description '$Path' must be a regular file."
    }

    return $item
}

function Assert-BunkFySha256Digest {
    param(
        [Parameter(Mandatory = $true)][string] $Value,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name must be a lowercase SHA-256 digest."
    }
}

function Assert-BunkFyBackupManifestIntegrity {
    param(
        [Parameter(Mandatory = $true)][string] $ManifestPath,
        [Parameter(Mandatory = $true)][int] $SchemaVersion,
        [string] $ExpectedSha256
    )

    [void](Assert-BunkFyRegularFile `
            -Path $ManifestPath `
            -Description 'Backup manifest')
    $actual = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        Assert-BunkFySha256Digest `
            -Value $ExpectedSha256 `
            -Name 'ExpectedManifestSha256'
        if ($actual -cne $ExpectedSha256) {
            throw 'Backup manifest does not match ExpectedManifestSha256.'
        }
    }

    if ($SchemaVersion -ge 4) {
        $digestPath = Join-Path (
            Split-Path -Parent $ManifestPath) $script:BunkFyPreviewManifestDigestFileName
        [void](Assert-BunkFyRegularFile `
                -Path $digestPath `
                -Description 'Backup manifest digest')
        $recorded = [IO.File]::ReadAllText($digestPath).Trim()
        Assert-BunkFySha256Digest `
            -Value $recorded `
            -Name 'Backup manifest digest'
        if ($actual -cne $recorded) {
            throw 'Backup manifest failed SHA-256 sidecar verification.'
        }
    }

    return $actual
}

function Get-BunkFyStateTreeFingerprint {
    param([Parameter(Mandatory = $true)][string] $Path)

    $root = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "State tree '$root' does not exist."
    }
    $rootItem = Get-Item -LiteralPath $root -Force
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "State tree '$root' must not be a reparse point."
    }

    $entries = @(Get-ChildItem -LiteralPath $root -Recurse -Force)
    foreach ($entry in $entries) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "State tree '$root' contains a reparse point."
        }
    }
    $filesByPath = [Collections.Generic.Dictionary[string, IO.FileInfo]]::new(
        [StringComparer]::Ordinal)
    foreach ($entry in @($entries | Where-Object { -not $_.PSIsContainer })) {
        $relativePath = [IO.Path]::GetRelativePath($root, $entry.FullName).Replace('\', '/')
        if (-not $filesByPath.TryAdd($relativePath, $entry)) {
            throw "State tree '$root' contains ambiguous file paths."
        }
    }
    $relativePaths = [string[]]@($filesByPath.Keys)
    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    $records = [Text.StringBuilder]::new()
    $totalBytes = [long]0
    foreach ($relativePath in $relativePaths) {
        $file = $filesByPath[$relativePath]
        $digest = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        [void]$records.Append($relativePath)
        [void]$records.Append("`0")
        [void]$records.Append($file.Length.ToString(
                [Globalization.CultureInfo]::InvariantCulture))
        [void]$records.Append("`0")
        [void]$records.Append($digest)
        [void]$records.Append("`n")
        $totalBytes += $file.Length
    }

    $canonicalBytes = [Text.UTF8Encoding]::new($false).GetBytes($records.ToString())
    $treeDigest = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($canonicalBytes)).ToLowerInvariant()
    return [pscustomobject]@{
        FileCount = $relativePaths.Count
        TotalBytes = $totalBytes
        Sha256 = $treeDigest
    }
}

function Assert-BunkFyPreviewStateContractCompatible {
    param([Parameter(Mandatory = $true)][object] $Contract)

    if ($Contract.Name -cne $script:BunkFyPreviewStateContractName -or
        $Contract.Version -ne $script:BunkFyPreviewStateContractVersion) {
        throw "Backup state contract '$($Contract.Name)/$($Contract.Version)' is not supported by this checkout."
    }
}

function Assert-BunkFyGitCommitRecord {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($Value -isnot [string] -or
        $Value -notmatch '^[0-9a-f]{40}$' -or
        $Value -eq ('0' * 40)) {
        throw "Backup manifest Git record '$Name' is invalid."
    }
}

function Get-BunkFyPreviewComposeDefinition {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $ComposePath,
        [Parameter(Mandatory = $true)][string] $EnvironmentPath
    )

    Push-Location -LiteralPath $Root
    try {
        $json = @(& docker compose --env-file $EnvironmentPath -f $ComposePath `
            config --format json)
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to resolve the preview Compose configuration.'
        }
    }
    finally {
        Pop-Location
    }

    try {
        return ($json -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        throw "Unable to parse the resolved preview Compose configuration: $($_.Exception.Message)"
    }
}

function Get-BunkFyPreviewVolumeMap {
    param([Parameter(Mandatory = $true)][object] $ComposeDefinition)

    $map = [ordered]@{}
    $names = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $logicalNames = @('postgres-data') + @($script:BunkFyPreviewStateArchives.Keys)
    foreach ($logicalName in $logicalNames) {
        $property = $ComposeDefinition.volumes.PSObject.Properties[$logicalName]
        $dockerName = if ($null -eq $property) {
            $null
        }
        else {
            [string]$property.Value.name
        }

        if ([string]::IsNullOrWhiteSpace($dockerName)) {
            throw "Preview Compose volume '$logicalName' has no resolved Docker name."
        }
        if (-not $names.Add($dockerName)) {
            throw "Preview Compose resolves multiple state volumes to '$dockerName'."
        }

        $map[$logicalName] = $dockerName
    }

    return $map
}

function Get-BunkFyGitCommit {
    param([Parameter(Mandatory = $true)][string] $RepositoryPath)

    $output = @(& git -C $RepositoryPath rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$output[0])) {
        throw "Unable to resolve the Git commit at '$RepositoryPath'."
    }

    return ([string]$output[0]).Trim()
}

function Assert-BunkFyGitWorktreeClean {
    param([Parameter(Mandatory = $true)][string] $RepositoryPath)

    $status = @(& git -C $RepositoryPath status --porcelain=v1 `
        --untracked-files=no --ignore-submodules=none)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect the Git worktree at '$RepositoryPath'."
    }
    if ($status.Count -gt 0) {
        throw "Git worktree '$RepositoryPath' has tracked changes."
    }
}

function Get-BunkFyDockerImageId {
    param([Parameter(Mandatory = $true)][string] $Reference)

    $imageId = @(& docker image inspect --format '{{.Id}}' $Reference)
    if ($LASTEXITCODE -ne 0 -or $imageId.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$imageId[0])) {
        throw "Docker image '$Reference' is not available locally."
    }

    return ([string]$imageId[0]).Trim()
}
