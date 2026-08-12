Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BunkFyWorkspaceAccessEstateSchemaVersion = 1
$script:BunkFyWorkspaceAccessSeedVersion = 4
$script:BunkFyWorkspaceAccessSeedProfileCount = 4
$script:BunkFyWorkspaceAccessMaximumJsonBytes = 1MB

function Invoke-BunkFyWorkspaceAccessProcess {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $cancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        if (-not $process.Start()) {
            throw "$Description could not be started."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = $false
        try {
            [void]$process.WaitForExitAsync($cancellation.Token).GetAwaiter().GetResult()
        }
        catch [OperationCanceledException] {
            $timedOut = $true
            if (-not $process.HasExited) {
                [void]$process.Kill($true)
            }
            [void]$process.WaitForExit()
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($timedOut) {
            throw "$Description exceeded the $TimeoutSeconds-second timeout."
        }
        if ([Text.Encoding]::UTF8.GetByteCount($stdout) -gt
            $script:BunkFyWorkspaceAccessMaximumJsonBytes -or
            [Text.Encoding]::UTF8.GetByteCount($stderr) -gt
            $script:BunkFyWorkspaceAccessMaximumJsonBytes) {
            throw "$Description exceeded the bounded output size."
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $stdout
            StandardError = $stderr
        }
    }
    finally {
        [void]$cancellation.Dispose()
        [void]$process.Dispose()
    }
}

function Assert-BunkFyWorkspaceAccessExactProperties {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if ($null -eq $Value) {
        throw "$Description is missing."
    }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Expected.Count) {
        throw "$Description does not have the expected closed shape."
    }

    $expectedNames = [Collections.Generic.HashSet[string]]::new(
        $Expected,
        [StringComparer]::Ordinal)
    foreach ($name in $actual) {
        if (-not $expectedNames.Contains([string]$name)) {
            throw "$Description contains unexpected property '$name'."
        }
    }
}

function ConvertFrom-BunkFyWorkspaceAccessJsonObject {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Json,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $byteCount = [Text.Encoding]::UTF8.GetByteCount($Json)
    if ($byteCount -lt 2 -or $byteCount -gt $script:BunkFyWorkspaceAccessMaximumJsonBytes) {
        throw "$Description JSON is empty or exceeds the bounded response size."
    }

    try {
        $value = $Json | ConvertFrom-Json -Depth 8 -DateKind String
    }
    catch {
        throw "$Description is not valid JSON."
    }
    if ($null -eq $value -or $value -is [Array] -or $value -is [string] -or
        $value -is [ValueType]) {
        throw "$Description must be one JSON object."
    }

    return $value
}

function ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Description,
        [long] $Maximum = [int]::MaxValue
    )

    $isInteger =
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    if ($null -eq $Value -or -not $isInteger) {
        throw "$Description must be an integer."
    }

    $parsed = [long]0
    if (-not [long]::TryParse(
            [string]$Value,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed) -or
        $parsed -lt 0 -or
        $parsed -gt $Maximum) {
        throw "$Description is outside the allowed range."
    }

    return $parsed
}

function Assert-BunkFyWorkspaceAccessBoundedString {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter(Mandatory = $true)][int] $MaximumLength,
        [switch] $DisallowWhitespace
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt $MaximumLength -or
        $Value -cne $Value.Trim()) {
        throw "$Description is missing or invalid."
    }
    foreach ($character in $Value.ToCharArray()) {
        if ([char]::IsControl($character) -or
            ($DisallowWhitespace -and [char]::IsWhiteSpace($character))) {
            throw "$Description contains unsupported characters."
        }
    }
}

function Get-BunkFyWorkspaceAccessSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-BunkFyWorkspaceAccessFingerprint {
    param(
        [Parameter(Mandatory = $true)][Guid] $OrganizationId,
        [Parameter(Mandatory = $true)][string] $ScopeId
    )

    return Get-BunkFyWorkspaceAccessSha256 -Value (
        "bunkfy-workspace-access-estate-v1`0$($OrganizationId.ToString('D'))`0$ScopeId")
}

function ConvertFrom-BunkFyOrganizationCatalogPage {
    param(
        [Parameter(Mandatory = $true)][string] $Json,
        [Parameter(Mandatory = $true)][int] $ExpectedPage,
        [Parameter(Mandatory = $true)][int] $ExpectedPageSize
    )

    $value = ConvertFrom-BunkFyWorkspaceAccessJsonObject `
        -Json $Json `
        -Description 'Organizations catalog response'
    Assert-BunkFyWorkspaceAccessExactProperties `
        -Value $value `
        -Expected @('items', 'page', 'pageSize', 'hasMore') `
        -Description 'Organizations catalog response'

    $page = ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
        -Value $value.page `
        -Description 'Organizations catalog page'
    $pageSize = ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
        -Value $value.pageSize `
        -Description 'Organizations catalog page size'
    if ($page -ne $ExpectedPage -or $pageSize -ne $ExpectedPageSize) {
        throw 'Organizations catalog pagination does not match the requested page.'
    }
    if ($value.hasMore -isnot [bool]) {
        throw 'Organizations catalog hasMore must be a boolean.'
    }
    if ($null -eq $value.items -or $value.items -is [string] -or
        $value.items -isnot [Collections.IEnumerable]) {
        throw 'Organizations catalog items must be an array.'
    }

    $items = [Collections.Generic.List[object]]::new()
    foreach ($item in @($value.items)) {
        Assert-BunkFyWorkspaceAccessExactProperties `
            -Value $item `
            -Expected @(
                'organizationId',
                'scopeId',
                'name',
                'slug',
                'status',
                'activeOwnerCount',
                'version',
                'createdAtUtc',
                'lastChangedAtUtc') `
            -Description 'Organizations catalog item'

        $organizationId = [Guid]::Empty
        if ($item.organizationId -isnot [string] -or
            -not [Guid]::TryParseExact(
                [string]$item.organizationId,
                'D',
                [ref]$organizationId) -or
            $organizationId -eq [Guid]::Empty) {
            throw 'Organizations catalog item has an invalid organization id.'
        }
        Assert-BunkFyWorkspaceAccessBoundedString `
            -Value $item.scopeId `
            -Description 'Organizations catalog scope id' `
            -MaximumLength 128 `
            -DisallowWhitespace
        Assert-BunkFyWorkspaceAccessBoundedString `
            -Value $item.name `
            -Description 'Organizations catalog name' `
            -MaximumLength 256
        Assert-BunkFyWorkspaceAccessBoundedString `
            -Value $item.slug `
            -Description 'Organizations catalog slug' `
            -MaximumLength 128 `
            -DisallowWhitespace

        if ($item.status -isnot [string] -or
            [string]$item.status -cnotin @('active', 'suspended', 'archived')) {
            throw 'Organizations catalog item has an unsupported status.'
        }
        $activeOwnerCount = ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
            -Value $item.activeOwnerCount `
            -Description 'Organizations catalog active owner count'
        $version = ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
            -Value $item.version `
            -Description 'Organizations catalog version' `
            -Maximum ([long]::MaxValue)
        if ($version -lt 1) {
            throw 'Organizations catalog version must be positive.'
        }
        foreach ($dateProperty in @('createdAtUtc', 'lastChangedAtUtc')) {
            $timestamp = [DateTimeOffset]::MinValue
            if ($item.$dateProperty -isnot [string] -or
                -not [DateTimeOffset]::TryParse(
                    [string]$item.$dateProperty,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind,
                    [ref]$timestamp)) {
                throw "Organizations catalog item has an invalid $dateProperty."
            }
        }

        $items.Add([pscustomobject]@{
                OrganizationId = $organizationId
                ScopeId = [string]$item.scopeId
                Status = [string]$item.status
                ActiveOwnerCount = [int]$activeOwnerCount
                Version = [long]$version
                Fingerprint = Get-BunkFyWorkspaceAccessFingerprint `
                    -OrganizationId $organizationId `
                    -ScopeId ([string]$item.scopeId)
            })
    }
    if ($items.Count -gt $ExpectedPageSize -or
        ($value.hasMore -and $items.Count -ne $ExpectedPageSize)) {
        throw 'Organizations catalog page cardinality is inconsistent with hasMore.'
    }

    return [pscustomobject]@{
        Page = [int]$page
        PageSize = [int]$pageSize
        HasMore = [bool]$value.hasMore
        Items = [object[]]$items.ToArray()
    }
}

function Get-BunkFyWorkspaceAccessCatalogFingerprint {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Items)

    $records = @($Items |
        Sort-Object -Property Fingerprint |
        ForEach-Object {
            "$($_.Fingerprint)`0$($_.Status)`0$($_.Version)`n"
        })
    return Get-BunkFyWorkspaceAccessSha256 -Value ($records -join '')
}

function ConvertFrom-BunkFyWorkspaceAccessStatus {
    param([Parameter(Mandatory = $true)][string] $Json)

    $value = ConvertFrom-BunkFyWorkspaceAccessJsonObject `
        -Json $Json `
        -Description 'Workspace access status response'
    Assert-BunkFyWorkspaceAccessExactProperties `
        -Value $value `
        -Expected @(
            'seedVersion',
            'expectedSeedProfileCount',
            'activeSeedProfileCount',
            'driftedSeedProfileCount',
            'archivedSeedProfileCount',
            'legacyMemberCount',
            'markerMemberCount',
            'requiresBackfill') `
        -Description 'Workspace access status response'

    $status = [pscustomobject]@{
        SeedVersion = [int](ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
                -Value $value.seedVersion -Description 'Workspace access seed version')
        ExpectedSeedProfileCount = [int](ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
                -Value $value.expectedSeedProfileCount -Description 'Workspace access expected seed count')
        ActiveSeedProfileCount = [int](ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
                -Value $value.activeSeedProfileCount -Description 'Workspace access active seed count')
        DriftedSeedProfileCount = [int](ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
                -Value $value.driftedSeedProfileCount -Description 'Workspace access drifted seed count')
        ArchivedSeedProfileCount = [int](ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
                -Value $value.archivedSeedProfileCount -Description 'Workspace access archived seed count')
        LegacyMemberCount = [int](ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
                -Value $value.legacyMemberCount -Description 'Workspace access legacy member count')
        MarkerMemberCount = [int](ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
                -Value $value.markerMemberCount -Description 'Workspace access marker member count')
        RequiresBackfill = if ($value.requiresBackfill -is [bool]) {
            [bool]$value.requiresBackfill
        }
        else {
            throw 'Workspace access requiresBackfill must be a boolean.'
        }
    }
    $derivedRequiresBackfill =
        $status.ActiveSeedProfileCount -ne $status.ExpectedSeedProfileCount -or
        $status.DriftedSeedProfileCount -ne 0 -or
        $status.ArchivedSeedProfileCount -ne 0 -or
        $status.LegacyMemberCount -ne 0
    if ($status.RequiresBackfill -ne $derivedRequiresBackfill) {
        throw 'Workspace access status has inconsistent backfill state.'
    }

    return $status
}

function ConvertFrom-BunkFyWorkspaceAccessBootstrapResult {
    param([Parameter(Mandatory = $true)][string] $Json)

    $value = ConvertFrom-BunkFyWorkspaceAccessJsonObject `
        -Json $Json `
        -Description 'Workspace access bootstrap response'
    Assert-BunkFyWorkspaceAccessExactProperties `
        -Value $value `
        -Expected @('seedVersion', 'seedProfileCount', 'migratedMemberCount') `
        -Description 'Workspace access bootstrap response'

    return [pscustomobject]@{
        SeedVersion = [int](ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
                -Value $value.seedVersion -Description 'Workspace access bootstrap seed version')
        SeedProfileCount = [int](ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
                -Value $value.seedProfileCount -Description 'Workspace access bootstrap seed count')
        MigratedMemberCount = [int](ConvertTo-BunkFyWorkspaceAccessNonNegativeInteger `
                -Value $value.migratedMemberCount -Description 'Workspace access migrated member count')
    }
}

function Test-BunkFyWorkspaceAccessStatusConverged {
    param([Parameter(Mandatory = $true)][object] $Status)

    return (
        $Status.SeedVersion -eq $script:BunkFyWorkspaceAccessSeedVersion -and
        $Status.ExpectedSeedProfileCount -eq $script:BunkFyWorkspaceAccessSeedProfileCount -and
        $Status.ActiveSeedProfileCount -eq $script:BunkFyWorkspaceAccessSeedProfileCount -and
        $Status.DriftedSeedProfileCount -eq 0 -and
        $Status.ArchivedSeedProfileCount -eq 0 -and
        $Status.LegacyMemberCount -eq 0 -and
        -not $Status.RequiresBackfill)
}

function Assert-BunkFyWorkspaceAccessBootstrapTransition {
    param(
        [Parameter(Mandatory = $true)][object] $Before,
        [Parameter(Mandatory = $true)][object] $Bootstrap,
        [Parameter(Mandatory = $true)][object] $After
    )

    if ($Bootstrap.SeedVersion -ne $script:BunkFyWorkspaceAccessSeedVersion -or
        $Bootstrap.SeedProfileCount -ne $script:BunkFyWorkspaceAccessSeedProfileCount -or
        $Bootstrap.MigratedMemberCount -ne $Before.LegacyMemberCount) {
        throw 'Workspace access bootstrap result does not match the inspected state.'
    }
    if ($After.MarkerMemberCount -lt $Before.MarkerMemberCount) {
        throw 'Workspace access bootstrap reduced membership-marker coverage.'
    }
    if (-not (Test-BunkFyWorkspaceAccessStatusConverged -Status $After)) {
        throw 'Workspace access bootstrap did not converge the workspace.'
    }
}

function ConvertTo-BunkFyWorkspaceAccessStatusEvidence {
    param([Parameter(Mandatory = $true)][object] $Status)

    return [ordered]@{
        seedVersion = $Status.SeedVersion
        expectedSeedProfileCount = $Status.ExpectedSeedProfileCount
        activeSeedProfileCount = $Status.ActiveSeedProfileCount
        driftedSeedProfileCount = $Status.DriftedSeedProfileCount
        archivedSeedProfileCount = $Status.ArchivedSeedProfileCount
        legacyMemberCount = $Status.LegacyMemberCount
        markerMemberCount = $Status.MarkerMemberCount
        requiresBackfill = $Status.RequiresBackfill
        converged = Test-BunkFyWorkspaceAccessStatusConverged -Status $Status
    }
}
