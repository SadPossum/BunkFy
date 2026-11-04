function Assert-BunkFyDockerTestWorkflow {
    param([Parameter(Mandatory = $true)][string] $Content)

    # Validate this repository's committed workflow layout; structural YAML
    # changes require a corresponding policy review.

    function Get-RequiredSection {
        param([string] $Text, [string] $Name, [int] $Indent)
        $pattern = '(?ms)^' + [regex]::Escape((' ' * $Indent) + $Name) +
            ':\r?\n(?<body>.*?)(?=^[\t ]{0,' + $Indent + '}[^\t \r\n]|\z)'
        $sections = [regex]::Matches($Text, $pattern)
        if ($sections.Count -ne 1) { throw "Docker workflow requires exactly one '$Name' section." }
        return $sections[0].Groups['body'].Value
    }

    function Require-Pattern {
        param([string] $Text, [string] $Pattern, [string] $Description)
        if (-not [regex]::IsMatch($Text, $Pattern)) { throw "Docker workflow is missing $Description." }
    }

    $triggers = Get-RequiredSection $Content 'on' 0
    foreach ($name in @('pull_request', 'schedule', 'workflow_dispatch')) {
        Require-Pattern $triggers ('(?m)^  ' + $name + ':[\t ]*\r?$') "$name trigger"
    }
    $prTrigger = [regex]::Match($triggers,
        '(?ms)^  pull_request:[\t ]*\r?\n(?<body>.*?)(?=^  [^\t \r\n]|\z)')
    if (-not $prTrigger.Success -or
        @($prTrigger.Groups['body'].Value -split '\r?\n' |
            Where-Object { $_ -match '\S' -and $_ -notmatch '^[\t ]*#' }).Count -ne 0) {
        throw 'Docker PR validation must not have branch or path filters.'
    }
    if ($triggers -match '(?m)^  (?:push|pull_request_target):') {
        throw 'Docker tests require PR, scheduled and manual triggers without push or privileged PR triggers.'
    }
    $environment = Get-RequiredSection $Content 'env' 0
    Require-Pattern $environment '(?m)^  GMA_REQUIRE_DOCKER_TESTS:[\t ]*(?:true|''true''|"true")[\t ]*\r?$' 'mandatory native-provider execution'
    Require-Pattern $environment '(?m)^  DOTNET_PROCESSOR_COUNT:[\t ]*(?:[12]|''[12]''|"[12]")[\t ]*\r?$' 'bounded per-process concurrency'
    $jobs = Get-RequiredSection $Content 'jobs' 0
    $blocks = @{}
    foreach ($name in @('plan', 'storage-fixture', 'provider-tests', 'ordinary-control', 'ordinary-compare', 'docker')) {
        $blocks[$name] = Get-RequiredSection $jobs $name 2
        if ($name -ne 'docker' -and $blocks[$name] -match '(?m)^    if:') {
            throw "Required Docker job '$name' must not be conditionally skipped."
        }
    }
    # Raw scanning must retain the known fork finding for the mandatory scoped
    # classifier. Only the exact reviewed raw-scan step may continue on error;
    # no provider, comparison, storage qualification or final gate may do so.
    $rawSteps = [regex]::Matches($blocks['storage-fixture'],
        '(?ms)^      - name: Record raw fixture findings and inventory\r?\n.*?(?=^      - |\z)')
    if ($rawSteps.Count -ne 1) { throw 'The reviewed raw storage scan step is missing or duplicated.' }
    $rawStep = $rawSteps[0].Value
    $rawStepHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($rawStep.Replace("`r`n", "`n").Trim()))).ToLowerInvariant()
    if ($rawStepHash -cne '8f4f0fa6458e77d9740cbb28aa0d4046d90e8fd4135ef85b9fe940387bb25091' -or
        [regex]::Matches($Content, '(?m)^[\t ]*continue-on-error:').Count -ne 1) {
        throw 'Only the exact reviewed raw scan may retain findings without ending the job; qualification failures remain mandatory.'
    }
    $storageSteps = Get-RequiredSection $blocks['storage-fixture'] 'steps' 4
    $storageGates = [regex]::Matches($storageSteps,
        '(?ms)^      - name: Require exact reviewed provenance and zero unresolved findings\r?\n(?<body>.*?)(?=^      - |\z)')
    if ($storageGates.Count -ne 1) { throw 'A single mandatory scoped storage classifier is required.' }
    $storageGate = $storageGates[0].Groups['body'].Value
    Require-Pattern $storageGate '(?m)^        if: always\(\)[\t ]*\r?$' 'unconditional storage classification'
    foreach ($token in @('SCAN_EXIT_CODE: ${{ steps.scan.outputs.exit_code }}',
            'run: python3 eng/operations/check-preview-storage-security.py --directory artifacts/provider-images --derived-identity artifacts/provider-images/minio.json --scanner-exit-code "$SCAN_EXIT_CODE"')) {
        if ($token.Length -gt 0 -and -not $storageGate.Contains($token, [StringComparison]::Ordinal)) {
            throw "Storage qualification is missing '$token'."
        }
    }
    $storageCommand = 'python3 eng/operations/check-preview-storage-security.py --directory artifacts/provider-images --derived-identity artifacts/provider-images/minio.json --scanner-exit-code "$SCAN_EXIT_CODE"'
    Require-Pattern $storageGate ('(?m)^        run: ' + [regex]::Escape($storageCommand) + '[\t ]*\r?$') 'unmasked storage classifier exit status'
    foreach ($command in @('python3 eng/test-docker-groups.tests.py',
            'python3 eng/compare-ordinary-behavior.tests.py',
            'python3 eng/test-docker-groups.py --matrix')) {
        if (-not $blocks['plan'].Contains($command, [StringComparison]::Ordinal)) {
            throw "Docker provider plan is missing '$command'."
        }
    }
    Require-Pattern $blocks['provider-tests'] '(?m)^    needs: \[plan, storage-fixture\][\t ]*\r?$' 'provider plan and qualified storage dependencies'
    Require-Pattern $blocks['provider-tests'] '(?m)^      max-parallel: [1-3][\t ]*\r?$' 'bounded provider groups'
    Require-Pattern $blocks['provider-tests'] '(?m)^      fail-fast: false[\t ]*\r?$' 'execution of every planned group'
    foreach ($token in @('matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}',
            'run: python3 eng/test-docker-groups.py --group "${{ matrix.group }}"',
            'artifact-ids: ${{ needs.storage-fixture.outputs.evidence-artifact-id }}',
            'artifact-ids: ${{ needs.storage-fixture.outputs.image-artifact-id }}',
            'EXPECTED_FIXTURE_ID: ${{ needs.storage-fixture.outputs.image-id }}',
            'sha256sum --check storage-fixture.tar.sha256',
            'test "$actual_id" = "$EXPECTED_FIXTURE_ID"')) {
        if (-not $blocks['provider-tests'].Contains($token, [StringComparison]::Ordinal)) {
            throw "Docker provider execution is missing '$token'."
        }
    }
    $providerCommand = 'python3 eng/test-docker-groups.py --group "${{ matrix.group }}"'
    Require-Pattern $blocks['provider-tests'] ('(?m)^        run: ' + [regex]::Escape($providerCommand) + '[\t ]*\r?$') 'unmasked provider runner exit status'
    if ([regex]::Matches($blocks['provider-tests'], '(?m)^          digest-mismatch: error[\t ]*\r?$').Count -ne 2) {
        throw 'Both qualified fixture artifact downloads must reject digest mismatches.'
    }
    foreach ($token in @('needs: [plan, provider-tests]',
            'ref: ${{ needs.plan.outputs.control-sha }}',
            'submodules: recursive', 'working-directory: control',
            'BFX_CMP_VARIANT: control',
            'BFX_CMP_BUILD_FINGERPRINT: ${{ needs.plan.outputs.control-sha }}',
            'dotnet test tests/Integration.Tests/Integration.Tests.csproj',
            'Category=Docker&FullyQualifiedName~OrdinaryBehaviorComparisonIntegrationTests')) {
        if (-not $blocks['ordinary-control'].Contains($token, [StringComparison]::Ordinal)) {
            throw "Docker predecessor control is missing '$token'."
        }
    }
    foreach ($token in @('needs: [plan, provider-tests, ordinary-control]',
            'CONTROL_FINGERPRINT: ${{ needs.plan.outputs.control-sha }}',
            'CANDIDATE_FINGERPRINT: ${{ github.sha }}',
            'python3 eng/compare-ordinary-behavior.py',
            '--control-fingerprint "$CONTROL_FINGERPRINT"',
            '--candidate-fingerprint "$CANDIDATE_FINGERPRINT"')) {
        if (-not $blocks['ordinary-compare'].Contains($token, [StringComparison]::Ordinal)) {
            throw "Docker parity comparison is missing '$token'."
        }
    }
    if ([regex]::Matches($blocks['ordinary-compare'], '(?m)^          digest-mismatch: error[\t ]*\r?$').Count -ne 2) {
        throw 'Both ordinary comparison artifact downloads must reject digest mismatches.'
    }
    Require-Pattern $blocks['docker'] '(?m)^    if: always\(\)[\t ]*\r?$' 'unconditional final result gate'
    Require-Pattern $blocks['docker'] '(?m)^    needs: \[plan, storage-fixture, provider-tests, ordinary-control, ordinary-compare\][\t ]*\r?$' 'all final result dependencies'
    foreach ($pair in @(@('PLAN_RESULT', 'plan'), @('STORAGE_RESULT', 'storage-fixture'), @('PROVIDER_RESULT', 'provider-tests'),
            @('CONTROL_RESULT', 'ordinary-control'), @('COMPARISON_RESULT', 'ordinary-compare'))) {
        $line = $pair[0] + ': ${{ needs.' + $pair[1] + '.result }}'
        if (-not $blocks['docker'].Contains($line, [StringComparison]::Ordinal)) {
            throw "Docker final gate is missing '$line'."
        }
    }
    $command = [regex]::Match($blocks['docker'], '(?ms)^        run: >-\r?\n(?<body>.*)\z')
    $expected = 'test "$PLAN_RESULT" = success && test "$STORAGE_RESULT" = success && test "$PROVIDER_RESULT" = success && test "$CONTROL_RESULT" = success && test "$COMPARISON_RESULT" = success'
    if (-not $command.Success -or
        ([regex]::Replace($command.Groups['body'].Value.Trim(), '\s+', ' ')) -cne $expected) {
        throw 'Docker final gate must require success from every provider and parity job.'
    }
}
