Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$operationsPath = Join-Path $PSScriptRoot 'operations'
$testsPath = Join-Path $PSScriptRoot 'tests'
$commonPath = Join-Path $operationsPath 'preview-browser-onboarding.common.mjs'
$driverPath = Join-Path $operationsPath 'rehearse-preview-browser-onboarding.mjs'
$workspaceAccessContributorPath = Join-Path $operationsPath 'preview-browser-workspace-access-administration.mjs'
$operatorPath = Join-Path $operationsPath 'rehearse-preview-browser-onboarding.ps1'
$testPath = Join-Path $testsPath 'preview-browser-onboarding.common.test.mjs'
$composePath = Join-Path (Join-Path $root 'deploy') 'preview/compose.yaml'
$environmentPath = '/home/artem/deployments/bunkfy-preview/.env'

foreach ($path in @($commonPath, $driverPath, $workspaceAccessContributorPath, $operatorPath, $testPath, $composePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Preview browser rehearsal fixture is missing '$path'."
    }
}

& node --test $testPath
if ($LASTEXITCODE -ne 0) {
    throw 'Preview browser onboarding Node contract tests failed.'
}

& node --check $commonPath
if ($LASTEXITCODE -ne 0) {
    throw 'Preview browser onboarding common helper has invalid syntax.'
}
& node --check $driverPath
if ($LASTEXITCODE -ne 0) {
    throw 'Preview browser onboarding driver has invalid syntax.'
}
& node --check $workspaceAccessContributorPath
if ($LASTEXITCODE -ne 0) {
    throw 'Preview browser workspace-access contributor has invalid syntax.'
}

$webPackagePath = Join-Path (Join-Path $root 'apps') 'web/package.json'
$webPackage = Get-Content -LiteralPath $webPackagePath -Raw |
    ConvertFrom-Json
if ([string]$webPackage.devDependencies.'@playwright/test' -notmatch '^[0-9]+[.][0-9]+[.][0-9]+$') {
    throw 'Playwright must be pinned to one exact package version.'
}
if ([string]$webPackage.scripts.'browser:install' -cne 'playwright install chromium') {
    throw 'The browser installer must remain Chromium-only.'
}

$driver = Get-Content -LiteralPath $driverPath -Raw
$workspaceAccessContributor = Get-Content -LiteralPath $workspaceAccessContributorPath -Raw
$browserSources = $driver + "`n" + $workspaceAccessContributor
foreach ($forbidden in @(
        'screenshot(',
        'recordVideo',
        'tracing.start',
        'trace: ''on''',
        'video: ''on''',
        '/api/access-control/',
        '/api/admin/',
        'Invoke-Sqlcmd',
        'NpgsqlConnection',
        'psql ')) {
    if ($browserSources.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Preview browser rehearsal enables forbidden artifact '$forbidden'."
    }
}
foreach ($required in @(
        'assertReleaseIdentity(',
        'stopPreviewWorker(',
        'startPreviewWorker(',
        'assertSecretCleared(',
        'removeNonOwnerMembers(',
        'runPreviewWorkspaceAccessAdministration(',
        'ensureWorkspaceAccessProfileArchived(',
        'archiveWorkspace(',
        'sanitizedFailure(')) {
    if (-not $driver.Contains($required, [StringComparison]::Ordinal)) {
        throw "Preview browser rehearsal is missing required guard '$required'."
    }
}
foreach ($required in @(
        '/api/workspace-access/profiles',
        '/api/workspace-access/members/',
        '/api/access/permissions/evaluate',
        '/api/properties/',
        'custom-role-created-through-browser',
        'custom-role-reassignment-least-privilege',
        'custom-role-update-live-permissions',
        'custom-role-unassigned-and-archived')) {
    if (-not $workspaceAccessContributor.Contains($required, [StringComparison]::Ordinal)) {
        throw "Preview browser workspace-access contributor is missing required guard '$required'."
    }
}
$tokens = $null
$parseErrors = $null
$operatorAst = [Management.Automation.Language.Parser]::ParseFile(
    $operatorPath,
    [ref]$tokens,
    [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
    throw 'Preview browser operator has invalid PowerShell syntax.'
}
$indexedExpressions = @($operatorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IndexExpressionAst] -and
            $node.Target -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.Target.VariablePath.UserPath -cin @(
                'containerIds',
                'networkIds',
                'health',
                'published',
                'attachments')
        }, $true))
if ($indexedExpressions.Count -ne 0) {
    throw 'Preview browser operator must select validated scalar values without string indexing.'
}

$operator = Get-Content -LiteralPath $operatorPath -Raw
foreach ($required in @(
        'SupportsShouldProcess = $true',
        'Restore-BrowserRehearsalWorker',
        'Close-BrowserRehearsalMailpit',
        'IncludeCustomProfileAdministration',
        'BUNKFY_BROWSER_INCLUDE_CUSTOM_PROFILE_ADMINISTRATION',
        '$process.Kill($true)',
        'Write-BunkFyLocalSensitiveTextFile')) {
    if (-not $operator.Contains($required, [StringComparison]::Ordinal)) {
        throw "Preview browser operator is missing required guard '$required'."
    }
}

if (Test-Path -LiteralPath $environmentPath -PathType Leaf) {
    $moduleUri = [Uri]::new($commonPath).AbsoluteUri
    $expression = @"
import { assertPreviewCompose } from '$moduleUri';
assertPreviewCompose(process.argv[1], process.argv[2], 'bunkfy-preview');
"@
    & node --input-type=module -e $expression $composePath $environmentPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Preview browser onboarding Compose ownership guard failed.'
    }

    & $operatorPath `
        -PublicOrigin 'https://preview.example.test' `
        -ExpectedReleaseId 'preview-browser-fixture' `
        -EnvironmentPath $environmentPath `
        -IncludeCustomProfileAdministration `
        -WhatIf | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Preview browser onboarding WhatIf guard failed.'
    }
}

Write-Host 'BunkFy Preview browser onboarding rehearsal fixture passed.'
