Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BunkFyPublicEdgeMaximumBodyBytes = 64KB

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

function Assert-BunkFySmokeResponse {
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

    $expectedNames = @('application', 'service', 'status', 'timestampUtc')
    $actualNames = @($payload.PSObject.Properties.Name | Sort-Object)
    if (@(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames).Count -gt 0) {
        throw 'The /api/smoke response does not have the expected closed shape.'
    }
    if ($payload.application -cne 'BunkFy' -or
        $payload.service -cne 'BunkFy.Host.Api' -or
        $payload.status -cne 'ok') {
        throw 'The /api/smoke response does not identify the BunkFy public API.'
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
