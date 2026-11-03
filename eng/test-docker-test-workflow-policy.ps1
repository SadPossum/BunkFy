[CmdletBinding()]
param([string] $RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $RepositoryRoot 'eng/docker-test-workflow-policy.common.ps1')
$content = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'apps/backend/.github/workflows/docker-tests.yml'))
Assert-BunkFyDockerTestWorkflow -Content $content
Assert-BunkFyDockerTestWorkflow -Content ($content.Replace("`r`n", "`n").Replace("`n", "`r`n"))
$mutants = [ordered]@{
    'missing PR trigger' = $content.Replace('  pull_request:', '')
    'filtered PR gate' = $content.Replace('  pull_request:', "  pull_request:`n    paths: ['docs/**']")
    'missing manual trigger' = $content.Replace('  workflow_dispatch:', '')
    'privileged PR trigger' = $content.Replace('  pull_request:', '  pull_request_target:')
    'optional native providers' = $content.Replace("  GMA_REQUIRE_DOCKER_TESTS: 'true'", "  GMA_REQUIRE_DOCKER_TESTS: 'false'")
    'unbounded provider concurrency' = $content.Replace('max-parallel: 3', 'max-parallel: 8')
    'skipped provider job' = $content.Replace('  provider-tests:', "  provider-tests:`n    if: false")
    'optional provider failure' = $content.Replace('  provider-tests:', "  provider-tests:`n    continue-on-error: true")
    'wrong predecessor source' = $content.Replace('ref: ${{ needs.plan.outputs.control-sha }}', 'ref: dev')
    'wrong candidate fingerprint' = $content.Replace('CANDIDATE_FINGERPRINT: ${{ github.sha }}', 'CANDIDATE_FINGERPRINT: ${{ github.event.pull_request.base.sha }}')
    'missing artifact digest rejection' = $content.Replace('digest-mismatch: error', 'digest-mismatch: warn')
    'missing comparison dependency' = $content.Replace('needs: [plan, provider-tests, ordinary-control, ordinary-compare]', 'needs: [plan, provider-tests, ordinary-control]')
    'ignored comparison result' = $content.Replace('test "$COMPARISON_RESULT" = success', 'true')
}
foreach ($name in $mutants.Keys) {
    if ($mutants[$name] -ceq $content) { throw "Fixture mutation '$name' did not alter the actual workflow." }
    $rejected = $false
    try { Assert-BunkFyDockerTestWorkflow -Content $mutants[$name] } catch { $rejected = $true }
    if (-not $rejected) { throw "Docker workflow policy accepted '$name'." }
}
Write-Host "Docker workflow policy fixtures passed: actual LF/CRLF workflow and $($mutants.Count) rejected gate bypasses."
