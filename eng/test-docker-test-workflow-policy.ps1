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
    'missing comparison dependency' = $content.Replace('needs: [plan, storage-fixture, provider-tests, ordinary-control, ordinary-compare]', 'needs: [plan, storage-fixture, provider-tests, ordinary-control]')
    'ignored comparison result' = $content.Replace('test "$COMPARISON_RESULT" = success', 'true')
    'optional storage qualification' = $content.Replace('  storage-fixture:', "  storage-fixture:`n    continue-on-error: true")
    'skipped storage qualification' = $content.Replace('  storage-fixture:', "  storage-fixture:`n    if: false")
    'changed raw-scan command' = $content.Replace('exit "$scan_status"', 'exit 0')
    'ignored inventory failure' = $content.Replace('test "$inventory_status" -eq 0 || exit "$inventory_status"', 'true')
    'conditional storage classifier' = $content.Replace("name: Require exact reviewed provenance and zero unresolved findings`n        if: always()", "name: Require exact reviewed provenance and zero unresolved findings`n        if: success()")
    'missing storage final dependency' = $content.Replace('needs: [plan, storage-fixture, provider-tests, ordinary-control, ordinary-compare]', 'needs: [plan, provider-tests, ordinary-control, ordinary-compare]')
    'ignored storage result' = $content.Replace('test "$STORAGE_RESULT" = success', 'true')
    'provider bypasses storage producer' = $content.Replace('    needs: [plan, storage-fixture]', '    needs: plan')
    'wrong transferred image identity' = $content.Replace('EXPECTED_FIXTURE_ID: ${{ needs.storage-fixture.outputs.image-id }}', "EXPECTED_FIXTURE_ID: 'unverified'")
    'ignored classifier failure' = $content.Replace(' --scanner-exit-code "$SCAN_EXIT_CODE"', ' --scanner-exit-code "$SCAN_EXIT_CODE" || true')
    'ignored native provider failure' = $content.Replace('run: python3 eng/test-docker-groups.py --group "${{ matrix.group }}"', 'run: python3 eng/test-docker-groups.py --group "${{ matrix.group }}" || true')
}
foreach ($name in $mutants.Keys) {
    if ($mutants[$name] -ceq $content) { throw "Fixture mutation '$name' did not alter the actual workflow." }
    $rejected = $false
    try { Assert-BunkFyDockerTestWorkflow -Content $mutants[$name] } catch { $rejected = $true }
    if (-not $rejected) { throw "Docker workflow policy accepted '$name'." }
}
Write-Host "Docker workflow policy fixtures passed: actual LF/CRLF workflow and $($mutants.Count) rejected gate bypasses."
