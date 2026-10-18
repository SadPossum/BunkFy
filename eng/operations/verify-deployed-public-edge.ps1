[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [string] $OutputPath,
    [ValidateRange(1, 60)][int] $TimeoutSeconds = 15,
    [ValidateLength(1, 253)][string] $UntrustedHost = 'untrusted.invalid',
    [switch] $AllowLoopbackHttp,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'deployed-public-edge.common.ps1')

$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackHttp
$untrustedLabels = @($UntrustedHost.Split('.'))
$invalidUntrustedLabel = @($untrustedLabels | Where-Object {
        $_.Length -lt 1 -or
        $_.Length -gt 63 -or
        $_ -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$'
    }).Count -gt 0
if ($untrustedLabels.Count -lt 2 -or
    $invalidUntrustedLabel -or
    $UntrustedHost.Equals($origin.Host, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'UntrustedHost must be a distinct, syntactically valid DNS host name.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/public-edge-$stamp.json"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) {
    $item = Get-Item -LiteralPath $OutputPath -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The output path is not a regular file: '$OutputPath'."
    }
    if (-not $Force) {
        throw "The output file already exists: '$OutputPath'. Use -Force to replace it."
    }
}

$client = New-BunkFyPublicEdgeHttpClient

$checks = [Collections.Generic.List[object]]::new()
try {
    $rootResponse = Invoke-BunkFyPublicEdgeRequest `
        -Client $client `
        -Uri ([Uri]::new($origin, '/')) `
        -TimeoutSeconds $TimeoutSeconds
    Assert-BunkFyResponseStatus $rootResponse 200 'Web root'
    Assert-BunkFyResponseContentType $rootResponse 'text/html' 'Web root'
    if ($rootResponse.Body.Length -eq 0) {
        throw 'The web root returned an empty body.'
    }
    Assert-BunkFyPublicEdgeSecurityHeaders -Response $rootResponse
    $webReleaseId = Assert-BunkFyWebReleaseIdentity `
        -Response $rootResponse `
        -ExpectedReleaseId $ExpectedReleaseId
    $checks.Add([ordered]@{
        name = 'web-root-and-browser-policy'
        path = '/'
        status = 200
    })
    $checks.Add([ordered]@{
        name = 'web-release-identity'
        path = '/'
        status = 200
    })

    $healthResponse = Invoke-BunkFyPublicEdgeRequest `
        -Client $client `
        -Uri ([Uri]::new($origin, '/healthz')) `
        -TimeoutSeconds $TimeoutSeconds
    Assert-BunkFyResponseStatus $healthResponse 204 'Edge health'
    if ($healthResponse.Body.Length -ne 0) {
        throw 'The edge health response must not contain a body.'
    }
    $checks.Add([ordered]@{
        name = 'edge-health'
        path = '/healthz'
        status = 204
    })

    $smokeResponse = Invoke-BunkFyPublicEdgeRequest `
        -Client $client `
        -Uri ([Uri]::new($origin, '/api/smoke')) `
        -TimeoutSeconds $TimeoutSeconds
    $observedReleaseId = Assert-BunkFySmokeResponse `
        -Response $smokeResponse `
        -ExpectedReleaseId $ExpectedReleaseId
    if ($webReleaseId -cne $observedReleaseId) {
        throw 'The web and API release identities do not match.'
    }
    $checks.Add([ordered]@{
        name = 'public-api-smoke'
        path = '/api/smoke'
        status = 200
    })

    $adminResponse = Invoke-BunkFyPublicEdgeRequest `
        -Client $client `
        -Uri ([Uri]::new($origin, '/api/admin/audit/')) `
        -TimeoutSeconds $TimeoutSeconds
    Assert-BunkFyResponseStatus $adminResponse 404 'Public Admin API isolation'
    $checks.Add([ordered]@{
        name = 'admin-api-absent'
        path = '/api/admin/audit/'
        status = 404
    })

    $hostStatus = if ($origin.Scheme.Equals(
            'https',
            [StringComparison]::OrdinalIgnoreCase)) {
        Invoke-BunkFyUntrustedHttpsHostRequest `
            -Uri ([Uri]::new($origin, '/api/smoke')) `
            -TimeoutSeconds $TimeoutSeconds `
            -HostHeader $UntrustedHost
    }
    else {
        $hostResponse = Invoke-BunkFyPublicEdgeRequest `
            -Client $client `
            -Uri ([Uri]::new($origin, '/api/smoke')) `
            -TimeoutSeconds $TimeoutSeconds `
            -HostHeader $UntrustedHost
        $hostResponse.StatusCode
    }
    if ($hostStatus -lt 400 -or $hostStatus -gt 499) {
        throw "The public edge accepted an untrusted Host value with HTTP $hostStatus."
    }
    $checks.Add([ordered]@{
        name = 'untrusted-host-rejected'
        path = '/api/smoke'
        status = $hostStatus
    })
}
finally {
    $client.Dispose()
}

$evidence = [ordered]@{
    schemaVersion = 3
    evidenceKind = 'bunkfy-deployed-public-edge-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-fixture' }
    result = 'passed'
    checks = @($checks)
    limitations = @(
        'registry-and-image-provenance-require-promotion-record',
        'private-infrastructure-not-observed',
        'authenticated-workflows-not-executed'
    )
}

$parent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $parent -Force)
}
Write-BunkFyPrivateJsonEvidence `
    -Path $OutputPath `
    -Value $evidence `
    -Overwrite:$Force

Write-Host "BunkFy deployed public edge passed $($checks.Count) checks."
Write-Host "Evidence: $OutputPath"
