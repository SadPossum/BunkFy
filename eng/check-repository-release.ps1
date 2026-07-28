[CmdletBinding()]
param(
    [string] $RepositoryRoot,

    [switch] $LocalImplementation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = if (
        (Split-Path -Leaf $PSScriptRoot) -eq 'repository-release') {
        Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    else {
        Split-Path -Parent $PSScriptRoot
    }
}
$root = [System.IO.Path]::GetFullPath($RepositoryRoot)

function Assert-ClosedObject {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [string[]] $AllowedProperties,

        [Parameter(Mandatory = $true)]
        [string] $Context
    )

    $unknownProperties = @(
        $Value.PSObject.Properties.Name |
            Where-Object { $AllowedProperties -notcontains $_ }
    )
    if ($unknownProperties.Count -gt 0) {
        throw "$Context contains unsupported properties."
    }
}

function Read-JsonDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [int] $MaximumBytes,

        [Parameter(Mandatory = $true)]
        [string] $Context
    )

    if (-not [System.IO.File]::Exists($Path)) {
        throw "Missing $Context file."
    }

    $fileInfo = [System.IO.FileInfo]::new($Path)
    if ($fileInfo.Length -gt $MaximumBytes) {
        throw "$Context file exceeds its size limit."
    }

    try {
        $document = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    }
    catch {
        throw "$Context file is not valid JSON."
    }

    if ($null -eq $document -or
        $document -is [string] -or
        $document -is [System.Array]) {
        throw "$Context file must contain an object."
    }

    return $document
}

function Assert-RepositoryRelativePath {
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [string] $Context
    )

    if ($Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Value) -or
        [System.IO.Path]::IsPathRooted($Value) -or
        $Value -match '^[A-Za-z]:[\\/]' -or
        $Value -match '^[\\/]' -or
        $Value -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "$Context must be a repository-relative path."
    }
}

$requiredFiles = @(
    '.github\workflows\security.yml',
    '.github\workflows\release-evidence.yml',
    '.gma\release-evidence.json',
    '.gma\security-exceptions.json',
    'eng\check-repository-security.ps1',
    'SUPPORT.md'
)
if ($LocalImplementation) {
    $requiredFiles += @(
        '.github\actions\security-baseline\action.yml',
        '.github\actions\source-release-evidence\action.yml',
        '.github\actions\source-release-evidence\create-source-release-evidence.ps1'
    )
}
else {
    $requiredFiles += '.gma\repository-security.json'
}

foreach ($relativePath in $requiredFiles) {
    if (-not [System.IO.File]::Exists((Join-Path $root $relativePath))) {
        throw "Missing repository release baseline file '$relativePath'."
    }
}

$manifest = Read-JsonDocument `
    -Path (Join-Path $root '.gma\release-evidence.json') `
    -MaximumBytes 16KB `
    -Context 'release-evidence manifest'
Assert-ClosedObject `
    -Value $manifest `
    -AllowedProperties @(
        'schemaVersion',
        'repository',
        'artifactName',
        'releaseKind',
        'releaseEvidence',
        'sourceSetPath'
    ) `
    -Context 'Release-evidence manifest'
if ($manifest.schemaVersion -ne 1 -or
    $manifest.repository -isnot [string] -or
    $manifest.repository -notmatch
        '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
    $manifest.artifactName -isnot [string] -or
    $manifest.artifactName -notmatch
        '^[a-z0-9][a-z0-9.-]{1,63}$' -or
    @('source', 'composition') -notcontains $manifest.releaseKind) {
    throw 'Release-evidence manifest identity is invalid.'
}

if ($null -eq $manifest.releaseEvidence -or
    $manifest.releaseEvidence -is [string] -or
    $manifest.releaseEvidence -is [System.Array]) {
    throw 'Release-evidence implementation reference must be an object.'
}
Assert-ClosedObject `
    -Value $manifest.releaseEvidence `
    -AllowedProperties @('repository', 'commit') `
    -Context 'Release-evidence implementation reference'
if ($manifest.releaseEvidence.repository -ne 'SadPossum/GMA-Skeleton' -or
    $manifest.releaseEvidence.commit -isnot [string] -or
    $manifest.releaseEvidence.commit -notmatch '^[0-9a-f]{40}$' -or
    $manifest.releaseEvidence.commit -eq ('0' * 40)) {
    throw 'Release-evidence implementation reference is invalid.'
}

if ($manifest.releaseKind -eq 'composition') {
    Assert-RepositoryRelativePath `
        -Value $manifest.sourceSetPath `
        -Context 'Composition sourceSetPath'
    if (-not [System.IO.File]::Exists(
            (Join-Path $root 'eng\export-source-set.ps1'))) {
        throw 'A composition release requires eng/export-source-set.ps1.'
    }
}
elseif ($null -ne $manifest.sourceSetPath) {
    throw 'A source release must set sourceSetPath to null.'
}

$securityManifest = $null
if (-not $LocalImplementation) {
    $securityManifest = Read-JsonDocument `
        -Path (Join-Path $root '.gma\repository-security.json') `
        -MaximumBytes 16KB `
        -Context 'repository security manifest'
    if ($null -eq $securityManifest.securityBaseline -or
        $securityManifest.securityBaseline -is [string] -or
        $securityManifest.securityBaseline -is [System.Array]) {
        throw 'Repository security baseline reference must be an object.'
    }
    Assert-ClosedObject `
        -Value $securityManifest.securityBaseline `
        -AllowedProperties @('repository', 'commit') `
        -Context 'Repository security baseline reference'
    if ($securityManifest.repository -ne $manifest.repository -or
        $securityManifest.securityBaseline.repository -ne
            'SadPossum/GMA-Skeleton' -or
        $securityManifest.securityBaseline.commit -isnot [string] -or
        $securityManifest.securityBaseline.commit -notmatch '^[0-9a-f]{40}$' -or
        $securityManifest.securityBaseline.commit -eq ('0' * 40)) {
        throw 'Repository security and release identities do not align.'
    }
}

$remoteUrl = & git -C $root remote get-url origin 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
    throw 'Repository origin URL is unavailable.'
}
$remoteMatch = [regex]::Match(
    $remoteUrl.Trim(),
    '(?i)(?:github\.com(?:-private)?[:/])(?<slug>[^/:\s]+/[^/\s]+?)(?:\.git)?$')
if (-not $remoteMatch.Success -or
    $remoteMatch.Groups['slug'].Value -ne $manifest.repository) {
    throw 'Release-evidence manifest does not match the GitHub origin.'
}

$workflow = [System.IO.File]::ReadAllText(
    (Join-Path $root '.github\workflows\release-evidence.yml'))
$securityWorkflow = [System.IO.File]::ReadAllText(
    (Join-Path $root '.github\workflows\security.yml'))
if ($securityWorkflow.IndexOf(
        'run: ./eng/check-repository-release.ps1',
        [System.StringComparison]::Ordinal) -lt 0) {
    throw 'Security workflow does not validate repository release policy.'
}
$releaseActionReference = if ($LocalImplementation) {
    'uses: ./.github/actions/source-release-evidence'
}
else {
    "uses: $($manifest.releaseEvidence.repository)/.github/actions/source-release-evidence@$($manifest.releaseEvidence.commit)"
}
$securityActionReference = if ($LocalImplementation) {
    'uses: ./.github/actions/security-baseline'
}
else {
    "uses: $($securityManifest.securityBaseline.repository)/.github/actions/security-baseline@$($securityManifest.securityBaseline.commit)"
}

$requiredWorkflowTokens = @(
    'workflow_dispatch:',
    'tags:',
    "- 'v*'",
    $releaseActionReference,
    $securityActionReference,
    'output-directory: artifacts/release-security',
    'exception-file: .gma/security-exceptions.json',
    'actions/attest@f7c74d28b9d84cb8768d0b8ca14a4bac6ef463e6',
    'subject-checksums:',
    'sbom-path:',
    'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
    'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c',
    'attestations: write',
    'id-token: write',
    'contents: write',
    "if: startsWith(github.ref, 'refs/tags/v')",
    "'release',",
    "'create',",
    '& gh @arguments',
    '--verify-tag',
    'assets are immutable',
    'retention-days: 90'
)
if ($manifest.releaseKind -eq 'composition') {
    $requiredWorkflowTokens +=
        './eng/export-source-set.ps1 -RequireClean'
}
foreach ($token in $requiredWorkflowTokens) {
    if ($workflow.IndexOf($token, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Release workflow is missing required token '$token'."
    }
}

foreach ($forbiddenToken in @(
    'pull_request_target:',
    'persist-credentials: true',
    '--clobber',
    'trivy-results.sarif')) {
    if ($workflow.IndexOf(
            $forbiddenToken,
            [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "Release workflow contains forbidden token '$forbiddenToken'."
    }
}

$supportPolicy = [System.IO.File]::ReadAllText(
    (Join-Path $root 'SUPPORT.md'))
foreach ($token in @(
    'Release Channels',
    'Compatibility',
    'End Of Life',
    'no contractual support SLA')) {
    if ($supportPolicy.IndexOf(
            $token,
            [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Support policy is missing required token '$token'."
    }
}

$usesPattern = [regex] '(?m)^\s*-?\s*uses:\s*([^\s#]+)'
$workflowFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $root '.github') -Recurse -File |
        Where-Object { $_.Extension -in @('.yml', '.yaml') }
)
foreach ($file in $workflowFiles) {
    $content = [System.IO.File]::ReadAllText($file.FullName)
    foreach ($match in $usesPattern.Matches($content)) {
        $reference = $match.Groups[1].Value
        if ($reference.StartsWith(
                './',
                [System.StringComparison]::Ordinal)) {
            continue
        }
        if ($reference -notmatch '^[^@\s]+@[0-9a-fA-F]{40}$') {
            $relativePath = $file.FullName.Substring(
                $root.TrimEnd('\', '/').Length).TrimStart('\', '/')
            throw "GitHub Action reference '$reference' in '$relativePath' is not pinned to an immutable commit."
        }
    }
}

Write-Host "Repository release evidence is valid for $($manifest.repository)."
