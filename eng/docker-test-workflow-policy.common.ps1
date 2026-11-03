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
    if ($Content -match '(?m)^[\t ]*continue-on-error:') {
        throw 'Docker provider and comparison failures must not be optional.'
    }
    $environment = Get-RequiredSection $Content 'env' 0
    Require-Pattern $environment '(?m)^  GMA_REQUIRE_DOCKER_TESTS:[\t ]*(?:true|''true''|"true")[\t ]*\r?$' 'mandatory native-provider execution'
    Require-Pattern $environment '(?m)^  DOTNET_PROCESSOR_COUNT:[\t ]*(?:[12]|''[12]''|"[12]")[\t ]*\r?$' 'bounded per-process concurrency'
    $jobs = Get-RequiredSection $Content 'jobs' 0
    $blocks = @{}
    foreach ($name in @('plan', 'provider-tests', 'ordinary-control', 'ordinary-compare', 'docker')) {
        $blocks[$name] = Get-RequiredSection $jobs $name 2
        if ($name -ne 'docker' -and $blocks[$name] -match '(?m)^    if:') {
            throw "Required Docker job '$name' must not be conditionally skipped."
        }
    }
    foreach ($command in @('python3 eng/test-docker-groups.tests.py',
            'python3 eng/compare-ordinary-behavior.tests.py',
            'python3 eng/test-docker-groups.py --matrix')) {
        if (-not $blocks['plan'].Contains($command, [StringComparison]::Ordinal)) {
            throw "Docker provider plan is missing '$command'."
        }
    }
    Require-Pattern $blocks['provider-tests'] '(?m)^    needs: plan[\t ]*\r?$' 'provider plan dependency'
    Require-Pattern $blocks['provider-tests'] '(?m)^      max-parallel: [1-3][\t ]*\r?$' 'bounded provider groups'
    Require-Pattern $blocks['provider-tests'] '(?m)^      fail-fast: false[\t ]*\r?$' 'execution of every planned group'
    foreach ($token in @('matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}',
            'run: python3 eng/test-docker-groups.py --group "${{ matrix.group }}"')) {
        if (-not $blocks['provider-tests'].Contains($token, [StringComparison]::Ordinal)) {
            throw "Docker provider execution is missing '$token'."
        }
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
    Require-Pattern $blocks['docker'] '(?m)^    needs: \[plan, provider-tests, ordinary-control, ordinary-compare\][\t ]*\r?$' 'all final result dependencies'
    foreach ($pair in @(@('PLAN_RESULT', 'plan'), @('PROVIDER_RESULT', 'provider-tests'),
            @('CONTROL_RESULT', 'ordinary-control'), @('COMPARISON_RESULT', 'ordinary-compare'))) {
        $line = $pair[0] + ': ${{ needs.' + $pair[1] + '.result }}'
        if (-not $blocks['docker'].Contains($line, [StringComparison]::Ordinal)) {
            throw "Docker final gate is missing '$line'."
        }
    }
    $command = [regex]::Match($blocks['docker'], '(?ms)^        run: >-\r?\n(?<body>.*)\z')
    $expected = 'test "$PLAN_RESULT" = success && test "$PROVIDER_RESULT" = success && test "$CONTROL_RESULT" = success && test "$COMPARISON_RESULT" = success'
    if (-not $command.Success -or
        ([regex]::Replace($command.Groups['body'].Value.Trim(), '\s+', ' ')) -cne $expected) {
        throw 'Docker final gate must require success from every provider and parity job.'
    }
}
