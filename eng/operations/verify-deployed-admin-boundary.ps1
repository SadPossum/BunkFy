[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][Uri] $AdminOrigin,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Allowed', 'Denied')]
    [string] $ExpectedAdminReachability,
    [Parameter(Mandatory = $true)][Guid] $EvidenceSetId,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [string] $OutputPath,
    [switch] $AllowLoopbackHttp,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'deployed-public-edge.common.ps1')

$public = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackHttp

function Assert-BunkFyAdminBoundaryOrigin {
    param(
        [Parameter(Mandatory = $true)][Uri] $Origin,
        [switch] $AllowLoopback
    )

    if (-not $Origin.IsAbsoluteUri -or
        $Origin.Scheme -notin @('http', 'https') -or
        -not [string]::IsNullOrEmpty($Origin.UserInfo) -or
        -not [string]::IsNullOrEmpty($Origin.Query) -or
        -not [string]::IsNullOrEmpty($Origin.Fragment) -or
        $Origin.AbsolutePath -ne '/') {
        throw 'AdminOrigin must be an absolute HTTP(S) origin without user information, path, query, or fragment.'
    }

    $isHttps = $Origin.Scheme.Equals('https', [StringComparison]::OrdinalIgnoreCase)
    $isAllowedLoopbackHttp =
        $AllowLoopback -and
        $Origin.Scheme.Equals('http', [StringComparison]::OrdinalIgnoreCase) -and
        (Test-BunkFyLoopbackHost -HostName $Origin.Host)
    if (-not $isHttps -and -not $isAllowedLoopbackHttp) {
        throw 'The deployed Admin API must use HTTPS. Plain HTTP is allowed only for the explicit loopback fixture mode.'
    }

    return [Uri]($Origin.GetLeftPart([UriPartial]::Authority).TrimEnd('/') + '/')
}

$admin = Assert-BunkFyAdminBoundaryOrigin `
    -Origin $AdminOrigin `
    -AllowLoopback:$AllowLoopbackHttp
if ($public.GetLeftPart([UriPartial]::Authority).Equals(
        $admin.GetLeftPart([UriPartial]::Authority),
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'PublicOrigin and AdminOrigin must identify distinct authorities.'
}
if ($EvidenceSetId -eq [Guid]::Empty) {
    throw 'EvidenceSetId must not be an empty GUID.'
}
$ExpectedAdminReachability = if ($ExpectedAdminReachability -ieq 'Allowed') {
    'Allowed'
}
else {
    'Denied'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $mode = $ExpectedAdminReachability.ToLowerInvariant()
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/admin-boundary-$mode-$stamp.json"
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

$script:AdminBoundaryMaximumBodyBytes = 64KB
$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$handler.AutomaticDecompression =
    [Net.DecompressionMethods]::GZip -bor
    [Net.DecompressionMethods]::Deflate -bor
    [Net.DecompressionMethods]::Brotli
$client = [Net.Http.HttpClient]::new($handler, $true)
$client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Deployed-Admin-Boundary-Probe/1')
$checks = [Collections.Generic.List[object]]::new()
$adminObservation = $null

function Invoke-BunkFyAdminBoundaryRequest {
    param([Parameter(Mandatory = $true)][Uri] $Uri)

    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
    $cancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($RequestTimeoutSeconds))
    try {
        [void]$request.Headers.Accept.ParseAdd('application/json')
        $response = $client.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token).GetAwaiter().GetResult()
        try {
            $contentLength = $response.Content.Headers.ContentLength
            if ($null -ne $contentLength -and
                $contentLength -gt $script:AdminBoundaryMaximumBodyBytes) {
                throw "Response body exceeds $script:AdminBoundaryMaximumBodyBytes bytes."
            }

            $stream = $response.Content.ReadAsStreamAsync(
                $cancellation.Token).GetAwaiter().GetResult()
            try {
                $body = [IO.MemoryStream]::new()
                try {
                    $buffer = [byte[]]::new(4096)
                    while (($read = $stream.ReadAsync(
                                $buffer,
                                0,
                                $buffer.Length,
                                $cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
                        if ($body.Length + $read -gt $script:AdminBoundaryMaximumBodyBytes) {
                            throw "Response body exceeds $script:AdminBoundaryMaximumBodyBytes bytes."
                        }
                        $body.Write($buffer, 0, $read)
                    }
                    $bodyBytes = $body.ToArray()
                }
                finally {
                    $body.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }

            return [pscustomobject]@{
                Outcome = 'http-response'
                StatusCode = [int]$response.StatusCode
                ContentType = if ($null -eq $response.Content.Headers.ContentType) {
                    $null
                }
                else {
                    [string]$response.Content.Headers.ContentType.MediaType
                }
                Body = $bodyBytes
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch [OperationCanceledException] {
        return [pscustomobject]@{
            Outcome = 'timeout'
            StatusCode = $null
            ContentType = $null
            Body = [byte[]]::new(0)
        }
    }
    catch [Net.Http.HttpRequestException] {
        $errorProperty = $_.Exception.PSObject.Properties['HttpRequestError']
        $errorKind = if ($null -eq $errorProperty) {
            'Unknown'
        }
        else {
            [string]$errorProperty.Value
        }
        $outcome = switch ($errorKind) {
            'NameResolutionError' { 'dns-unreachable' }
            'ConnectionError' { 'connection-unreachable' }
            'SecureConnectionError' { 'tls-failure' }
            default { 'network-error' }
        }
        return [pscustomobject]@{
            Outcome = $outcome
            StatusCode = $null
            ContentType = $null
            Body = [byte[]]::new(0)
        }
    }
    finally {
        $cancellation.Dispose()
        $request.Dispose()
    }
}

function Assert-BunkFyHttpResponse {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ($Response.Outcome -cne 'http-response') {
        throw "$Operation did not return an HTTP response; observed '$($Response.Outcome)'."
    }
}

function Assert-BunkFyPrivateNetworkProblem {
    param([Parameter(Mandatory = $true)][object] $Response)

    Assert-BunkFyHttpResponse -Response $Response -Operation 'Denied Admin API health check'
    if ($Response.StatusCode -ne 403) {
        throw "Denied Admin API health check returned HTTP $($Response.StatusCode); expected HTTP 403 or a network boundary."
    }
    if ([string]::IsNullOrWhiteSpace($Response.ContentType) -or
        -not $Response.ContentType.Equals(
            'application/problem+json',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Denied Admin API health check did not return application/problem+json.'
    }
    if ($Response.Body.Length -eq 0) {
        throw 'Denied Admin API health check returned an empty Problem Details body.'
    }

    try {
        $body = [Text.UTF8Encoding]::new($false, $true).GetString($Response.Body)
        $problem = $body | ConvertFrom-Json -Depth 8
    }
    catch {
        throw 'Denied Admin API health check returned invalid Problem Details JSON.'
    }

    if ([string]$problem.title -cne 'Http.PrivateNetworkRequired' -or
        [int]$problem.status -ne 403 -or
        [string]$problem.detail -cne
            'This endpoint is available only through an approved private network boundary.') {
        throw 'Denied Admin API health check did not return the expected private-network Problem Details response.'
    }
}

try {
    $releaseIdBefore = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $public `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds
    $publicHealth = Invoke-BunkFyAdminBoundaryRequest -Uri ([Uri]::new($public, '/healthz'))
    Assert-BunkFyHttpResponse -Response $publicHealth -Operation 'Public edge health check'
    if ($publicHealth.StatusCode -ne 204 -or $publicHealth.Body.Length -ne 0) {
        throw "Public edge health check returned HTTP $($publicHealth.StatusCode) with an unexpected body; expected an empty HTTP 204 response."
    }
    $checks.Add([ordered]@{
            name = 'public-edge-healthy'
            surface = 'public'
            path = '/healthz'
            observation = 'http-204'
        })

    $publicAdmin = Invoke-BunkFyAdminBoundaryRequest `
        -Uri ([Uri]::new($public, '/api/admin/audit/'))
    Assert-BunkFyHttpResponse -Response $publicAdmin -Operation 'Public Admin API isolation check'
    if ($publicAdmin.StatusCode -ne 404) {
        throw "Public Admin API isolation check returned HTTP $($publicAdmin.StatusCode); expected HTTP 404."
    }
    $checks.Add([ordered]@{
            name = 'admin-api-absent-from-public-edge'
            surface = 'public'
            path = '/api/admin/audit/'
            observation = 'http-404'
        })

    $adminHealth = Invoke-BunkFyAdminBoundaryRequest -Uri ([Uri]::new($admin, '/health'))
    if ($ExpectedAdminReachability -ceq 'Allowed') {
        Assert-BunkFyHttpResponse -Response $adminHealth -Operation 'Allowed Admin API health check'
        if ($adminHealth.StatusCode -ne 200) {
            throw "Allowed Admin API health check returned HTTP $($adminHealth.StatusCode); expected HTTP 200."
        }
        $checks.Add([ordered]@{
                name = 'admin-api-reachable-from-approved-network'
                surface = 'admin'
                path = '/health'
                observation = 'http-200'
            })

        $anonymousAudit = Invoke-BunkFyAdminBoundaryRequest `
            -Uri ([Uri]::new($admin, '/api/admin/audit/'))
        Assert-BunkFyHttpResponse `
            -Response $anonymousAudit `
            -Operation 'Anonymous Admin API authorization check'
        if ($anonymousAudit.StatusCode -notin @(401, 403)) {
            throw "Anonymous Admin API authorization check returned HTTP $($anonymousAudit.StatusCode); expected HTTP 401 or 403."
        }
        if ($anonymousAudit.StatusCode -eq 403 -and $anonymousAudit.Body.Length -gt 0) {
            try {
                $anonymousBody = [Text.UTF8Encoding]::new($false, $true).GetString(
                    $anonymousAudit.Body)
                $anonymousProblem = $anonymousBody | ConvertFrom-Json -Depth 8
                if ([string]$anonymousProblem.title -ceq 'Http.PrivateNetworkRequired') {
                    throw 'The allowed Admin API request was still rejected by the private-network boundary.'
                }
            }
            catch [Management.Automation.RuntimeException] {
                if ($_.Exception.Message.Contains(
                        'still rejected by the private-network boundary',
                        [StringComparison]::Ordinal)) {
                    throw
                }
            }
        }
        $checks.Add([ordered]@{
                name = 'admin-api-anonymous-access-denied'
                surface = 'admin'
                path = '/api/admin/audit/'
                observation = "http-$($anonymousAudit.StatusCode)"
            })
        $adminObservation = [ordered]@{
            classification = 'private-reachable-auth-gated'
            healthStatus = 200
            anonymousAuditStatus = $anonymousAudit.StatusCode
        }
    }
    elseif ($adminHealth.Outcome -ceq 'http-response') {
        Assert-BunkFyPrivateNetworkProblem -Response $adminHealth
        $checks.Add([ordered]@{
                name = 'admin-api-denied-outside-approved-network'
                surface = 'admin'
                path = '/health'
                observation = 'http-403-private-network-required'
            })
        $adminObservation = [ordered]@{
            classification = 'private-network-policy-denial'
            status = 403
        }
    }
    elseif ($adminHealth.Outcome -in @('dns-unreachable', 'connection-unreachable', 'timeout')) {
        $checks.Add([ordered]@{
                name = 'admin-api-denied-outside-approved-network'
                surface = 'admin'
                path = '/health'
                observation = $adminHealth.Outcome
            })
        $adminObservation = [ordered]@{
            classification = 'network-unreachable'
            outcome = $adminHealth.Outcome
        }
    }
    elseif ($adminHealth.Outcome -ceq 'tls-failure') {
        throw 'Denied Admin API verification observed a TLS failure. Broken TLS is not proof of private reachability isolation.'
    }
    else {
        throw "Denied Admin API verification observed unsupported network outcome '$($adminHealth.Outcome)'."
    }
    $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $public `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds
    if ($observedReleaseId -cne $releaseIdBefore) {
        throw 'The public API release identity changed during Admin boundary verification.'
    }
    $checks.Add([ordered]@{
            name = 'release-identity-continuous'
            surface = 'public'
            path = '/api/smoke'
            observation = $observedReleaseId
        })
}
finally {
    $client.Dispose()
}

$evidence = [ordered]@{
    schemaVersion = 1
    evidenceKind = 'bunkfy-deployed-admin-boundary-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    evidenceSetId = $EvidenceSetId.ToString('D')
    releaseId = $observedReleaseId
    expectedAdminReachability = $ExpectedAdminReachability.ToLowerInvariant()
    publicOrigin = $public.GetLeftPart([UriPartial]::Authority)
    adminOrigin = $admin.GetLeftPart([UriPartial]::Authority)
    transport = if ($public.Scheme -eq 'https' -and $admin.Scheme -eq 'https') {
        'trusted-https'
    }
    else {
        'loopback-http-fixture'
    }
    result = 'passed'
    adminObservation = $adminObservation
    checks = @($checks)
    limitations = @(
        'single-vantage-point-observation',
        'deployment-configuration-not-inspected',
        'authenticated-admin-operations-not-executed'
    )
}

$parent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $parent -Force)
}
$temporaryPath = "$OutputPath.$([Guid]::NewGuid().ToString('N')).tmp"
try {
    $json = $evidence | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText(
        $temporaryPath,
        ($json.Replace("`r`n", "`n") + "`n"),
        [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $OutputPath -Force:$Force
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

Write-Host "BunkFy deployed Admin API boundary passed $($checks.Count) checks for the $ExpectedAdminReachability vantage point."
Write-Host "Evidence set: $($EvidenceSetId.ToString('D'))"
Write-Host "Evidence: $OutputPath"
