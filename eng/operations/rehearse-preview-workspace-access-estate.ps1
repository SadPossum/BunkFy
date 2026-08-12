[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][string] $EnvironmentPath,
    [string] $ComposePath,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [ValidateRange(5, 300)][int] $CommandTimeoutSeconds = 60,
    [ValidateRange(1, 100)][int] $PageSize = 100,
    [ValidateRange(1, 100)][int] $MaxPages = 20,
    [ValidateRange(1, 10000)][int] $MaxCatalogWorkspaces = 2000,
    [ValidateRange(1, 500)][int] $MaxActiveWorkspaces = 100,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,127}$')]
    [string] $Actor = 'bootstrap-owner',
    [string] $OutputPath,
    [switch] $Apply,
    [switch] $AllowLoopbackHttp,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'local-sensitive-state.common.ps1')
. (Join-Path $PSScriptRoot 'deployed-public-edge.common.ps1')
. (Join-Path $PSScriptRoot 'preview-state.common.ps1')
. (Join-Path $PSScriptRoot 'preview-workspace-access-estate.common.ps1')

function Remove-BunkFyWorkspaceAccessTransientContainer {
    param(
        [Parameter(Mandatory = $true)][string] $DockerPath,
        [Parameter(Mandatory = $true)][string] $ContainerName,
        [Parameter(Mandatory = $true)][string] $Root
    )

    $inspect = Invoke-BunkFyWorkspaceAccessProcess `
        -FilePath $DockerPath `
        -Arguments @('container', 'inspect', '--format', '{{.Id}}', $ContainerName) `
        -WorkingDirectory $Root `
        -TimeoutSeconds 15 `
        -Description 'Transient Admin CLI container inspection'
    if ($inspect.ExitCode -eq 0) {
        $removed = Invoke-BunkFyWorkspaceAccessProcess `
            -FilePath $DockerPath `
            -Arguments @('container', 'rm', '--force', $ContainerName) `
            -WorkingDirectory $Root `
            -TimeoutSeconds 15 `
            -Description 'Transient Admin CLI container cleanup'
        if ($removed.ExitCode -ne 0) {
            throw 'Transient Admin CLI container cleanup failed.'
        }
    }
    elseif ($inspect.ExitCode -ne 1) {
        throw 'Unable to determine whether the transient Admin CLI container remains.'
    }

    $verify = Invoke-BunkFyWorkspaceAccessProcess `
        -FilePath $DockerPath `
        -Arguments @('container', 'inspect', '--format', '{{.Id}}', $ContainerName) `
        -WorkingDirectory $Root `
        -TimeoutSeconds 15 `
        -Description 'Transient Admin CLI container cleanup verification'
    if ($verify.ExitCode -eq 0) {
        throw 'Transient Admin CLI container remains after cleanup.'
    }
    if ($verify.ExitCode -ne 1) {
        throw 'Transient Admin CLI container cleanup could not be verified.'
    }
}

function Invoke-BunkFyWorkspaceAccessAdminCli {
    param(
        [Parameter(Mandatory = $true)][string] $DockerPath,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $EnvironmentFile,
        [Parameter(Mandatory = $true)][string] $ComposeFile,
        [Parameter(Mandatory = $true)][string] $AdminActor,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Command,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $containerName = 'bunkfy-workspace-access-' + [Guid]::NewGuid().ToString('N')
    $arguments = @(
        'compose',
        '--env-file', $EnvironmentFile,
        '-f', $ComposeFile,
        '--profile', 'tools',
        'run',
        '--rm',
        '--no-deps',
        '-T',
        '--name', $containerName,
        'admin-cli',
        '-a', $AdminActor,
        '-o', 'json') + $Command

    $operationError = $null
    $result = $null
    try {
        $result = Invoke-BunkFyWorkspaceAccessProcess `
            -FilePath $DockerPath `
            -Arguments $arguments `
            -WorkingDirectory $Root `
            -TimeoutSeconds $TimeoutSeconds `
            -Description $Description
    }
    catch {
        $operationError = $_
    }

    $cleanupError = $null
    try {
        Remove-BunkFyWorkspaceAccessTransientContainer `
            -DockerPath $DockerPath `
            -ContainerName $containerName `
            -Root $Root
    }
    catch {
        $cleanupError = $_
    }
    if ($null -ne $cleanupError) {
        if ($null -ne $operationError) {
            throw "$Description failed and its transient container could not be cleaned up."
        }
        throw $cleanupError
    }
    if ($null -ne $operationError) {
        throw $operationError
    }
    if ($result.ExitCode -ne 0) {
        $errorDigest = Get-BunkFyWorkspaceAccessSha256 -Value $result.StandardError
        throw "$Description failed with exit code $($result.ExitCode); stderr SHA-256 $errorDigest."
    }

    return $result.StandardOutput
}

function Get-BunkFyWorkspaceAccessService {
    param(
        [Parameter(Mandatory = $true)][object] $ComposeDefinition,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $property = $ComposeDefinition.services.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "Preview Compose is missing service '$Name'."
    }
    return $property.Value
}

function Get-BunkFyWorkspaceAccessStringValues {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string]) {
        return @([string]$Value)
    }
    return @($Value | ForEach-Object { [string]$_ })
}

function Get-BunkFyWorkspaceAccessNetworkNames {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Networks)

    if ($null -eq $Networks) {
        return @()
    }
    if ($Networks -is [Array]) {
        return @($Networks | ForEach-Object { [string]$_ })
    }
    return @($Networks.PSObject.Properties.Name)
}

function Assert-BunkFyWorkspaceAccessComposeBoundary {
    param([Parameter(Mandatory = $true)][object] $ComposeDefinition)

    $admin = Get-BunkFyWorkspaceAccessService `
        -ComposeDefinition $ComposeDefinition `
        -Name 'admin-cli'
    $api = Get-BunkFyWorkspaceAccessService `
        -ComposeDefinition $ComposeDefinition `
        -Name 'api'
    $adminImage = Assert-BunkFyPreviewImageReference `
        -Value ([string]$admin.image) `
        -Name 'Preview Admin CLI image'
    $apiImage = Assert-BunkFyPreviewImageReference `
        -Value ([string]$api.image) `
        -Name 'Preview API image'
    if ($adminImage -cne $apiImage) {
        throw 'Preview Admin CLI and API must resolve to the same backend image.'
    }

    $profiles = @(Get-BunkFyWorkspaceAccessStringValues -Value $admin.profiles)
    $entrypoint = @(Get-BunkFyWorkspaceAccessStringValues -Value $admin.entrypoint)
    $networks = @(Get-BunkFyWorkspaceAccessNetworkNames -Networks $admin.networks)
    $capDrop = @(Get-BunkFyWorkspaceAccessStringValues -Value $admin.cap_drop)
    $security = @(Get-BunkFyWorkspaceAccessStringValues -Value $admin.security_opt)
    $portsProperty = $admin.PSObject.Properties['ports']
    if ($profiles.Count -ne 1 -or $profiles[0] -cne 'tools' -or
        $entrypoint.Count -ne 2 -or
        $entrypoint[0] -cne 'dotnet' -or
        $entrypoint[1] -cne '/opt/bunkfy/admin-cli/BunkFy.Host.AdminCli.dll' -or
        $networks.Count -ne 1 -or $networks[0] -cne 'backend' -or
        $capDrop -cnotcontains 'ALL' -or
        $security -cnotcontains 'no-new-privileges:true' -or
        $admin.read_only -ne $true -or
        ($null -ne $portsProperty -and @($portsProperty.Value).Count -ne 0)) {
        throw 'Preview Admin CLI does not satisfy the private tools boundary.'
    }

    return $adminImage
}

function Get-BunkFyWorkspaceAccessRuntimeImage {
    param(
        [Parameter(Mandatory = $true)][string] $DockerPath,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $EnvironmentFile,
        [Parameter(Mandatory = $true)][string] $ComposeFile,
        [Parameter(Mandatory = $true)][string] $ImageReference,
        [Parameter(Mandatory = $true)][string] $ExpectedProjectName
    )

    $imageId = Get-BunkFyDockerImageId -Reference $ImageReference
    if ($imageId -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Preview Admin CLI image id is invalid.'
    }
    $containers = Invoke-BunkFyWorkspaceAccessProcess `
        -FilePath $DockerPath `
        -Arguments @(
            'compose', '--env-file', $EnvironmentFile, '-f', $ComposeFile,
            'ps', '--quiet', 'api') `
        -WorkingDirectory $Root `
        -TimeoutSeconds 30 `
        -Description 'Preview API container lookup'
    if ($containers.ExitCode -ne 0) {
        throw 'Preview API container lookup failed.'
    }
    $containerIds = @($containers.StandardOutput -split '\r?\n' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($containerIds.Count -ne 1 -or $containerIds[0] -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Preview API container lookup was ambiguous.'
    }

    $inspection = Invoke-BunkFyWorkspaceAccessProcess `
        -FilePath $DockerPath `
        -Arguments @(
            'container', 'inspect', '--format',
            '{{.Image}}|{{.State.Running}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project"}}',
            $containerIds[0]) `
        -WorkingDirectory $Root `
        -TimeoutSeconds 30 `
        -Description 'Preview API image inspection'
    if ($inspection.ExitCode -ne 0) {
        throw 'Preview API image inspection failed.'
    }
    $parts = @($inspection.StandardOutput.Trim() -split '\|', 4)
    if ($parts.Count -ne 4 -or
        $parts[0] -cne $imageId -or
        $parts[1] -cne 'true' -or
        $parts[2] -cne 'api' -or
        $parts[3] -cne $ExpectedProjectName) {
        throw 'Preview Admin CLI image does not match the running API deployment.'
    }

    return [pscustomobject]@{
        Reference = $ImageReference
        ImageId = $imageId
    }
}

function Get-BunkFyWorkspaceAccessCatalog {
    param(
        [Parameter(Mandatory = $true)][string] $DockerPath,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $EnvironmentFile,
        [Parameter(Mandatory = $true)][string] $ComposeFile,
        [Parameter(Mandatory = $true)][string] $AdminActor,
        [Parameter(Mandatory = $true)][int] $CatalogPageSize,
        [Parameter(Mandatory = $true)][int] $CatalogMaxPages,
        [Parameter(Mandatory = $true)][int] $MaximumCatalogWorkspaces,
        [Parameter(Mandatory = $true)][int] $MaximumActiveWorkspaces,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds
    )

    $items = [Collections.Generic.List[object]]::new()
    $organizationIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $scopeIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $pages = 0
    for ($pageNumber = 1; $pageNumber -le $CatalogMaxPages; $pageNumber++) {
        $json = Invoke-BunkFyWorkspaceAccessAdminCli `
            -DockerPath $DockerPath `
            -Root $Root `
            -EnvironmentFile $EnvironmentFile `
            -ComposeFile $ComposeFile `
            -AdminActor $AdminActor `
            -Command @(
                'organizations', 'list',
                '--page', $pageNumber.ToString([Globalization.CultureInfo]::InvariantCulture),
                '--page-size', $CatalogPageSize.ToString([Globalization.CultureInfo]::InvariantCulture)) `
            -TimeoutSeconds $TimeoutSeconds `
            -Description 'Organizations catalog query'
        $script:workspaceAccessCliInvocationCount++
        $page = ConvertFrom-BunkFyOrganizationCatalogPage `
            -Json $json `
            -ExpectedPage $pageNumber `
            -ExpectedPageSize $CatalogPageSize
        $pages = $pageNumber
        foreach ($item in $page.Items) {
            if (-not $organizationIds.Add($item.OrganizationId.ToString('D')) -or
                -not $scopeIds.Add($item.ScopeId)) {
                throw 'Organizations catalog contains a duplicate identity or scope.'
            }
            $items.Add($item)
            if ($items.Count -gt $MaximumCatalogWorkspaces) {
                throw 'Organizations catalog exceeded the configured workspace bound.'
            }
        }
        if (-not $page.HasMore) {
            break
        }
        if ($pageNumber -eq $CatalogMaxPages) {
            throw 'Organizations catalog exceeded the configured page bound.'
        }
    }

    $active = @($items | Where-Object { $_.Status -ceq 'active' })
    if ($active.Count -gt $MaximumActiveWorkspaces) {
        throw 'Organizations catalog exceeded the configured active-workspace bound.'
    }

    return [pscustomobject]@{
        Pages = $pages
        Items = [object[]]$items.ToArray()
        ActiveItems = [object[]]$active
        ActiveCount = $active.Count
        ArchivedCount = @($items | Where-Object { $_.Status -ceq 'archived' }).Count
        SuspendedCount = @($items | Where-Object { $_.Status -ceq 'suspended' }).Count
        FingerprintSha256 = Get-BunkFyWorkspaceAccessCatalogFingerprint `
            -Items ([object[]]$items.ToArray())
    }
}

function ConvertTo-BunkFyWorkspaceAccessCatalogEvidence {
    param([Parameter(Mandatory = $true)][object] $Catalog)

    return [ordered]@{
        pages = $Catalog.Pages
        totalCount = $Catalog.Items.Count
        activeCount = $Catalog.ActiveCount
        archivedCount = $Catalog.ArchivedCount
        suspendedCount = $Catalog.SuspendedCount
        fingerprintSha256 = $Catalog.FingerprintSha256
    }
}

function ConvertTo-BunkFyWorkspaceAccessWorkspaceEvidence {
    param([Parameter(Mandatory = $true)][object] $State)

    return [ordered]@{
        fingerprintSha256 = $State.Fingerprint
        action = $State.Action
        before = ConvertTo-BunkFyWorkspaceAccessStatusEvidence -Status $State.Before
        bootstrap = if ($null -eq $State.Bootstrap) {
            $null
        }
        else {
            [ordered]@{
                seedVersion = $State.Bootstrap.SeedVersion
                seedProfileCount = $State.Bootstrap.SeedProfileCount
                migratedMemberCount = $State.Bootstrap.MigratedMemberCount
            }
        }
        after = if ($null -eq $State.After) {
            $null
        }
        else {
            ConvertTo-BunkFyWorkspaceAccessStatusEvidence -Status $State.After
        }
    }
}

$root = Get-BunkFyRepositoryRoot
$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackHttp
if ([string]::IsNullOrWhiteSpace($ComposePath)) {
    $ComposePath = Join-BunkFyPath 'deploy/preview/compose.yaml'
}
$ComposePath = [IO.Path]::GetFullPath($ComposePath)
$EnvironmentPath = [IO.Path]::GetFullPath($EnvironmentPath)
foreach ($path in @($ComposePath, $EnvironmentPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required Preview file '$path' does not exist."
    }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Required Preview file '$path' must not be a reparse point."
    }
}
Assert-BunkFyLocalSensitivePath `
    -Path $EnvironmentPath `
    -PathType Leaf `
    -Description 'Preview environment'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/preview-workspace-access-estate-$stamp.json"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $OutputPath
if ($Apply -and $WhatIfPreference) {
    [void]$PSCmdlet.ShouldProcess(
        'active Preview workspace estate',
        'Bootstrap non-converged workspace access seeds')
    return
}
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-BunkFyLocalSensitiveDirectory `
        -Path $outputDirectory `
        -Description 'Workspace access estate evidence directory'
}
else {
    Assert-BunkFyLocalSensitivePath `
        -Path $outputDirectory `
        -PathType Container `
        -Description 'Workspace access estate evidence directory'
}
if (Test-Path -LiteralPath $OutputPath) {
    [void](Assert-BunkFyRegularFile `
            -Path $OutputPath `
            -Description 'Workspace access estate evidence')
    if (-not $Force) {
        throw "The output file already exists: '$OutputPath'. Use -Force to replace it."
    }
}

$docker = Get-Command docker -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
$composeDefinition = Get-BunkFyPreviewComposeDefinition `
    -Root $root `
    -ComposePath $ComposePath `
    -EnvironmentPath $EnvironmentPath `
    -Profiles @('tools')
$projectName = [string]$composeDefinition.name
Assert-BunkFyWorkspaceAccessBoundedString `
    -Value $projectName `
    -Description 'Preview Compose project name' `
    -MaximumLength 128 `
    -DisallowWhitespace
$imageReference = Assert-BunkFyWorkspaceAccessComposeBoundary `
    -ComposeDefinition $composeDefinition

$startedAtUtc = [DateTimeOffset]::UtcNow
$stage = 'release-identity'
$observedReleaseId = $null
$runtimeImage = $null
$initialCatalog = $null
$finalCatalog = $null
$workspaceStates = [Collections.Generic.List[object]]::new()
$script:workspaceAccessCliInvocationCount = 0
$alreadyConvergedCount = 0
$bootstrappedCount = 0
$mutationPerformed = $false
$result = 'failed'
$failureCode = $null

try {
    $client = New-BunkFyPublicEdgeHttpClient `
        -UserAgent 'BunkFy-Workspace-Access-Estate-Probe/1'
    try {
        $rootResponse = Invoke-BunkFyPublicEdgeRequest `
            -Client $client `
            -Uri ([Uri]::new($origin, '/')) `
            -TimeoutSeconds $RequestTimeoutSeconds
        Assert-BunkFyResponseStatus $rootResponse 200 'Web root'
        $webReleaseId = Assert-BunkFyWebReleaseIdentity `
            -Response $rootResponse `
            -ExpectedReleaseId $ExpectedReleaseId
        $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
            -Client $client `
            -Origin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -TimeoutSeconds $RequestTimeoutSeconds
        if ($webReleaseId -cne $observedReleaseId) {
            throw 'The web and API release identities do not match.'
        }
    }
    finally {
        $client.Dispose()
    }

    $stage = 'runtime-image'
    $runtimeImage = Get-BunkFyWorkspaceAccessRuntimeImage `
        -DockerPath $docker.Source `
        -Root $root `
        -EnvironmentFile $EnvironmentPath `
        -ComposeFile $ComposePath `
        -ImageReference $imageReference `
        -ExpectedProjectName $projectName

    $stage = 'initial-catalog'
    $initialCatalog = Get-BunkFyWorkspaceAccessCatalog `
        -DockerPath $docker.Source `
        -Root $root `
        -EnvironmentFile $EnvironmentPath `
        -ComposeFile $ComposePath `
        -AdminActor $Actor `
        -CatalogPageSize $PageSize `
        -CatalogMaxPages $MaxPages `
        -MaximumCatalogWorkspaces $MaxCatalogWorkspaces `
        -MaximumActiveWorkspaces $MaxActiveWorkspaces `
        -TimeoutSeconds $CommandTimeoutSeconds
    if ($initialCatalog.ActiveCount -eq 0) {
        $failureCode = 'active-estate-empty'
        throw 'Preview has no active workspace estate to prove.'
    }

    $stage = 'initial-status'
    foreach ($workspace in @($initialCatalog.ActiveItems | Sort-Object -Property Fingerprint)) {
        $json = Invoke-BunkFyWorkspaceAccessAdminCli `
            -DockerPath $docker.Source `
            -Root $root `
            -EnvironmentFile $EnvironmentPath `
            -ComposeFile $ComposePath `
            -AdminActor $Actor `
            -Command @('-t', $workspace.ScopeId, 'workspaces', 'access', 'status') `
            -TimeoutSeconds $CommandTimeoutSeconds `
            -Description 'Workspace access status query'
        $script:workspaceAccessCliInvocationCount++
        $status = ConvertFrom-BunkFyWorkspaceAccessStatus -Json $json
        $converged = Test-BunkFyWorkspaceAccessStatusConverged -Status $status
        if ($converged) {
            $alreadyConvergedCount++
        }
        $workspaceStates.Add([pscustomobject]@{
                Fingerprint = $workspace.Fingerprint
                ScopeId = $workspace.ScopeId
                Before = $status
                Bootstrap = $null
                After = $null
                Action = if ($converged) { 'none' } else { 'required' }
            })
    }

    $nonConverged = @($workspaceStates | Where-Object {
            -not (Test-BunkFyWorkspaceAccessStatusConverged -Status $_.Before)
        })
    if ($nonConverged.Count -gt 0 -and -not $Apply) {
        $failureCode = 'non-converged-status-only'
        throw "$($nonConverged.Count) active workspace(s) require access bootstrap; rerun with -Apply."
    }
    if ($nonConverged.Count -gt 0) {
        $target = "$($nonConverged.Count) non-converged active Preview workspace(s)"
        if (-not $PSCmdlet.ShouldProcess(
                $target,
                'Bootstrap workspace access seeds and migrate legacy assignments')) {
            Write-Host 'Workspace access estate bootstrap was not applied.'
            return
        }

        $stage = 'bootstrap'
        foreach ($state in $nonConverged) {
            $json = Invoke-BunkFyWorkspaceAccessAdminCli `
                -DockerPath $docker.Source `
                -Root $root `
                -EnvironmentFile $EnvironmentPath `
                -ComposeFile $ComposePath `
                -AdminActor $Actor `
                -Command @(
                    '-t', $state.ScopeId,
                    'workspaces', 'access', 'bootstrap', '--yes') `
                -TimeoutSeconds $CommandTimeoutSeconds `
                -Description 'Workspace access bootstrap'
            $script:workspaceAccessCliInvocationCount++
            $state.Bootstrap = ConvertFrom-BunkFyWorkspaceAccessBootstrapResult -Json $json
            $state.Action = 'bootstrapped'
            $bootstrappedCount++
            $mutationPerformed = $true
        }
    }

    $stage = 'final-status'
    foreach ($state in $workspaceStates) {
        $json = Invoke-BunkFyWorkspaceAccessAdminCli `
            -DockerPath $docker.Source `
            -Root $root `
            -EnvironmentFile $EnvironmentPath `
            -ComposeFile $ComposePath `
            -AdminActor $Actor `
            -Command @('-t', $state.ScopeId, 'workspaces', 'access', 'status') `
            -TimeoutSeconds $CommandTimeoutSeconds `
            -Description 'Workspace access final status query'
        $script:workspaceAccessCliInvocationCount++
        $state.After = ConvertFrom-BunkFyWorkspaceAccessStatus -Json $json
        if ($null -ne $state.Bootstrap) {
            Assert-BunkFyWorkspaceAccessBootstrapTransition `
                -Before $state.Before `
                -Bootstrap $state.Bootstrap `
                -After $state.After
        }
        elseif (-not (Test-BunkFyWorkspaceAccessStatusConverged -Status $state.After)) {
            throw 'A previously converged workspace drifted during the estate proof.'
        }
    }

    $stage = 'final-catalog'
    $finalCatalog = Get-BunkFyWorkspaceAccessCatalog `
        -DockerPath $docker.Source `
        -Root $root `
        -EnvironmentFile $EnvironmentPath `
        -ComposeFile $ComposePath `
        -AdminActor $Actor `
        -CatalogPageSize $PageSize `
        -CatalogMaxPages $MaxPages `
        -MaximumCatalogWorkspaces $MaxCatalogWorkspaces `
        -MaximumActiveWorkspaces $MaxActiveWorkspaces `
        -TimeoutSeconds $CommandTimeoutSeconds
    if ($finalCatalog.FingerprintSha256 -cne $initialCatalog.FingerprintSha256 -or
        $finalCatalog.Items.Count -ne $initialCatalog.Items.Count -or
        $finalCatalog.ActiveCount -ne $initialCatalog.ActiveCount) {
        throw 'Organizations catalog changed during the workspace access estate proof.'
    }

    $result = 'passed'
}
catch {
    if ([string]::IsNullOrWhiteSpace($failureCode)) {
        $failureCode = "$stage-failed"
    }
    $operationError = $_
}

$workspaceEvidence = @($workspaceStates |
    Sort-Object -Property Fingerprint |
    ForEach-Object { ConvertTo-BunkFyWorkspaceAccessWorkspaceEvidence -State $_ })
$evidence = [ordered]@{
    schemaVersion = $script:BunkFyWorkspaceAccessEstateSchemaVersion
    evidenceKind = 'bunkfy-preview-workspace-access-seed-estate'
    startedAtUtc = $startedAtUtc.ToString('O')
    completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    expectedReleaseId = $ExpectedReleaseId
    transport = if ($origin.Scheme -eq 'https') {
        'trusted-https'
    }
    else {
        'loopback-http-fixture'
    }
    result = $result
    failure = if ($result -eq 'passed') {
        $null
    }
    else {
        [ordered]@{
            code = $failureCode
            stage = $stage
        }
    }
    mutation = [ordered]@{
        requested = [bool]$Apply
        performed = $mutationPerformed
    }
    operator = [ordered]@{
        actorFingerprintSha256 = Get-BunkFyWorkspaceAccessSha256 -Value (
            "bunkfy-workspace-access-actor-v1`0$Actor")
        adminCliInvocationCount = $script:workspaceAccessCliInvocationCount
        transientContainers = 'removed-or-auto-removed'
    }
    runtime = if ($null -eq $runtimeImage) {
        $null
    }
    else {
        [ordered]@{
            backendImageReference = $runtimeImage.Reference
            backendImageId = $runtimeImage.ImageId
            adminCliMatchesRunningApi = $true
        }
    }
    bounds = [ordered]@{
        pageSize = $PageSize
        maxPages = $MaxPages
        maxCatalogWorkspaces = $MaxCatalogWorkspaces
        maxActiveWorkspaces = $MaxActiveWorkspaces
        commandTimeoutSeconds = $CommandTimeoutSeconds
    }
    catalog = [ordered]@{
        initial = if ($null -eq $initialCatalog) {
            $null
        }
        else {
            ConvertTo-BunkFyWorkspaceAccessCatalogEvidence -Catalog $initialCatalog
        }
        final = if ($null -eq $finalCatalog) {
            $null
        }
        else {
            ConvertTo-BunkFyWorkspaceAccessCatalogEvidence -Catalog $finalCatalog
        }
        stable = $null -ne $initialCatalog -and
            $null -ne $finalCatalog -and
            $initialCatalog.FingerprintSha256 -ceq $finalCatalog.FingerprintSha256
    }
    summary = [ordered]@{
        inspectedActiveWorkspaces = $workspaceStates.Count
        alreadyConvergedWorkspaces = $alreadyConvergedCount
        bootstrappedWorkspaces = $bootstrappedCount
        finalConvergedWorkspaces = @($workspaceStates | Where-Object {
                $null -ne $_.After -and
                (Test-BunkFyWorkspaceAccessStatusConverged -Status $_.After)
            }).Count
    }
    workspaces = $workspaceEvidence
    limitations = @(
        'preview-deployment-only',
        'workspace-identities-retained-only-as-sha256-fingerprints',
        'hosted-fleet-orchestration-not-exercised')
}

Write-BunkFyPrivateJsonEvidence `
    -Path $OutputPath `
    -Value $evidence `
    -Depth 12 `
    -Overwrite:$Force `
    -Description 'Workspace access estate evidence'

if ($result -ne 'passed') {
    throw $operationError
}

Write-Host (
    "BunkFy Preview workspace access estate passed for $($workspaceStates.Count) active workspace(s); " +
    "$bootstrappedCount bootstrapped.")
Write-Host "Evidence: $OutputPath"
