Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'local-sensitive-state.common.ps1')

$script:BunkFyPublicEdgeMaximumBodyBytes = 64KB

function Write-BunkFyPrivateJsonEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][object] $Value,
        [ValidateRange(2, 32)][int] $Depth = 8,
        [switch] $Overwrite,
        [string] $Description = 'Deployed verification evidence'
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    Write-BunkFyLocalSensitiveTextFile `
        -Path $Path `
        -Content ($json.Replace("`r`n", "`n") + "`n") `
        -Overwrite:$Overwrite `
        -Description $Description
}

function Test-BunkFyLoopbackHost {
    param([Parameter(Mandatory = $true)][string] $HostName)

    if ($HostName.Equals('localhost', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $candidate = $HostName.Trim('[', ']')
    $address = $null
    if ([Net.IPAddress]::TryParse($candidate, [ref]$address)) {
        return [Net.IPAddress]::IsLoopback($address)
    }

    return $false
}

function Assert-BunkFyPublicEdgeOrigin {
    param(
        [Parameter(Mandatory = $true)][Uri] $Origin,
        [switch] $AllowLoopbackHttp
    )

    if (-not $Origin.IsAbsoluteUri) {
        throw 'The public edge origin must be an absolute URI.'
    }
    if (-not [string]::IsNullOrEmpty($Origin.UserInfo) -or
        -not [string]::IsNullOrEmpty($Origin.Query) -or
        -not [string]::IsNullOrEmpty($Origin.Fragment) -or
        $Origin.AbsolutePath -ne '/') {
        throw 'The public edge origin must contain only a scheme, host, optional port, and trailing slash.'
    }

    $isHttps = $Origin.Scheme.Equals('https', [StringComparison]::OrdinalIgnoreCase)
    $isAllowedLoopbackHttp =
        $AllowLoopbackHttp -and
        $Origin.Scheme.Equals('http', [StringComparison]::OrdinalIgnoreCase) -and
        (Test-BunkFyLoopbackHost -HostName $Origin.Host)
    if (-not $isHttps -and -not $isAllowedLoopbackHttp) {
        throw 'The deployed public edge must use HTTPS. Plain HTTP is allowed only for the explicit loopback fixture mode.'
    }

    return [Uri]($Origin.GetLeftPart([UriPartial]::Authority).TrimEnd('/') + '/')
}

function Get-BunkFyUnambiguousHeaderValue {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $values = $null
    if (-not $Response.Headers.TryGetValue($Name, [ref]$values) -or
        $null -eq $values -or
        @($values).Count -eq 0) {
        throw "The response is missing required header '$Name'."
    }

    $distinct = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @($values)) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            throw "The response contains an empty '$Name' header."
        }
        [void]$distinct.Add(([string]$value).Trim())
    }
    if ($distinct.Count -ne 1) {
        throw "The response contains ambiguous values for header '$Name'."
    }

    return @($distinct)[0]
}

function Assert-BunkFyExactHeaderValue {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Expected
    )

    $actual = Get-BunkFyUnambiguousHeaderValue -Response $Response -Name $Name
    if (-not $actual.Equals($Expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Header '$Name' is '$actual'; expected '$Expected'."
    }
}

function ConvertTo-BunkFyContentSecurityPolicyMap {
    param([Parameter(Mandatory = $true)][string] $Value)

    $directives = [Collections.Generic.Dictionary[string, string[]]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($segment in $Value.Split(';')) {
        $trimmed = $segment.Trim()
        if ($trimmed.Length -eq 0) {
            continue
        }

        $parts = @([Text.RegularExpressions.Regex]::Split($trimmed, '\s+') |
            Where-Object { $_.Length -gt 0 })
        $name = $parts[0]
        if ($directives.ContainsKey($name)) {
            throw "Content-Security-Policy repeats directive '$name'."
        }

        $tokens = if ($parts.Count -gt 1) { @($parts[1..($parts.Count - 1)]) } else { @() }
        $directives.Add($name, $tokens)
    }

    return $directives
}

function Assert-BunkFyExactDirectiveTokens {
    param(
        [Parameter(Mandatory = $true)]
        [Collections.Generic.Dictionary[string, string[]]] $Directives,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Expected
    )

    $actual = $null
    if (-not $Directives.TryGetValue($Name, [ref]$actual)) {
        throw "Content-Security-Policy is missing directive '$Name'."
    }

    $actualSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($token in @($actual)) {
        if (-not $actualSet.Add($token)) {
            throw "Content-Security-Policy directive '$Name' repeats token '$token'."
        }
    }
    $expectedSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($token in $Expected) {
        [void]$expectedSet.Add($token)
    }
    if (-not $actualSet.SetEquals($expectedSet)) {
        throw "Content-Security-Policy directive '$Name' has unexpected sources."
    }
}

function Assert-BunkFyContentSecurityPolicy {
    param([Parameter(Mandatory = $true)][object] $Response)

    $value = Get-BunkFyUnambiguousHeaderValue `
        -Response $Response `
        -Name 'Content-Security-Policy'
    $directives = ConvertTo-BunkFyContentSecurityPolicyMap -Value $value
    $required = [ordered]@{
        'default-src' = @("'self'")
        'base-uri' = @("'self'")
        'object-src' = @("'none'")
        'frame-ancestors' = @("'none'")
        'form-action' = @("'self'")
        'script-src' = @("'self'")
        'style-src' = @("'self'", "'unsafe-inline'")
        'img-src' = @("'self'", 'data:')
        'font-src' = @("'self'")
        'connect-src' = @("'self'")
    }
    foreach ($entry in $required.GetEnumerator()) {
        Assert-BunkFyExactDirectiveTokens `
            -Directives $directives `
            -Name $entry.Key `
            -Expected $entry.Value
    }
    if ($directives.Count -ne $required.Count) {
        throw 'Content-Security-Policy contains directives outside the checked-in BunkFy policy.'
    }
}

function Assert-BunkFyPermissionsPolicy {
    param([Parameter(Mandatory = $true)][object] $Response)

    $value = Get-BunkFyUnambiguousHeaderValue `
        -Response $Response `
        -Name 'Permissions-Policy'
    $features = [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($segment in $value.Split(',')) {
        $trimmed = $segment.Trim()
        if ($trimmed -notmatch '^([a-z0-9-]+)\s*=\s*(\([^)]*\))$') {
            throw "Permissions-Policy contains unsupported entry '$trimmed'."
        }
        if (-not $features.TryAdd($Matches[1], $Matches[2].Replace(' ', ''))) {
            throw "Permissions-Policy repeats feature '$($Matches[1])'."
        }
    }

    foreach ($feature in @('camera', 'microphone', 'geolocation', 'payment', 'usb')) {
        $allowlist = $null
        if (-not $features.TryGetValue($feature, [ref]$allowlist) -or $allowlist -ne '()') {
            throw "Permissions-Policy must disable '$feature'."
        }
    }
    if ($features.Count -ne 5) {
        throw 'Permissions-Policy contains features outside the checked-in BunkFy policy.'
    }
}

function Assert-BunkFyStrictTransportSecurity {
    param([Parameter(Mandatory = $true)][object] $Response)

    $value = Get-BunkFyUnambiguousHeaderValue `
        -Response $Response `
        -Name 'Strict-Transport-Security'
    $maxAge = $null
    foreach ($segment in $value.Split(';')) {
        $trimmed = $segment.Trim()
        if ($trimmed -match '^max-age\s*=\s*([0-9]+)$') {
            if ($null -ne $maxAge) {
                throw 'Strict-Transport-Security repeats max-age.'
            }
            $parsed = [long]0
            if (-not [long]::TryParse(
                    $Matches[1],
                    [Globalization.NumberStyles]::None,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$parsed)) {
                throw 'Strict-Transport-Security max-age is invalid.'
            }
            $maxAge = $parsed
        }
    }
    if ($null -eq $maxAge -or $maxAge -lt 31536000) {
        throw 'Strict-Transport-Security max-age must be at least 31536000 seconds.'
    }
}

function Assert-BunkFyPublicEdgeSecurityHeaders {
    param([Parameter(Mandatory = $true)][object] $Response)

    Assert-BunkFyExactHeaderValue $Response 'X-Content-Type-Options' 'nosniff'
    Assert-BunkFyExactHeaderValue $Response 'X-Frame-Options' 'DENY'
    Assert-BunkFyExactHeaderValue $Response 'Referrer-Policy' 'strict-origin-when-cross-origin'
    Assert-BunkFyExactHeaderValue $Response 'Cross-Origin-Opener-Policy' 'same-origin'
    Assert-BunkFyExactHeaderValue $Response 'X-Permitted-Cross-Domain-Policies' 'none'
    Assert-BunkFyContentSecurityPolicy -Response $Response
    Assert-BunkFyPermissionsPolicy -Response $Response
    Assert-BunkFyStrictTransportSecurity -Response $Response
}

function Get-BunkFyWebReleaseIdentity {
    param([Parameter(Mandatory = $true)][object] $Response)

    $actual = Get-BunkFyUnambiguousHeaderValue `
        -Response $Response `
        -Name 'X-BunkFy-Release-Id'
    if ($actual -cnotmatch '^[a-z0-9][a-z0-9._-]{2,127}$') {
        throw "The web release id '$actual' is invalid."
    }

    return $actual
}

function Assert-BunkFyWebReleaseIdentity {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
        [string] $ExpectedReleaseId
    )

    $actual = Get-BunkFyWebReleaseIdentity -Response $Response
    if ($actual -cne $ExpectedReleaseId) {
        throw "The web release id '$actual' does not match '$ExpectedReleaseId'."
    }

    return $actual
}

function Assert-BunkFyResponseStatus {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $Expected,
        [Parameter(Mandatory = $true)][string] $CheckName
    )

    if ($Response.StatusCode -ne $Expected) {
        throw "$CheckName returned HTTP $($Response.StatusCode); expected HTTP $Expected."
    }
}

function Assert-BunkFyResponseContentType {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][string] $ExpectedPrefix,
        [Parameter(Mandatory = $true)][string] $CheckName
    )

    $actual = Get-BunkFyUnambiguousHeaderValue -Response $Response -Name 'Content-Type'
    if (-not $actual.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$CheckName returned Content-Type '$actual'; expected '$ExpectedPrefix'."
    }
}

function Get-BunkFyBoundedUtf8Body {
    param([Parameter(Mandatory = $true)][object] $Response)

    try {
        return [Text.UTF8Encoding]::new($false, $true).GetString($Response.Body)
    }
    catch {
        throw "The response body is not valid UTF-8: $($_.Exception.Message)"
    }
}

function Get-BunkFySmokeDeploymentIdentity {
    param([Parameter(Mandatory = $true)][object] $Response)

    Assert-BunkFyResponseStatus $Response 200 '/api/smoke'
    Assert-BunkFyResponseContentType $Response 'application/json' '/api/smoke'
    $body = Get-BunkFyBoundedUtf8Body -Response $Response
    try {
        $payload = $body | ConvertFrom-Json -Depth 8
    }
    catch {
        throw "The /api/smoke response is not valid JSON: $($_.Exception.Message)"
    }

    $expectedNames = @(
        'admissionEvidenceReference',
        'application',
        'releaseId',
        'service',
        'status',
        'timestampUtc')
    $actualNames = @($payload.PSObject.Properties.Name | Sort-Object)
    if (@(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames).Count -gt 0) {
        throw 'The /api/smoke response does not have the expected closed shape.'
    }
    if ($payload.application -cne 'BunkFy' -or
        $payload.service -cne 'BunkFy.Host.Api' -or
        $payload.status -cne 'ok') {
        throw 'The /api/smoke response does not identify the BunkFy public API.'
    }
    if ($payload.releaseId -isnot [string] -or
        $payload.releaseId -cnotmatch '^[a-z0-9][a-z0-9._-]{2,127}$') {
        throw 'The /api/smoke response contains an invalid release id.'
    }
    $admissionReference = $payload.admissionEvidenceReference
    if ($null -ne $admissionReference -and
        ($admissionReference -isnot [string] -or
         $admissionReference -cnotmatch '^admission:[0-9a-f]{32}$' -or
         $admissionReference -ceq 'admission:00000000000000000000000000000000')) {
        throw 'The /api/smoke response contains an invalid admission evidence reference.'
    }

    $timestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
            [string]$payload.timestampUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$timestamp)) {
        throw 'The /api/smoke timestamp is invalid.'
    }
    $now = [DateTimeOffset]::UtcNow
    if ($timestamp -lt $now.AddMinutes(-10) -or $timestamp -gt $now.AddMinutes(1)) {
        throw 'The /api/smoke timestamp is outside the allowed clock-skew window.'
    }

    return [pscustomobject]@{
        ReleaseId = [string]$payload.releaseId
        AdmissionEvidenceReference = if ($null -eq $admissionReference) {
            $null
        }
        else {
            [string]$admissionReference
        }
    }
}

function Get-BunkFySmokeReleaseIdentity {
    param([Parameter(Mandatory = $true)][object] $Response)

    return [string](
        Get-BunkFySmokeDeploymentIdentity -Response $Response).ReleaseId
}

function Assert-BunkFySmokeDeploymentIdentity {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
        [string] $ExpectedReleaseId
    )

    $actual = Get-BunkFySmokeDeploymentIdentity -Response $Response
    if ($actual.ReleaseId -cne $ExpectedReleaseId) {
        throw "The /api/smoke release id '$($actual.ReleaseId)' does not match '$ExpectedReleaseId'."
    }
    if ([string]::IsNullOrWhiteSpace($actual.AdmissionEvidenceReference)) {
        throw 'The /api/smoke response is not bound to an admission evidence reference.'
    }

    return $actual
}

function Assert-BunkFySmokeResponse {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
        [string] $ExpectedReleaseId
    )

    return [string](
        Assert-BunkFySmokeDeploymentIdentity `
            -Response $Response `
            -ExpectedReleaseId $ExpectedReleaseId).ReleaseId
}

function New-BunkFyPublicEdgeHttpClient {
    param(
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9./_-]{2,127}$')]
        [string] $UserAgent = 'BunkFy-Deployed-Public-Edge-Probe/1'
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.AutomaticDecompression =
        [Net.DecompressionMethods]::GZip -bor
        [Net.DecompressionMethods]::Deflate -bor
        [Net.DecompressionMethods]::Brotli
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $client.DefaultRequestHeaders.UserAgent.ParseAdd($UserAgent)
    return $client
}

function Invoke-BunkFyUntrustedHttpsHostRequest {
    param(
        [Parameter(Mandatory = $true)][Uri] $Uri,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $HostHeader
    )

    if (-not $Uri.Scheme.Equals('https', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The external untrusted-Host transport supports HTTPS only.'
    }

    $curl = Get-Command curl -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $bodyPath = Join-Path ([IO.Path]::GetTempPath()) (
        'bunkfy-public-edge-' + [Guid]::NewGuid().ToString('N') + '.body')
    try {
        $arguments = @(
            '--disable',
            '--silent',
            '--show-error',
            '--output', $bodyPath,
            '--write-out', '%{http_code}',
            '--max-time', $TimeoutSeconds.ToString(
                [Globalization.CultureInfo]::InvariantCulture),
            '--max-filesize', $script:BunkFyPublicEdgeMaximumBodyBytes.ToString(
                [Globalization.CultureInfo]::InvariantCulture),
            '--proto', '=https',
            '--proxy', '',
            '--header', "Host: $HostHeader",
            $Uri.AbsoluteUri)
        $statusOutput = @(& $curl.Source @arguments)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "The untrusted-Host request to '$Uri' failed with curl exit code $exitCode."
        }

        $statusText = ($statusOutput -join '').Trim()
        if ($statusText -cnotmatch '^[0-9]{3}$') {
            throw "The untrusted-Host request returned invalid HTTP status '$statusText'."
        }

        $body = Get-Item -LiteralPath $bodyPath -Force
        if ($body.PSIsContainer -or
            ($body.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $body.Length -gt $script:BunkFyPublicEdgeMaximumBodyBytes) {
            throw 'The untrusted-Host response body is not a bounded regular file.'
        }

        return [int]::Parse(
            $statusText,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture)
    }
    finally {
        Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-BunkFyPublicEdgeRequest {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory = $true)][Uri] $Uri,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [string] $HostHeader
    )

    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
    $cancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        if (-not [string]::IsNullOrWhiteSpace($HostHeader)) {
            $request.Headers.Host = $HostHeader
        }

        $response = $Client.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token).GetAwaiter().GetResult()
        try {
            $contentLength = $response.Content.Headers.ContentLength
            if ($null -ne $contentLength -and
                $contentLength -gt $script:BunkFyPublicEdgeMaximumBodyBytes) {
                throw "Response body exceeds $script:BunkFyPublicEdgeMaximumBodyBytes bytes."
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
                        if ($body.Length + $read -gt $script:BunkFyPublicEdgeMaximumBodyBytes) {
                            throw "Response body exceeds $script:BunkFyPublicEdgeMaximumBodyBytes bytes."
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

            $values = [Collections.Generic.Dictionary[string, Collections.Generic.List[string]]]::new(
                [StringComparer]::OrdinalIgnoreCase)
            foreach ($header in @($response.Headers, $response.Content.Headers)) {
                foreach ($entry in $header) {
                    if (-not $values.ContainsKey($entry.Key)) {
                        $values.Add($entry.Key, [Collections.Generic.List[string]]::new())
                    }
                    foreach ($value in $entry.Value) {
                        $values[$entry.Key].Add([string]$value)
                    }
                }
            }
            $headers = [Collections.Generic.Dictionary[string, string[]]]::new(
                [StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $values.GetEnumerator()) {
                $headers.Add($entry.Key, $entry.Value.ToArray())
            }

            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Headers = $headers
                Body = $bodyBytes
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch [OperationCanceledException] {
        throw "Request to '$Uri' exceeded the $TimeoutSeconds-second timeout."
    }
    finally {
        $cancellation.Dispose()
        $request.Dispose()
    }
}

function Assert-BunkFyPublicApiReleaseIdentity {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory = $true)][Uri] $Origin,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
        [string] $ExpectedReleaseId,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [ref] $ObservedAdmissionEvidenceReference
    )

    $identity = Assert-BunkFyPublicApiDeploymentIdentity `
        -Client $Client `
        -Origin $Origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $TimeoutSeconds
    if ($PSBoundParameters.ContainsKey('ObservedAdmissionEvidenceReference')) {
        if ([string]::IsNullOrWhiteSpace(
                [string]$ObservedAdmissionEvidenceReference.Value)) {
            $ObservedAdmissionEvidenceReference.Value =
                $identity.AdmissionEvidenceReference
        }
        elseif ([string]$ObservedAdmissionEvidenceReference.Value -cne
            $identity.AdmissionEvidenceReference) {
            throw 'The public API admission evidence reference changed during verification.'
        }
    }

    return [string]$identity.ReleaseId
}

function Assert-BunkFyPublicApiDeploymentIdentity {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory = $true)][Uri] $Origin,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
        [string] $ExpectedReleaseId,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds
    )

    $response = Invoke-BunkFyPublicEdgeRequest `
        -Client $Client `
        -Uri ([Uri]::new($Origin, '/api/smoke')) `
        -TimeoutSeconds $TimeoutSeconds
    return Assert-BunkFySmokeDeploymentIdentity `
        -Response $response `
        -ExpectedReleaseId $ExpectedReleaseId
}

function Get-BunkFyObservedComposedReleaseId {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory = $true)][Uri] $Origin,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [ref] $ObservedAdmissionEvidenceReference
    )

    $webReleaseId = $null
    $apiIdentity = $null
    try {
        $rootResponse = Invoke-BunkFyPublicEdgeRequest `
            -Client $Client `
            -Uri ([Uri]::new($Origin, '/')) `
            -TimeoutSeconds $TimeoutSeconds
        if ($rootResponse.StatusCode -ne 200) {
            return $null
        }
        $webReleaseId = Get-BunkFyWebReleaseIdentity -Response $rootResponse

        $smokeResponse = Invoke-BunkFyPublicEdgeRequest `
            -Client $Client `
            -Uri ([Uri]::new($Origin, '/api/smoke')) `
            -TimeoutSeconds $TimeoutSeconds
        $apiIdentity = Get-BunkFySmokeDeploymentIdentity -Response $smokeResponse
    }
    catch {
        return $null
    }

    if ($PSBoundParameters.ContainsKey('ObservedAdmissionEvidenceReference')) {
        if ([string]::IsNullOrWhiteSpace(
                [string]$ObservedAdmissionEvidenceReference.Value)) {
            $ObservedAdmissionEvidenceReference.Value =
                $apiIdentity.AdmissionEvidenceReference
        }
        elseif ([string]$ObservedAdmissionEvidenceReference.Value -cne
            $apiIdentity.AdmissionEvidenceReference) {
            throw 'The public API admission evidence reference changed during release convergence.'
        }
    }
    if ($webReleaseId -cne $apiIdentity.ReleaseId) {
        return $null
    }
    return $webReleaseId
}
