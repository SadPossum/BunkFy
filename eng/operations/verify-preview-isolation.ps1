[CmdletBinding()]
param(
    [string] $EnvironmentFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'local-sensitive-state.common.ps1')

$composeFile = Join-BunkFyPath 'deploy\preview\compose.yaml'
if ([string]::IsNullOrWhiteSpace($EnvironmentFile)) {
    $EnvironmentFile = Join-BunkFyPath 'deploy\preview\.env'
}
$EnvironmentFile = [IO.Path]::GetFullPath($EnvironmentFile)

if (-not (Test-Path -LiteralPath $EnvironmentFile -PathType Leaf)) {
    throw "Preview environment file is missing: '$EnvironmentFile'."
}
Assert-BunkFyLocalSensitivePath `
    -Path $EnvironmentFile `
    -PathType Leaf `
    -Description 'Preview environment'

$composeArguments = @(
    'compose',
    '--env-file', $EnvironmentFile,
    '-f', $composeFile,
    '--profile', 'operations')

function Get-BunkFyServiceContainer {
    param(
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][string[]] $ComposeArguments
    )

    $containerIds = @(
        & docker @ComposeArguments ps --quiet $ServiceName |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($LASTEXITCODE -ne 0 -or $containerIds.Count -ne 1) {
        throw "Preview service '$ServiceName' must have exactly one running container."
    }

    $inspectJson = & docker inspect $containerIds[0]
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect preview service '$ServiceName'."
    }

    $container = @($inspectJson | ConvertFrom-Json)[0]
    if (-not $container.State.Running -or $container.State.Health.Status -ne 'healthy') {
        throw "Preview service '$ServiceName' is not healthy."
    }

    return $container
}

function Assert-BunkFyContainerNetworks {
    param(
        [Parameter(Mandatory = $true)][object] $Container,
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][string[]] $ExpectedNetworks
    )

    $actualNetworks = @(
        $Container.NetworkSettings.Networks.PSObject.Properties.Name |
            Sort-Object)
    $expected = @($ExpectedNetworks | Sort-Object)
    if (@(Compare-Object -ReferenceObject $expected -DifferenceObject $actualNetworks).Count -gt 0) {
        throw "Preview service '$ServiceName' networks are '$($actualNetworks -join ', ')'; expected '$($expected -join ', ')'."
    }
}

function Assert-BunkFyLoopbackBinding {
    param(
        [Parameter(Mandatory = $true)][object] $Container,
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][int] $ExpectedPort
    )

    $bindingProperty = $Container.HostConfig.PortBindings.PSObject.Properties['8080/tcp']
    $bindings = if ($null -eq $bindingProperty) { @() } else { @($bindingProperty.Value) }
    if ($bindings.Count -ne 1 -or
        $bindings[0].HostIp -ne '127.0.0.1' -or
        [int]$bindings[0].HostPort -ne $ExpectedPort) {
        throw "Preview service '$ServiceName' must publish port 8080 only on 127.0.0.1:$ExpectedPort."
    }
}

function Assert-BunkFyNoPublishedPorts {
    param(
        [Parameter(Mandatory = $true)][object] $Container,
        [Parameter(Mandatory = $true)][string] $ServiceName
    )

    $publishedBindings = @(
        $Container.HostConfig.PortBindings.PSObject.Properties |
            Where-Object { $null -ne $_.Value -and @($_.Value).Count -gt 0 })
    if ($publishedBindings.Count -gt 0) {
        throw "Preview service '$ServiceName' must not publish a host port."
    }
}

function Get-BunkFyHttpStatusCode {
    param([Parameter(Mandatory = $true)][Uri] $Uri)

    try {
        $response = Invoke-WebRequest -Uri $Uri -Method GET -SkipHttpErrorCheck `
            -MaximumRedirection 0 -TimeoutSec 15
        return [int]$response.StatusCode
    }
    catch {
        throw "Preview isolation probe '$Uri' failed: $($_.Exception.Message)"
    }
}

$configurationJson = & docker @composeArguments config --format json
if ($LASTEXITCODE -ne 0) {
    throw 'Preview Compose configuration is invalid.'
}
$configuration = $configurationJson | ConvertFrom-Json

$backendNetwork = [string]$configuration.networks.backend.name
$edgeNetwork = [string]$configuration.networks.edge.name
$managementNetwork = [string]$configuration.networks.management.name
$webPort = [int]@($configuration.services.web.ports)[0].published
$adminPort = [int]@($configuration.services.'admin-api'.ports)[0].published

$web = Get-BunkFyServiceContainer -ServiceName 'web' -ComposeArguments $composeArguments
$api = Get-BunkFyServiceContainer -ServiceName 'api' -ComposeArguments $composeArguments
$adminApi = Get-BunkFyServiceContainer -ServiceName 'admin-api' -ComposeArguments $composeArguments

Assert-BunkFyContainerNetworks -Container $web -ServiceName 'web' `
    -ExpectedNetworks @($edgeNetwork)
Assert-BunkFyContainerNetworks -Container $api -ServiceName 'api' `
    -ExpectedNetworks @($backendNetwork, $edgeNetwork)
Assert-BunkFyContainerNetworks -Container $adminApi -ServiceName 'admin-api' `
    -ExpectedNetworks @($backendNetwork, $managementNetwork)

Assert-BunkFyLoopbackBinding -Container $web -ServiceName 'web' -ExpectedPort $webPort
Assert-BunkFyLoopbackBinding -Container $adminApi -ServiceName 'admin-api' -ExpectedPort $adminPort
Assert-BunkFyNoPublishedPorts -Container $api -ServiceName 'api'
if ([string]$adminApi.HostConfig.RestartPolicy.Name -notin @('', 'no')) {
    throw 'The preview Admin API has an automatic container restart policy.'
}

$webContainerId = [string]$web.Id
& docker exec $webContainerId sh -c `
    "wget -qO- -T 3 --header 'Host: 127.0.0.1' http://api:8080/health >/dev/null 2>&1"
if ($LASTEXITCODE -ne 0) {
    throw 'The public edge cannot reach the public API on its shared edge network.'
}

& docker exec $webContainerId sh -c `
    'wget -qO- -T 3 http://admin-api:8080/health >/dev/null 2>&1'
if ($LASTEXITCODE -eq 0) {
    throw 'The public edge can reach the Admin API container.'
}

$publicOrigin = [Uri]"http://127.0.0.1:$webPort/"
$adminOrigin = [Uri]"http://127.0.0.1:$adminPort/"
if ((Get-BunkFyHttpStatusCode -Uri ([Uri]::new($publicOrigin, 'healthz'))) -ne 204) {
    throw 'The loopback public edge health probe failed.'
}
if ((Get-BunkFyHttpStatusCode -Uri ([Uri]::new($publicOrigin, 'api/smoke'))) -ne 200) {
    throw 'The public edge could not proxy a request to the public API.'
}
if ((Get-BunkFyHttpStatusCode -Uri ([Uri]::new($publicOrigin, 'api/admin/audit/'))) -ne 404) {
    throw 'An Admin API route is reachable through the public edge.'
}

$adminStatus = Get-BunkFyHttpStatusCode -Uri ([Uri]::new($adminOrigin, 'api/admin/audit/'))
if ($adminStatus -notin @(401, 403)) {
    throw "The loopback Admin API probe returned HTTP $adminStatus instead of an authorization denial."
}

Write-Host 'Preview management-plane isolation is valid.'
