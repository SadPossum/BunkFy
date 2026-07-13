Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-BunkFySecureString {
    param([Parameter(Mandatory = $true)][Security.SecureString] $Value)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Resolve-BunkFyAdminAccessToken {
    param([Security.SecureString] $AccessToken)

    if ($null -ne $AccessToken) {
        return ConvertFrom-BunkFySecureString -Value $AccessToken
    }

    if (-not [string]::IsNullOrWhiteSpace($env:BUNKFY_ADMIN_TOKEN)) {
        return $env:BUNKFY_ADMIN_TOKEN.Trim()
    }

    $prompted = Read-Host 'Admin API access token' -AsSecureString
    return ConvertFrom-BunkFySecureString -Value $prompted
}

function Invoke-BunkFyAdminApi {
    param(
        [Parameter(Mandatory = $true)][string] $BaseUri,
        [Parameter(Mandatory = $true)][string] $TenantId,
        [Parameter(Mandatory = $true)][string] $AccessToken,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string] $Method,
        [Parameter(Mandatory = $true)][string] $Path,
        [object] $Body
    )

    $uri = '{0}{1}' -f $BaseUri.TrimEnd('/'), $Path
    $parameters = @{
        Uri = $uri
        Method = $Method
        Headers = @{
            Authorization = "Bearer $AccessToken"
            'X-Tenant-Id' = $TenantId
        }
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 12 -Compress
    }

    $maximumAttempts = 6
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            $responseBody = Invoke-RestMethod @parameters
            return $responseBody
        }
        catch {
            $response = $_.Exception.Response
            $statusCode = if ($null -ne $response) {
                [int]$response.StatusCode
            }
            else {
                0
            }

            if ($statusCode -eq 429 -and $attempt -lt $maximumAttempts) {
                $delaySeconds = [int][Math]::Min(15, [Math]::Pow(2, $attempt - 1))
                if ($null -ne $response -and $null -ne $response.Headers) {
                    $retryAfter = $response.Headers['Retry-After']
                    $parsedRetryAfter = 0
                    if ([int]::TryParse([string]$retryAfter, [ref]$parsedRetryAfter) -and $parsedRetryAfter -gt 0) {
                        $delaySeconds = [Math]::Min(30, $parsedRetryAfter)
                    }
                }

                Write-Warning "Admin API rate limit reached; retrying in $delaySeconds second(s)."
                Start-Sleep -Seconds $delaySeconds
                continue
            }

            $detail = if ($null -ne $_.ErrorDetails) {
                $_.ErrorDetails.Message
            }
            else {
                $null
            }
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = $_.Exception.Message
            }

            throw "Admin API $Method $Path failed: $detail"
        }
    }
}

function Read-BunkFyOperationState {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-BunkFyOperationState {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][object] $State
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $temporaryPath = "$Path.tmp"
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Add-BunkFyStateProperty {
    param(
        [Parameter(Mandatory = $true)][object] $State,
        [Parameter(Mandatory = $true)][string] $Name,
        [object] $Value
    )

    if ($null -eq $State.PSObject.Properties[$Name]) {
        $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function ConvertTo-BunkFyUrlValue {
    param([Parameter(Mandatory = $true)][string] $Value)

    return [Uri]::EscapeDataString($Value)
}
