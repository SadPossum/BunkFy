[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'common.ps1')

$root = Get-BunkFyRepositoryRoot
$skeletonSecurityRevision = 'ec0e1345ce36f2d2e25e6fad231bc031f690b255'
$requiredFiles = @(
    '.github\dependabot.yml',
    '.github\workflows\codeql.yml',
    '.github\workflows\security.yml',
    '.gma\repository-security.json',
    '.gma\security-exceptions.json',
    'SECURITY.md'
)

foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relativePath) -PathType Leaf)) {
        throw "Missing repository security baseline file '$relativePath'."
    }
}

function Read-BoundedJsonDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RelativePath,

        [Parameter(Mandatory = $true)]
        [int] $MaximumBytes,

        [Parameter(Mandatory = $true)]
        [string] $Context
    )

    $path = Join-Path $root $RelativePath
    $fileInfo = [System.IO.FileInfo]::new($path)
    if ($fileInfo.Length -gt $MaximumBytes) {
        throw "$Context file exceeds its size limit."
    }

    try {
        $document = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
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

function Assert-BoundedText {
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [string] $Context,

        [Parameter(Mandatory = $true)]
        [int] $MinimumLength,

        [Parameter(Mandatory = $true)]
        [int] $MaximumLength
    )

    if ($Value -isnot [string] -or
        $Value.Length -lt $MinimumLength -or
        $Value.Length -gt $MaximumLength -or
        $Value -match '[\x00-\x1F\x7F]') {
        throw "$Context is not valid bounded text."
    }
}

function Get-OptionalStringArray {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [string] $PropertyName,

        [Parameter(Mandatory = $true)]
        [string] $Context,

        [Parameter(Mandatory = $true)]
        [int] $MaximumItemLength
    )

    if ($Value.PSObject.Properties.Name -notcontains $PropertyName) {
        return @()
    }

    $items = $Value.$PropertyName
    if ($null -eq $items -or $items -isnot [System.Array]) {
        throw "$Context.$PropertyName must be an array."
    }

    $values = @($items)
    if ($values.Count -gt 16) {
        throw "$Context.$PropertyName contains too many entries."
    }

    foreach ($item in $values) {
        Assert-BoundedText `
            -Value $item `
            -Context "$Context.$PropertyName entry" `
            -MinimumLength 1 `
            -MaximumLength $MaximumItemLength
    }
    if (@($values | Select-Object -Unique).Count -ne $values.Count) {
        throw "$Context.$PropertyName contains duplicate entries."
    }

    return $values
}

$repositoryManifest = Read-BoundedJsonDocument `
    -RelativePath '.gma\repository-security.json' `
    -MaximumBytes 16KB `
    -Context 'Repository security manifest'
Assert-ClosedObject `
    -Value $repositoryManifest `
    -AllowedProperties @(
        'schemaVersion',
        'repository',
        'securityBaseline',
        'dependencyEcosystems'
    ) `
    -Context 'Repository security manifest'
if ($repositoryManifest.schemaVersion -ne 1 -or
    $repositoryManifest.repository -ne 'SadPossum/BunkFy') {
    throw 'Repository security manifest identity is invalid.'
}

Assert-ClosedObject `
    -Value $repositoryManifest.securityBaseline `
    -AllowedProperties @('repository', 'commit') `
    -Context 'Repository security baseline reference'
if ($repositoryManifest.securityBaseline.repository -ne 'SadPossum/GMA-Skeleton' -or
    $repositoryManifest.securityBaseline.commit -ne $skeletonSecurityRevision) {
    throw 'Repository security baseline reference is invalid.'
}

$dependencyEcosystems = @($repositoryManifest.dependencyEcosystems)
$expectedDependencyEcosystems = @('github-actions', 'gitsubmodule')
if ($repositoryManifest.dependencyEcosystems -isnot [System.Array] -or
    $dependencyEcosystems.Count -ne $expectedDependencyEcosystems.Count -or
    @($dependencyEcosystems | Select-Object -Unique).Count -ne
        $dependencyEcosystems.Count -or
    @($dependencyEcosystems |
        Where-Object { $expectedDependencyEcosystems -notcontains $_ }).Count -gt 0) {
    throw 'Repository dependency ecosystems are invalid.'
}

$exceptionDocument = Read-BoundedJsonDocument `
    -RelativePath '.gma\security-exceptions.json' `
    -MaximumBytes 64KB `
    -Context 'Security exception'
Assert-ClosedObject `
    -Value $exceptionDocument `
    -AllowedProperties @('schemaVersion', 'exceptions') `
    -Context 'Security exception document'
if ($exceptionDocument.schemaVersion -ne 1 -or
    $exceptionDocument.exceptions -isnot [System.Array]) {
    throw 'Security exception document shape is invalid.'
}

$exceptions = @($exceptionDocument.exceptions)
if ($exceptions.Count -gt 100) {
    throw 'Security exception document exceeds the 100-entry limit.'
}

$observedDate = [datetime]::UtcNow.Date
$latestExpiryDate = $observedDate.AddDays(90)
$exceptionIdentities = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)
for ($index = 0; $index -lt $exceptions.Count; $index++) {
    $exception = $exceptions[$index]
    $context = "Security exception $index"
    if ($null -eq $exception -or
        $exception -is [string] -or
        $exception -is [System.Array]) {
        throw "$context must be an object."
    }

    Assert-ClosedObject `
        -Value $exception `
        -AllowedProperties @(
            'scanner',
            'findingId',
            'owner',
            'reason',
            'expiresOn',
            'paths',
            'purls'
        ) `
        -Context $context

    foreach ($requiredProperty in @(
        'scanner',
        'findingId',
        'owner',
        'reason',
        'expiresOn')) {
        if ($exception.PSObject.Properties.Name -notcontains $requiredProperty) {
            throw "$context is missing required metadata."
        }
    }

    Assert-BoundedText `
        -Value $exception.scanner `
        -Context "$context.scanner" `
        -MinimumLength 1 `
        -MaximumLength 32
    if (@('vulnerability', 'misconfiguration', 'secret', 'license') -notcontains
        $exception.scanner) {
        throw "$context scanner is unsupported."
    }
    Assert-BoundedText `
        -Value $exception.findingId `
        -Context "$context.findingId" `
        -MinimumLength 1 `
        -MaximumLength 200
    Assert-BoundedText `
        -Value $exception.owner `
        -Context "$context.owner" `
        -MinimumLength 1 `
        -MaximumLength 100
    Assert-BoundedText `
        -Value $exception.reason `
        -Context "$context.reason" `
        -MinimumLength 10 `
        -MaximumLength 500
    Assert-BoundedText `
        -Value $exception.expiresOn `
        -Context "$context.expiresOn" `
        -MinimumLength 10 `
        -MaximumLength 10

    $expiryDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(
        $exception.expiresOn,
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref] $expiryDate) -or
        $expiryDate.Date -le $observedDate -or
        $expiryDate.Date -gt $latestExpiryDate) {
        throw "$context expiry is invalid."
    }

    $paths = @(
        Get-OptionalStringArray `
            -Value $exception `
            -PropertyName 'paths' `
            -Context $context `
            -MaximumItemLength 256
    )
    foreach ($path in $paths) {
        if ([System.IO.Path]::IsPathRooted($path) -or
            $path -match '^[A-Za-z]:[\\/]' -or
            $path -match '^[\\/]' -or
            $path -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "$context.paths must contain repository-relative paths."
        }
    }

    $purls = @(
        Get-OptionalStringArray `
            -Value $exception `
            -PropertyName 'purls' `
            -Context $context `
            -MaximumItemLength 512
    )
    if ($purls.Count -gt 0 -and $exception.scanner -ne 'vulnerability') {
        throw "$context.purls is valid only for vulnerability findings."
    }
    foreach ($purl in $purls) {
        if (-not $purl.StartsWith('pkg:', [System.StringComparison]::Ordinal)) {
            throw "$context.purls entries must be package URLs."
        }
    }
    if ($paths.Count -eq 0 -and $purls.Count -eq 0) {
        throw "$context must be narrowed by paths or purls."
    }

    $identity = @(
        $exception.scanner,
        $exception.findingId,
        (@($paths | Sort-Object) -join [char] 0x1F),
        (@($purls | Sort-Object) -join [char] 0x1F)
    ) -join [char] 0x1F
    if (-not $exceptionIdentities.Add($identity)) {
        throw "$context duplicates another exception scope."
    }
}

$securityWorkflow = [System.IO.File]::ReadAllText(
    (Join-Path $root '.github\workflows\security.yml'))
$requiredSecurityTokens = @(
    "SadPossum/GMA-Skeleton/.github/actions/security-baseline@$skeletonSecurityRevision",
    'Validate repository security policy',
    './eng/check-repository-security.ps1',
    'exception-file: .gma/security-exceptions.json',
    'github/codeql-action/upload-sarif@7188fc363630916deb702c7fdcf4e481b751f97a',
    'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
    'security-events: write',
    'if-no-files-found: error',
    'retention-days: 30'
)
foreach ($token in $requiredSecurityTokens) {
    if ($securityWorkflow.IndexOf($token, [System.StringComparison]::Ordinal) -lt 0) {
        throw "BunkFy security workflow is missing required token '$token'."
    }
}

$codeQlWorkflow = [System.IO.File]::ReadAllText(
    (Join-Path $root '.github\workflows\codeql.yml'))
foreach ($token in @(
    'github/codeql-action/init@7188fc363630916deb702c7fdcf4e481b751f97a',
    'github/codeql-action/analyze@7188fc363630916deb702c7fdcf4e481b751f97a',
    'language: csharp',
    'language: javascript-typescript',
    'build-mode: manual',
    'build-mode: none')) {
    if ($codeQlWorkflow.IndexOf($token, [System.StringComparison]::Ordinal) -lt 0) {
        throw "BunkFy CodeQL workflow is missing required token '$token'."
    }
}

$dependabot = [System.IO.File]::ReadAllText((Join-Path $root '.github\dependabot.yml'))
foreach ($token in @('package-ecosystem: github-actions', 'package-ecosystem: gitsubmodule')) {
    if ($dependabot.IndexOf($token, [System.StringComparison]::Ordinal) -lt 0) {
        throw "BunkFy dependency update policy is missing required token '$token'."
    }
}

$securityPolicy = [System.IO.File]::ReadAllText((Join-Path $root 'SECURITY.md'))
foreach ($token in @(
    'Supported Versions',
    'private vulnerability reporting form',
    'https://github.com/SadPossum/BunkFy/security/advisories/new',
    'not approved for hosted processing of real guest data')) {
    if ($securityPolicy.IndexOf($token, [System.StringComparison]::Ordinal) -lt 0) {
        throw "BunkFy security policy is missing required token '$token'."
    }
}

$usesPattern = [regex]'(?m)^\s*-?\s*uses:\s*([^\s#]+)'
$actionFiles = Get-ChildItem -LiteralPath (Join-Path $root '.github') -Recurse -File |
    Where-Object { $_.Extension -in @('.yml', '.yaml') }
foreach ($file in $actionFiles) {
    $content = [System.IO.File]::ReadAllText($file.FullName)
    foreach ($match in $usesPattern.Matches($content)) {
        $reference = $match.Groups[1].Value
        if ($reference.StartsWith('./', [System.StringComparison]::Ordinal)) {
            continue
        }

        if ($reference -notmatch '^[^@\s]+@[0-9a-fA-F]{40}$') {
            $relativePath = [System.IO.Path]::GetRelativePath($root, $file.FullName)
            throw "GitHub Action reference '$reference' in '$relativePath' is not pinned to an immutable commit."
        }
    }
}

Write-Host "BunkFy security policy, evidence workflows, and Skeleton baseline pin $skeletonSecurityRevision are valid."
