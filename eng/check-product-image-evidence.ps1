[CmdletBinding()]
param([string] $RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$root = [System.IO.Path]::GetFullPath($RepositoryRoot)

function Read-TextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RelativePath,

        [long] $MaximumBytes = 128KB
    )

    $path = Join-Path $root $RelativePath
    if (-not [System.IO.File]::Exists($path)) {
        throw "Missing product image evidence file '$RelativePath'."
    }
    if ([System.IO.FileInfo]::new($path).Length -gt $MaximumBytes) {
        throw "Product image evidence file '$RelativePath' exceeds its size limit."
    }

    return [System.IO.File]::ReadAllText($path)
}

function Assert-PowerShellSyntax {
    param([Parameter(Mandatory = $true)][string] $RelativePath)

    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root $RelativePath),
        [ref] $tokens,
        [ref] $errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw "PowerShell syntax validation failed for '$RelativePath'."
    }
}

function Assert-DigestPinnedDockerfile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RelativePath,

        [Parameter(Mandatory = $true)]
        [int] $ExpectedExternalBaseImageCount
    )

    $content = Read-TextFile -RelativePath $RelativePath
    $firstLine = @($content -split "`r?`n")[0]
    if ($firstLine -notmatch
        '^#\s*syntax=.+@sha256:[0-9a-f]{64}$') {
        throw "'$RelativePath' does not pin its Dockerfile frontend by digest."
    }

    $fromLines = @(
        $content -split "`r?`n" |
            Where-Object { $_ -match '^FROM\s+' }
    )
    $knownStages = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $externalBaseImageCount = 0
    foreach ($line in $fromLines) {
        $match = [regex]::Match(
            $line,
            '^FROM\s+(?<source>\S+)(?:\s+AS\s+(?<stage>[A-Za-z0-9_.-]+))?$')
        if (-not $match.Success) {
            throw "'$RelativePath' contains an invalid FROM instruction."
        }

        $source = $match.Groups['source'].Value
        if (-not $knownStages.Contains($source)) {
            if ($source -notmatch '^.+@sha256:[0-9a-f]{64}$') {
                throw "'$RelativePath' contains a base image that is not digest-pinned."
            }
            $externalBaseImageCount++
        }

        if ($match.Groups['stage'].Success) {
            [void] $knownStages.Add($match.Groups['stage'].Value)
        }
    }
    if ($externalBaseImageCount -ne $ExpectedExternalBaseImageCount) {
        throw "'$RelativePath' has an unexpected external base-image count."
    }
}

$workflow = Read-TextFile `
    -RelativePath '.github/workflows/image-evidence.yml' `
    -MaximumBytes 64KB
$requiredWorkflowTokens = @(
    'name: Product Image Evidence',
    'workflow_dispatch:',
    'submodules: recursive',
    'persist-credentials: false',
    './eng/check-repository-release.ps1',
    './eng/check-product-image-evidence.ps1',
    './eng/export-source-set.ps1',
    '-RequireClean',
    './apps/backend/eng/gma-bootstrap.ps1',
    'docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c',
    'docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a',
    'aquasecurity/setup-trivy@3fb12ec12f41e471780db15c232d5dd185dcb514',
    'version: v0.70.0',
    'context: apps/backend',
    'file: apps/backend/Dockerfile',
    'target: backend',
    'context: apps/web',
    'file: apps/web/Dockerfile',
    'target: web',
    'platforms: ${{ env.IMAGE_PLATFORM }}',
    'outputs: type=oci,dest=${{ runner.temp }}/bunkfy-backend.oci.tar',
    'outputs: type=oci,dest=${{ runner.temp }}/bunkfy-web.oci.tar',
    'BACKEND_BUILD_METADATA: ${{ steps.build-backend.outputs.metadata }}',
    'WEB_BUILD_METADATA: ${{ steps.build-web.outputs.metadata }}',
    'push: false',
    './eng/scan-oci-image.ps1',
    './eng/write-image-evidence.ps1',
    'github/codeql-action/upload-sarif@7188fc363630916deb702c7fdcf4e481b751f97a',
    'actions/attest@f7c74d28b9d84cb8768d0b8ca14a4bac6ef463e6',
    'subject-checksums: artifacts/image-evidence/checksums.sha256',
    'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
    'path: artifacts/image-evidence',
    'retention-days: 30',
    'attestations: write',
    'id-token: write',
    'security-events: write'
)
foreach ($token in $requiredWorkflowTokens) {
    if ($workflow.IndexOf(
            $token,
            [System.StringComparison]::Ordinal) -lt 0) {
        throw "Product image evidence workflow is missing '$token'."
    }
}

if ([regex]::Matches(
        $workflow,
        'docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count -ne 2) {
    throw 'Product image evidence must build exactly two OCI images.'
}
if ([regex]::Matches(
        $workflow,
        '(?im)^\s*push:\s*false\s*$').Count -ne 2) {
    throw 'Each product image build must explicitly disable publication.'
}
if ([regex]::Matches(
        $workflow,
        '\./eng/scan-oci-image\.ps1',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count -ne 2) {
    throw 'Product image evidence must scan each OCI image exactly once.'
}
if ([regex]::Matches(
        $workflow,
        '\./eng/write-image-evidence\.ps1',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count -ne 1) {
    throw 'Product image evidence must create one closed evidence manifest.'
}

foreach ($forbiddenPattern in @(
        '(?im)^\s*push:\s*$',
        '(?im)^\s*pull_request:\s*$',
        '(?im)^\s*schedule:\s*$',
        '(?im)^\s*contents:\s*write\s*$',
        '(?im)^\s*packages:\s*write\s*$',
        '(?im)^\s*push:\s*true\s*$',
        '(?i)docker/login-action@',
        '(?i)docker\s+push(?:\s|$)',
        '(?i)docker\s+buildx\s+build[\s\S]*?--push(?:\s|$)',
        '(?im)^\s*outputs:\s*type=registry',
        '(?i)ghcr\.io'
    )) {
    if ([regex]::IsMatch($workflow, $forbiddenPattern)) {
        throw "Product image evidence workflow enables a forbidden publication path."
    }
}

foreach ($script in @(
        'eng/scan-oci-image.ps1',
        'eng/write-image-evidence.ps1'
    )) {
    Assert-PowerShellSyntax -RelativePath $script
}

$scanner = Read-TextFile -RelativePath 'eng/scan-oci-image.ps1'
foreach ($token in @(
        'Get-Command tar -CommandType Application',
        'Select-Object -First 1',
        "'oci-layout'",
        "'index.json'",
        "'blobs'",
        '--input', '$expandedOciDirectory',
        '[System.IO.Directory]::Delete($expandedOciDirectory, $true)'
    )) {
    if ($scanner.IndexOf(
            $token,
            [System.StringComparison]::Ordinal) -lt 0) {
        throw "OCI image scanner is missing '$token'."
    }
}

Assert-DigestPinnedDockerfile `
    -RelativePath 'apps/backend/Dockerfile' `
    -ExpectedExternalBaseImageCount 2
Assert-DigestPinnedDockerfile `
    -RelativePath 'apps/web/Dockerfile' `
    -ExpectedExternalBaseImageCount 2

foreach ($component in @('apps/backend', 'apps/web')) {
    $dependabot = Read-TextFile `
        -RelativePath "$component/.github/dependabot.yml"
    if ($dependabot.IndexOf(
            'package-ecosystem: docker',
            [System.StringComparison]::Ordinal) -lt 0) {
        throw "'$component' does not schedule Docker dependency updates."
    }
}

$dockerWorkflow = Read-TextFile `
    -RelativePath 'apps/backend/.github/workflows/docker-tests.yml'
foreach ($token in @('schedule:', 'workflow_dispatch:')) {
    if ($dockerWorkflow.IndexOf(
            $token,
            [System.StringComparison]::Ordinal) -lt 0) {
        throw "Docker integration workflow is missing '$token'."
    }
}
foreach ($forbiddenPattern in @(
        '(?im)^\s*push:\s*$',
        '(?im)^\s*pull_request:\s*$'
    )) {
    if ([regex]::IsMatch($dockerWorkflow, $forbiddenPattern)) {
        throw 'Docker integration tests must be manual or scheduled, not per change.'
    }
}

$task = Read-TextFile `
    -RelativePath 'docs/operations/product-image-evidence.md' `
    -MaximumBytes 64KB
foreach ($token in @(
        'candidate-only',
        'No registry',
        'No deployment',
        'linux/amd64',
        'HIGH and CRITICAL'
    )) {
    if ($task.IndexOf(
            $token,
            [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Product image evidence note is missing '$token'."
    }
}

Write-Host 'Product image evidence policy is valid; publication remains disabled.'
