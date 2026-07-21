[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'common.ps1')

$root = Get-BunkFyRepositoryRoot
$skeletonSecurityRevision = '63f071af1ae746883433e795f2130ffcdbbf21f0'
$requiredFiles = @(
    '.github\dependabot.yml',
    '.github\workflows\codeql.yml',
    '.github\workflows\security.yml',
    'SECURITY.md'
)

foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relativePath) -PathType Leaf)) {
        throw "Missing repository security baseline file '$relativePath'."
    }
}

$securityWorkflow = [System.IO.File]::ReadAllText(
    (Join-Path $root '.github\workflows\security.yml'))
$requiredSecurityTokens = @(
    "SadPossum/GMA-Skeleton/.github/actions/security-baseline@$skeletonSecurityRevision",
    'github/codeql-action/upload-sarif@7188fc363630916deb702c7fdcf4e481b751f97a',
    'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
    'security-events: write',
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
