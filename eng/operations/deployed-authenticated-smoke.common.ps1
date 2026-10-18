Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BunkFyAuthenticatedSmokeMaximumBodyBytes = 256KB

function ConvertFrom-BunkFySmokeSecureString {
    param([Parameter(Mandatory = $true)][Security.SecureString] $Value)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Resolve-BunkFySmokeAccessToken {
    param(
        [Security.SecureString] $AccessToken,
        [Parameter(Mandatory = $true)][string] $EnvironmentVariable,
        [Parameter(Mandatory = $true)][string] $Prompt
    )

    if ($null -ne $AccessToken) {
        return ConvertFrom-BunkFySmokeSecureString -Value $AccessToken
    }

    $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
    if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
        return $environmentValue.Trim()
    }

    $prompted = Read-Host $Prompt -AsSecureString
    return ConvertFrom-BunkFySmokeSecureString -Value $prompted
}

function Invoke-BunkFyAuthenticatedJsonRequest {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory = $true)][Uri] $Origin,
        [Parameter(Mandatory = $true)][ValidatePattern('^/api/')][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PUT')][string] $Method,
        [Parameter(Mandatory = $true)][string] $TenantId,
        [Parameter(Mandatory = $true)][string] $AccessToken,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [AllowNull()][object] $Body
    )

    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::new($Method),
        [Uri]::new($Origin, $Path))
    $cancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new(
            'Bearer',
            $AccessToken)
        [void]$request.Headers.TryAddWithoutValidation('X-Tenant-Id', $TenantId)
        [void]$request.Headers.Accept.ParseAdd('application/json')
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 12 -Compress
            $request.Content = [Net.Http.StringContent]::new(
                $json,
                [Text.UTF8Encoding]::new($false),
                'application/json')
        }

        $response = $Client.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token).GetAwaiter().GetResult()
        try {
            $contentLength = $response.Content.Headers.ContentLength
            if ($null -ne $contentLength -and
                $contentLength -gt $script:BunkFyAuthenticatedSmokeMaximumBodyBytes) {
                throw "Response body exceeds $script:BunkFyAuthenticatedSmokeMaximumBodyBytes bytes."
            }

            $stream = $response.Content.ReadAsStreamAsync(
                $cancellation.Token).GetAwaiter().GetResult()
            try {
                $buffer = [byte[]]::new(4096)
                $body = [IO.MemoryStream]::new()
                try {
                    while (($read = $stream.ReadAsync(
                                $buffer,
                                0,
                                $buffer.Length,
                                $cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
                        if ($body.Length + $read -gt $script:BunkFyAuthenticatedSmokeMaximumBodyBytes) {
                            throw "Response body exceeds $script:BunkFyAuthenticatedSmokeMaximumBodyBytes bytes."
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
                StatusCode = [int]$response.StatusCode
                Body = $bodyBytes
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch [OperationCanceledException] {
        throw "Authenticated request to '$Path' exceeded the $TimeoutSeconds-second timeout."
    }
    finally {
        $cancellation.Dispose()
        $request.Dispose()
    }
}

function Get-BunkFyAuthenticatedProblemCode {
    param([Parameter(Mandatory = $true)][object] $Response)

    if ($Response.Body.Length -eq 0) {
        return $null
    }

    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($Response.Body)
        $problem = $json | ConvertFrom-Json -Depth 8
        $title = [string]$problem.title
        if ($title -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
            return $title
        }
        return $null
    }
    catch {
        return $null
    }
}

function ConvertFrom-BunkFyAuthenticatedJsonResponse {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ($Response.StatusCode -ne $ExpectedStatus) {
        $problemCode = Get-BunkFyAuthenticatedProblemCode -Response $Response
        $problemSuffix = if ([string]::IsNullOrWhiteSpace($problemCode)) {
            ''
        }
        else {
            " with problem '$problemCode'"
        }
        throw "$Operation returned HTTP $($Response.StatusCode)$problemSuffix; expected HTTP $ExpectedStatus."
    }
    if ($Response.Body.Length -eq 0) {
        return $null
    }

    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($Response.Body)
        return $json | ConvertFrom-Json -Depth 16
    }
    catch {
        throw "$Operation returned an invalid JSON response."
    }
}

function Invoke-BunkFyAuthenticatedJsonRequestWithConvergence {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory = $true)][Uri] $Origin,
        [Parameter(Mandatory = $true)][ValidatePattern('^/api/')][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('POST', 'PUT')][string] $Method,
        [Parameter(Mandatory = $true)][string] $TenantId,
        [Parameter(Mandatory = $true)][string] $AccessToken,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][object] $Body,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $Operation,
        [Parameter(Mandatory = $true)][ValidateRange(1, 600)][int] $ConvergenceTimeoutSeconds,
        [Parameter(Mandatory = $true)][ValidateRange(100, 5000)][int] $PollIntervalMilliseconds,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]] $RetryableProblemCodes
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    $lastProblemCode = $null
    do {
        $response = Invoke-BunkFyAuthenticatedJsonRequest `
            -Client $Client `
            -Origin $Origin `
            -Path $Path `
            -Method $Method `
            -TenantId $TenantId `
            -AccessToken $AccessToken `
            -TimeoutSeconds $TimeoutSeconds `
            -Body $Body
        if ($response.StatusCode -eq $ExpectedStatus) {
            return ConvertFrom-BunkFyAuthenticatedJsonResponse `
                -Response $response `
                -ExpectedStatus $ExpectedStatus `
                -Operation $Operation
        }

        $problemCode = Get-BunkFyAuthenticatedProblemCode -Response $response
        if ($response.StatusCode -ne 409 -or
            [string]::IsNullOrWhiteSpace($problemCode) -or
            $problemCode -cnotin $RetryableProblemCodes) {
            return ConvertFrom-BunkFyAuthenticatedJsonResponse `
                -Response $response `
                -ExpectedStatus $ExpectedStatus `
                -Operation $Operation
        }

        $lastProblemCode = $problemCode
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "$Operation did not converge before the timeout; last problem was '$lastProblemCode'."
}

function Assert-BunkFyAuthenticatedStatus {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ($Response.StatusCode -ne $ExpectedStatus) {
        throw "$Operation returned HTTP $($Response.StatusCode); expected HTTP $ExpectedStatus."
    }
}
