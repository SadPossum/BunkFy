[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][Guid] $WorkspaceId,
    [Parameter(Mandatory = $true)][Guid] $PropertyId,
    [Security.SecureString] $OperatorAccessToken,
    [Security.SecureString] $DeniedAccessToken,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [ValidateRange(10, 600)][int] $ConvergenceTimeoutSeconds = 180,
    [ValidateRange(250, 5000)][int] $PollIntervalMilliseconds = 1000,
    [string] $OutputPath,
    [switch] $AllowLoopbackHttp,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'deployed-public-edge.common.ps1')
. (Join-Path $PSScriptRoot 'deployed-authenticated-smoke.common.ps1')

$observedAdmissionEvidenceReference = $null
$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackHttp
if ($WorkspaceId -eq [Guid]::Empty -or $PropertyId -eq [Guid]::Empty) {
    throw 'WorkspaceId and PropertyId must not be empty GUIDs.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/ingestion-connection-lifecycle-$stamp.json"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) {
    $item = Get-Item -LiteralPath $OutputPath -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The output path is not a regular file: '$OutputPath'."
    }
    if (-not $Force) {
        throw "The output file already exists: '$OutputPath'. Use -Force to replace it."
    }
}

$operatorToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $OperatorAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_INGESTION_LIFECYCLE_OPERATOR_TOKEN' `
    -Prompt 'Ingestion connection lifecycle operator access token'
$deniedToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $DeniedAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_INGESTION_LIFECYCLE_DENIED_TOKEN' `
    -Prompt 'Ingestion connection lifecycle nonmember access token'
if ([string]::IsNullOrWhiteSpace($operatorToken) -or
    [string]::IsNullOrWhiteSpace($deniedToken)) {
    throw 'Both Ingestion lifecycle verification access tokens are required.'
}
if ($operatorToken -ceq $deniedToken) {
    throw 'The operator and nonmember access tokens must be distinct.'
}

$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$handler.AutomaticDecompression =
    [Net.DecompressionMethods]::GZip -bor
    [Net.DecompressionMethods]::Deflate -bor
    [Net.DecompressionMethods]::Brotli
$client = [Net.Http.HttpClient]::new($handler, $true)
$client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
$client.DefaultRequestHeaders.UserAgent.ParseAdd(
    'BunkFy-Deployed-Ingestion-Connection-Lifecycle-Probe/1')

$checks = [Collections.Generic.List[object]]::new()
$connectionId = [Guid]::NewGuid()
$createConnectionOperationId = $connectionId
$updateConnectionOperationId = [Guid]::NewGuid()
$clearSecretOperationId = [Guid]::NewGuid()
$disableConnectionOperationId = [Guid]::NewGuid()
$enableConnectionOperationId = [Guid]::NewGuid()
$credentialId = [Guid]::NewGuid()
$revokeCredentialOperationId = [Guid]::NewGuid()
$finalDisableOperationId = [Guid]::NewGuid()
$connectionCreateAttempted = $false
$credentialCreateAttempted = $false
$leaseClaimed = $false
$runTerminal = $false
$credentialRevoked = $false
$connectionDisabled = $false
$adapterToken = $null
$leaseProof = $null
$leaseCheckpoint = $null
$runId = [Guid]::Empty
$selectedCapability = $null
$observedReleaseId = $null
$initialConnectionVersion = 0L
$finalConnectionVersion = 0L
$initialCredentialVersion = 0L
$finalCredentialVersion = 0L
$suffix = $connectionId.ToString('N').Substring(0, 12)
$initialConfigurationReference = "synthetic://ingestion-lifecycle/$suffix/configuration-v1"
$updatedConfigurationReference = "synthetic://ingestion-lifecycle/$suffix/configuration-v2"
$syntheticSecretReference = "synthetic://ingestion-lifecycle/$suffix/secret-v1"
$credentialLabel = "Ingestion lifecycle proof $suffix"
$sourceSystem = "bunkfy.lifecycle.$suffix"
$credentialExpiresAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(30).ToString('O')

function Test-SmokeEnumValue {
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][int] $NumericValue,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $text = [string]$Value
    return $text -ceq [string]$NumericValue -or
        $text.Equals($Name, [StringComparison]::OrdinalIgnoreCase)
}

function Clear-SmokeResponseBody {
    param([AllowNull()][object] $Response)

    if ($null -ne $Response -and
        $null -ne $Response.Body -and
        $Response.Body.Length -gt 0) {
        [Array]::Clear($Response.Body, 0, $Response.Body.Length)
    }
}

function Invoke-SmokeApi {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PUT')][string] $Method,
        [AllowNull()][object] $Body,
        [string] $Token = $operatorToken,
        [string] $TenantId = $WorkspaceId.ToString('D')
    )

    return Invoke-BunkFyAuthenticatedJsonRequest `
        -Client $client `
        -Origin $origin `
        -Path $Path `
        -Method $Method `
        -TenantId $TenantId `
        -AccessToken $Token `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body $Body
}

function Invoke-AdapterApi {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][object] $Body,
        [Parameter(Mandatory = $true)][string] $Token
    )

    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Post,
        [Uri]::new($origin, $Path))
    $cancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($RequestTimeoutSeconds))
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new(
            'BunkFy-Adapter',
            $Token)
        [void]$request.Headers.TryAddWithoutValidation(
            'X-Tenant-Id',
            $WorkspaceId.ToString('D'))
        [void]$request.Headers.Accept.ParseAdd('application/json')
        $json = $Body | ConvertTo-Json -Depth 12 -Compress
        $request.Content = [Net.Http.StringContent]::new(
            $json,
            [Text.UTF8Encoding]::new($false),
            'application/json')

        $response = $client.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token).GetAwaiter().GetResult()
        try {
            $contentLength = $response.Content.Headers.ContentLength
            if ($null -ne $contentLength -and $contentLength -gt 256KB) {
                throw 'Adapter response body exceeds 262144 bytes.'
            }
            $bytes = $response.Content.ReadAsByteArrayAsync(
                $cancellation.Token).GetAwaiter().GetResult()
            if ($bytes.Length -gt 256KB) {
                [Array]::Clear($bytes, 0, $bytes.Length)
                throw 'Adapter response body exceeds 262144 bytes.'
            }
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Body = $bytes
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch [OperationCanceledException] {
        throw "Adapter request to '$Path' exceeded the $RequestTimeoutSeconds-second timeout."
    }
    finally {
        $cancellation.Dispose()
        $request.Dispose()
    }
}

function Read-SmokeJson {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    try {
        return ConvertFrom-BunkFyAuthenticatedJsonResponse `
            -Response $Response `
            -ExpectedStatus $ExpectedStatus `
            -Operation $Operation
    }
    finally {
        Clear-SmokeResponseBody -Response $Response
    }
}

function Assert-SmokeProblem {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $ExpectedCode,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    try {
        $actualCode = Get-BunkFyAuthenticatedProblemCode -Response $Response
        if ($Response.StatusCode -ne $ExpectedStatus -or $actualCode -cne $ExpectedCode) {
            throw "$Operation returned HTTP $($Response.StatusCode) with problem '$actualCode'; expected HTTP $ExpectedStatus with problem '$ExpectedCode'."
        }
    }
    finally {
        Clear-SmokeResponseBody -Response $Response
    }
}

function Assert-SmokeStatus {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    try {
        Assert-BunkFyAuthenticatedStatus `
            -Response $Response `
            -ExpectedStatus $ExpectedStatus `
            -Operation $Operation
    }
    finally {
        Clear-SmokeResponseBody -Response $Response
    }
}

function Assert-ConnectionReceipt {
    param(
        [Parameter(Mandatory = $true)][object] $Receipt,
        [Parameter(Mandatory = $true)][int] $Status,
        [Parameter(Mandatory = $true)][long] $Version,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ([Guid]$Receipt.connectionId -ne $connectionId -or
        -not (Test-SmokeEnumValue -Value $Receipt.status -NumericValue $Status -Name $(if ($Status -eq 1) { 'enabled' } else { 'disabled' })) -or
        [long]$Receipt.version -ne $Version) {
        throw "$Operation returned an invalid connection mutation receipt."
    }
}

function Assert-ConnectionReceiptReplay {
    param(
        [Parameter(Mandatory = $true)][object] $Original,
        [Parameter(Mandatory = $true)][object] $Replay,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ([Guid]$Replay.connectionId -ne [Guid]$Original.connectionId -or
        [string]$Replay.status -cne [string]$Original.status -or
        [long]$Replay.version -ne [long]$Original.version) {
        throw "$Operation was not stable."
    }
}

function Get-SmokeWorkspaceMembership {
    $matches = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $response = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/organizations?page=$page&pageSize=100" `
                -Method GET `
                -Body $null `
                -TenantId 'global') `
            -ExpectedStatus 200 `
            -Operation 'List operator workspaces'
        foreach ($entry in @($response.items)) {
            if ([Guid]$entry.organization.organizationId -eq $WorkspaceId) {
                [void]$matches.Add($entry.membership)
            }
        }
        $page++
        if ($page -gt 100) {
            throw 'The operator workspace preflight exceeded 100 pages.'
        }
    } while ([bool]$response.hasMore)

    if ($matches.Count -ne 1 -or
        [string]$matches[0].status -cne 'active' -or
        [string]::IsNullOrWhiteSpace([string]$matches[0].subjectId)) {
        throw 'The operator must have one active membership in the target workspace.'
    }
}

function Get-SmokeConnection {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read synthetic Ingestion connection'
}

function Get-SmokeConnectionOptional {
    $response = Invoke-SmokeApi `
        -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))" `
        -Method GET `
        -Body $null
    if ($response.StatusCode -eq 404) {
        Clear-SmokeResponseBody -Response $response
        return $null
    }
    return Read-SmokeJson `
        -Response $response `
        -ExpectedStatus 200 `
        -Operation 'Read synthetic Ingestion connection during cleanup'
}

function Get-SmokeConnectionDirectoryMatch {
    $matches = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $directory = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections?page=$page&pageSize=100" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List Ingestion connections'
        foreach ($item in @($directory.connections)) {
            if ([Guid]$item.connectionId -eq $connectionId) {
                [void]$matches.Add($item)
            }
        }
        $page++
        if ($page -gt 100) {
            throw 'The Ingestion connection directory exceeded 100 pages.'
        }
    } while ([bool]$directory.hasMore)

    if ($matches.Count -ne 1) {
        throw 'The synthetic Ingestion connection is not uniquely visible in the directory.'
    }
    return $matches[0]
}

function Get-SmokeCredentialMatch {
    $matches = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $directory = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/credentials?page=$page&pageSize=100" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List Ingestion ingress credentials'
        foreach ($item in @($directory.credentials)) {
            if ([Guid]$item.credentialId -eq $credentialId) {
                [void]$matches.Add($item)
            }
        }
        $page++
        if ($page -gt 100) {
            throw 'The Ingestion credential directory exceeded 100 pages.'
        }
    } while ([bool]$directory.hasMore)

    if ($matches.Count -ne 1) {
        throw 'The synthetic Ingestion credential is not uniquely visible in the directory.'
    }
    return $matches[0]
}

function Get-SmokeRun {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/runs/$($runId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read synthetic remote Ingestion run'
}

function Invoke-CreateConnection {
    param(
        [Parameter(Mandatory = $true)][string] $AdapterType,
        [Parameter(Mandatory = $true)][int] $ConflictPolicy,
        [Parameter(Mandatory = $true)][string] $ConfigurationReference
    )

    return Invoke-SmokeApi `
        -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections" `
        -Method POST `
        -Body ([ordered]@{
            operationId = $createConnectionOperationId.ToString('D')
            adapterType = $AdapterType
            executionMode = 4
            conflictPolicy = $ConflictPolicy
            configurationReference = $ConfigurationReference
            secretReference = $null
        })
}

function Invoke-CreateConnectionWithConvergence {
    param(
        [Parameter(Mandatory = $true)][string] $AdapterType,
        [Parameter(Mandatory = $true)][int] $ConflictPolicy,
        [Parameter(Mandatory = $true)][string] $ConfigurationReference
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $response = Invoke-CreateConnection `
            -AdapterType $AdapterType `
            -ConflictPolicy $ConflictPolicy `
            -ConfigurationReference $ConfigurationReference
        if ($response.StatusCode -eq 200) {
            return Read-SmokeJson `
                -Response $response `
                -ExpectedStatus 200 `
                -Operation 'Create synthetic Ingestion connection'
        }

        $problemCode = Get-BunkFyAuthenticatedProblemCode -Response $response
        if ($response.StatusCode -ne 409 -or
            $problemCode -cne 'Ingestion.CountryPolicyDenied.MissingBinding') {
            return Read-SmokeJson `
                -Response $response `
                -ExpectedStatus 200 `
                -Operation 'Create synthetic Ingestion connection'
        }

        Clear-SmokeResponseBody -Response $response
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "The Ingestion country-policy projection did not converge within $ConvergenceTimeoutSeconds seconds."
}

function Invoke-UpdateConnection {
    param(
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][int] $ConflictPolicy,
        [Parameter(Mandatory = $true)][string] $ConfigurationReference,
        [AllowNull()][object] $SecretReference,
        [Parameter(Mandatory = $true)][bool] $ClearSecretReference,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion
    )

    return Invoke-SmokeApi `
        -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))" `
        -Method PUT `
        -Body ([ordered]@{
            operationId = $OperationId.ToString('D')
            executionMode = 4
            conflictPolicy = $ConflictPolicy
            configurationReference = $ConfigurationReference
            secretReference = $SecretReference
            clearSecretReference = $ClearSecretReference
            expectedVersion = $ExpectedVersion
        })
}

function Invoke-ConnectionControl {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('enable', 'disable')][string] $Control,
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion
    )

    return Invoke-SmokeApi `
        -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/$Control" `
        -Method POST `
        -Body ([ordered]@{
            operationId = $OperationId.ToString('D')
            expectedVersion = $ExpectedVersion
        })
}

function Invoke-CreateCredential {
    param([Parameter(Mandatory = $true)][string] $Label)

    return Invoke-SmokeApi `
        -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/credentials" `
        -Method POST `
        -Body ([ordered]@{
            operationId = $credentialId.ToString('D')
            label = $Label
            expiresAtUtc = $credentialExpiresAtUtc
            sourceSystem = $sourceSystem
        })
}

function Invoke-RevokeCredential {
    param(
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion
    )

    return Invoke-SmokeApi `
        -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/credentials/$($credentialId.ToString('D'))/revoke" `
        -Method POST `
        -Body ([ordered]@{
            operationId = $OperationId.ToString('D')
            expectedVersion = $ExpectedVersion
        })
}

function Complete-SmokeLeaseForCleanup {
    if (-not $leaseClaimed -or $runTerminal) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($adapterToken) -or $null -eq $leaseProof) {
        throw 'The active synthetic lease cannot be completed because its credential material is unavailable.'
    }

    $completion = Read-SmokeJson `
        -Response (Invoke-AdapterApi `
            -Path "/api/ingestion/adapter-ingress/connections/$($connectionId.ToString('D'))/remote-leases/complete" `
            -Token $adapterToken `
            -Body ([ordered]@{
                lease = $leaseProof
                outcome = 4
                observedCount = 0
                acceptedCount = 0
                rejectedCount = 0
                acceptedCheckpoint = $leaseCheckpoint
                errorCode = $null
            })) `
        -ExpectedStatus 200 `
        -Operation 'Complete synthetic remote lease during cleanup'
    if ([Guid]$completion.runId -ne $runId -or
        -not (Test-SmokeEnumValue -Value $completion.outcome -NumericValue 4 -Name 'cancelled')) {
        throw 'Synthetic remote lease cleanup returned an invalid completion receipt.'
    }
    $script:runTerminal = $true
}

function Revoke-SmokeCredentialForCleanup {
    if (-not $credentialCreateAttempted) {
        return
    }
    $connection = Get-SmokeConnectionOptional
    if ($null -eq $connection) {
        return
    }
    $credential = Get-SmokeCredentialMatch
    if (Test-SmokeEnumValue -Value $credential.status -NumericValue 2 -Name 'revoked') {
        $script:credentialRevoked = $true
        $script:finalCredentialVersion = [long]$credential.version
        return
    }
    if (-not (Test-SmokeEnumValue -Value $credential.status -NumericValue 1 -Name 'active')) {
        throw 'The synthetic credential has an unsupported cleanup status.'
    }

    $receipt = Read-SmokeJson `
        -Response (Invoke-RevokeCredential `
            -OperationId ([Guid]::NewGuid()) `
            -ExpectedVersion ([long]$credential.version)) `
        -ExpectedStatus 200 `
        -Operation 'Revoke synthetic Ingestion credential during cleanup'
    if ([Guid]$receipt.credentialId -ne $credentialId -or
        -not (Test-SmokeEnumValue -Value $receipt.status -NumericValue 2 -Name 'revoked')) {
        throw 'Synthetic credential cleanup returned an invalid receipt.'
    }
    $script:credentialRevoked = $true
    $script:finalCredentialVersion = [long]$receipt.version
}

function Disable-SmokeConnectionForCleanup {
    if (-not $connectionCreateAttempted) {
        return
    }
    $connection = Get-SmokeConnectionOptional
    if ($null -eq $connection) {
        return
    }
    if (Test-SmokeEnumValue -Value $connection.status -NumericValue 2 -Name 'disabled') {
        $script:connectionDisabled = $true
        $script:finalConnectionVersion = [long]$connection.version
        return
    }
    if (-not (Test-SmokeEnumValue -Value $connection.status -NumericValue 1 -Name 'enabled')) {
        throw 'The synthetic connection has an unsupported cleanup status.'
    }

    $receipt = Read-SmokeJson `
        -Response (Invoke-ConnectionControl `
            -Control disable `
            -OperationId ([Guid]::NewGuid()) `
            -ExpectedVersion ([long]$connection.version)) `
        -ExpectedStatus 200 `
        -Operation 'Disable synthetic Ingestion connection during cleanup'
    if ([Guid]$receipt.connectionId -ne $connectionId -or
        -not (Test-SmokeEnumValue -Value $receipt.status -NumericValue 2 -Name 'disabled')) {
        throw 'Synthetic connection cleanup returned an invalid receipt.'
    }
    $script:connectionDisabled = $true
    $script:finalConnectionVersion = [long]$receipt.version
}

$workflowError = $null
$cleanupErrors = [Collections.Generic.List[string]]::new()
try {
    try {
        $releaseIdBefore = Assert-BunkFyPublicApiReleaseIdentity `
            -Client $client `
            -Origin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -TimeoutSeconds $RequestTimeoutSeconds `
            -ObservedAdmissionEvidenceReference ([ref]$observedAdmissionEvidenceReference)
        Get-SmokeWorkspaceMembership
        $property = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($PropertyId.ToString('D'))" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read Ingestion lifecycle property'
        $processing = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($PropertyId.ToString('D'))/processing" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read Ingestion lifecycle property processing state'
        if (-not (Test-SmokeEnumValue -Value $property.status -NumericValue 1 -Name 'active') -or
            -not (Test-SmokeEnumValue -Value $processing.configuredStatus -NumericValue 2 -Name 'enabled') -or
            -not (Test-SmokeEnumValue -Value $processing.effectiveStatus -NumericValue 2 -Name 'enabled') -or
            [string]$processing.reasonCode -cne 'Properties.CountryPolicy.Allowed' -or
            $null -eq $processing.governancePolicy) {
            throw 'The target property must be active with an already approved processing policy.'
        }
        $checks.Add([ordered]@{ name = 'scoped-operator-and-processing-preflight'; status = 'passed' })

        $deniedDirectory = Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections?page=1&pageSize=1" `
            -Method GET `
            -Body $null `
            -Token $deniedToken
        Assert-SmokeStatus `
            -Response $deniedDirectory `
            -ExpectedStatus 403 `
            -Operation 'Nonmember Ingestion connection directory read'
        $checks.Add([ordered]@{ name = 'nonmember-connections-denied'; status = 'passed' })

        $capabilities = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/adapter-types" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List registered Ingestion adapter capabilities'
        $remoteCapabilities = @($capabilities.adapterTypes | Where-Object {
                $modes = @($_.executionModes)
                @($modes | Where-Object {
                        Test-SmokeEnumValue -Value $_ -NumericValue 4 -Name 'remotePolling'
                    }).Count -gt 0
            } | Sort-Object -Property adapterType)
        $adapterNames = @($remoteCapabilities | ForEach-Object { [string]$_.adapterType })
        if ($remoteCapabilities.Count -lt 1 -or
            @($adapterNames | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
            @($adapterNames | Select-Object -Unique).Count -ne $adapterNames.Count) {
            throw 'The deployment does not expose a unique registered RemotePolling capability.'
        }
        $selectedCapability = $remoteCapabilities[0]
        if ([int]$selectedCapability.protocolVersion -le 0 -or
            [int]$selectedCapability.configurationSchemaVersion -le 0) {
            throw 'The selected RemotePolling capability has invalid protocol metadata.'
        }
        $checks.Add([ordered]@{ name = 'remote-capability-discovered'; status = 'passed' })

        if (-not $PSCmdlet.ShouldProcess(
                "workspace $($WorkspaceId.ToString('D')) property $($PropertyId.ToString('D'))",
                'Create and terminally disable a synthetic Ingestion connection and credential lifecycle')) {
            return
        }

        $connectionCreateAttempted = $true
        $created = Invoke-CreateConnectionWithConvergence `
            -AdapterType ([string]$selectedCapability.adapterType) `
            -ConflictPolicy 1 `
            -ConfigurationReference $initialConfigurationReference
        Assert-ConnectionReceipt -Receipt $created -Status 1 -Version 1 -Operation 'Synthetic Ingestion connection creation'
        $initialConnectionVersion = 1
        $checks.Add([ordered]@{ name = 'connection-created'; status = 'passed' })

        $createReplay = Read-SmokeJson `
            -Response (Invoke-CreateConnection `
                -AdapterType ([string]$selectedCapability.adapterType) `
                -ConflictPolicy 1 `
                -ConfigurationReference $initialConfigurationReference) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Ingestion connection creation'
        Assert-ConnectionReceiptReplay -Original $created -Replay $createReplay -Operation 'Exact connection create replay'
        $checks.Add([ordered]@{ name = 'connection-create-replay-stable'; status = 'passed' })

        $createConflict = Invoke-CreateConnection `
            -AdapterType ([string]$selectedCapability.adapterType) `
            -ConflictPolicy 2 `
            -ConfigurationReference $initialConfigurationReference
        Assert-SmokeProblem `
            -Response $createConflict `
            -ExpectedStatus 409 `
            -ExpectedCode 'Ingestion.ConnectionManagementOperationConflict' `
            -Operation 'Conflicting connection create operation reuse'
        $checks.Add([ordered]@{ name = 'connection-create-conflict-rejected'; status = 'passed' })

        $connection = Get-SmokeConnection
        $directoryConnection = Get-SmokeConnectionDirectoryMatch
        $health = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/health" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read new Ingestion connection health'
        if ([Guid]$connection.propertyId -ne $PropertyId -or
            [string]$connection.adapterType -cne [string]$selectedCapability.adapterType -or
            -not (Test-SmokeEnumValue -Value $connection.executionMode -NumericValue 4 -Name 'remotePolling') -or
            -not (Test-SmokeEnumValue -Value $connection.conflictPolicy -NumericValue 1 -Name 'suggestionsOnly') -or
            [string]$connection.configurationReference -cne $initialConfigurationReference -or
            [bool]$connection.hasSecretReference -or
            [long]$connection.version -ne 1 -or
            [Guid]$directoryConnection.connectionId -ne $connectionId -or
            -not (Test-SmokeEnumValue -Value $directoryConnection.status -NumericValue 1 -Name 'enabled') -or
            [Guid]$health.connectionId -ne $connectionId -or
            -not (Test-SmokeEnumValue -Value $health.capabilityStatus -NumericValue 1 -Name 'available') -or
            [int]$health.protocolVersion -ne [int]$selectedCapability.protocolVersion -or
            [int]$health.configurationSchemaVersion -ne [int]$selectedCapability.configurationSchemaVersion) {
            throw 'The new connection directory, detail, and health projections are inconsistent.'
        }
        $checks.Add([ordered]@{ name = 'connection-directory-detail-and-health-visible'; status = 'passed' })

        $updated = Read-SmokeJson `
            -Response (Invoke-UpdateConnection `
                -OperationId $updateConnectionOperationId `
                -ConflictPolicy 2 `
                -ConfigurationReference $updatedConfigurationReference `
                -SecretReference $syntheticSecretReference `
                -ClearSecretReference $false `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Update synthetic Ingestion connection'
        Assert-ConnectionReceipt -Receipt $updated -Status 1 -Version 2 -Operation 'Synthetic Ingestion connection update'
        $connection = Get-SmokeConnection
        if ([string]$connection.configurationReference -cne $updatedConfigurationReference -or
            -not [bool]$connection.hasSecretReference -or
            -not (Test-SmokeEnumValue -Value $connection.conflictPolicy -NumericValue 2 -Name 'autoApplyWhenAdapterBaselineUnchanged') -or
            [long]$connection.version -ne 2) {
            throw 'The connection update did not persist its configuration and opaque secret reference.'
        }
        $checks.Add([ordered]@{ name = 'connection-updated-with-secret-reference'; status = 'passed' })

        $updateReplay = Read-SmokeJson `
            -Response (Invoke-UpdateConnection `
                -OperationId $updateConnectionOperationId `
                -ConflictPolicy 2 `
                -ConfigurationReference $updatedConfigurationReference `
                -SecretReference $syntheticSecretReference `
                -ClearSecretReference $false `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Ingestion connection update'
        Assert-ConnectionReceiptReplay -Original $updated -Replay $updateReplay -Operation 'Exact connection update replay'
        $checks.Add([ordered]@{ name = 'connection-update-replay-stable'; status = 'passed' })

        $updateConflict = Invoke-UpdateConnection `
            -OperationId $updateConnectionOperationId `
            -ConflictPolicy 1 `
            -ConfigurationReference $updatedConfigurationReference `
            -SecretReference $syntheticSecretReference `
            -ClearSecretReference $false `
            -ExpectedVersion 1
        Assert-SmokeProblem -Response $updateConflict -ExpectedStatus 409 -ExpectedCode 'Ingestion.ConnectionManagementOperationConflict' -Operation 'Conflicting connection update operation reuse'
        $staleUpdate = Invoke-UpdateConnection `
            -OperationId ([Guid]::NewGuid()) `
            -ConflictPolicy 2 `
            -ConfigurationReference $updatedConfigurationReference `
            -SecretReference $syntheticSecretReference `
            -ClearSecretReference $false `
            -ExpectedVersion 1
        Assert-SmokeProblem -Response $staleUpdate -ExpectedStatus 409 -ExpectedCode 'Ingestion.VersionConflict' -Operation 'Stale connection update'
        $checks.Add([ordered]@{ name = 'connection-update-conflict-and-stale-write-rejected'; status = 'passed' })

        $cleared = Read-SmokeJson `
            -Response (Invoke-UpdateConnection `
                -OperationId $clearSecretOperationId `
                -ConflictPolicy 2 `
                -ConfigurationReference $updatedConfigurationReference `
                -SecretReference $null `
                -ClearSecretReference $true `
                -ExpectedVersion 2) `
            -ExpectedStatus 200 `
            -Operation 'Clear synthetic Ingestion secret reference'
        Assert-ConnectionReceipt -Receipt $cleared -Status 1 -Version 3 -Operation 'Synthetic secret-reference clear'
        $connection = Get-SmokeConnection
        if ([bool]$connection.hasSecretReference -or [long]$connection.version -ne 3) {
            throw 'The synthetic connection retained its cleared secret reference.'
        }
        $checks.Add([ordered]@{ name = 'secret-reference-cleared'; status = 'passed' })

        $disabled = Read-SmokeJson `
            -Response (Invoke-ConnectionControl `
                -Control disable `
                -OperationId $disableConnectionOperationId `
                -ExpectedVersion 3) `
            -ExpectedStatus 200 `
            -Operation 'Disable synthetic Ingestion connection'
        Assert-ConnectionReceipt -Receipt $disabled -Status 2 -Version 4 -Operation 'Synthetic Ingestion connection disable'
        $checks.Add([ordered]@{ name = 'connection-disabled'; status = 'passed' })

        $disableReplay = Read-SmokeJson `
            -Response (Invoke-ConnectionControl `
                -Control disable `
                -OperationId $disableConnectionOperationId `
                -ExpectedVersion 3) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Ingestion connection disable'
        Assert-ConnectionReceiptReplay -Original $disabled -Replay $disableReplay -Operation 'Exact connection disable replay'
        $checks.Add([ordered]@{ name = 'connection-disable-replay-stable'; status = 'passed' })

        $disableConflict = Invoke-ConnectionControl `
            -Control enable `
            -OperationId $disableConnectionOperationId `
            -ExpectedVersion 3
        Assert-SmokeProblem -Response $disableConflict -ExpectedStatus 409 -ExpectedCode 'Ingestion.ConnectionManagementOperationConflict' -Operation 'Conflicting connection disable operation reuse'
        $staleDisable = Invoke-ConnectionControl `
            -Control disable `
            -OperationId ([Guid]::NewGuid()) `
            -ExpectedVersion 3
        Assert-SmokeProblem -Response $staleDisable -ExpectedStatus 409 -ExpectedCode 'Ingestion.VersionConflict' -Operation 'Stale connection disable'
        $checks.Add([ordered]@{ name = 'connection-disable-conflict-and-stale-write-rejected'; status = 'passed' })

        $enabled = Read-SmokeJson `
            -Response (Invoke-ConnectionControl `
                -Control enable `
                -OperationId $enableConnectionOperationId `
                -ExpectedVersion 4) `
            -ExpectedStatus 200 `
            -Operation 'Enable synthetic Ingestion connection'
        Assert-ConnectionReceipt -Receipt $enabled -Status 1 -Version 5 -Operation 'Synthetic Ingestion connection enable'
        $checks.Add([ordered]@{ name = 'connection-enabled'; status = 'passed' })

        $enableReplay = Read-SmokeJson `
            -Response (Invoke-ConnectionControl `
                -Control enable `
                -OperationId $enableConnectionOperationId `
                -ExpectedVersion 4) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Ingestion connection enable'
        Assert-ConnectionReceiptReplay -Original $enabled -Replay $enableReplay -Operation 'Exact connection enable replay'
        $checks.Add([ordered]@{ name = 'connection-enable-replay-stable'; status = 'passed' })

        $enableConflict = Invoke-ConnectionControl `
            -Control disable `
            -OperationId $enableConnectionOperationId `
            -ExpectedVersion 4
        Assert-SmokeProblem -Response $enableConflict -ExpectedStatus 409 -ExpectedCode 'Ingestion.ConnectionManagementOperationConflict' -Operation 'Conflicting connection enable operation reuse'
        $staleEnable = Invoke-ConnectionControl `
            -Control enable `
            -OperationId ([Guid]::NewGuid()) `
            -ExpectedVersion 4
        Assert-SmokeProblem -Response $staleEnable -ExpectedStatus 409 -ExpectedCode 'Ingestion.VersionConflict' -Operation 'Stale connection enable'
        $checks.Add([ordered]@{ name = 'connection-enable-conflict-and-stale-write-rejected'; status = 'passed' })

        $credentialCreateAttempted = $true
        $credentialResponseRaw = Invoke-CreateCredential -Label $credentialLabel
        try {
            $credentialResponse = ConvertFrom-BunkFyAuthenticatedJsonResponse `
                -Response $credentialResponseRaw `
                -ExpectedStatus 200 `
                -Operation 'Issue synthetic Ingestion ingress credential'
        }
        finally {
            Clear-SmokeResponseBody -Response $credentialResponseRaw
        }
        $adapterToken = [string]$credentialResponse.token
        if ([Guid]$credentialResponse.credential.credentialId -ne $credentialId -or
            [Guid]$credentialResponse.credential.connectionId -ne $connectionId -or
            -not (Test-SmokeEnumValue -Value $credentialResponse.credential.status -NumericValue 1 -Name 'active') -or
            -not (Test-SmokeEnumValue -Value $credentialResponse.outcome -NumericValue 1 -Name 'issued') -or
            [string]$credentialResponse.credential.adapterType -cne [string]$selectedCapability.adapterType -or
            [int]$credentialResponse.credential.adapterProtocolVersion -ne [int]$selectedCapability.protocolVersion -or
            [int]$credentialResponse.credential.configurationSchemaVersion -ne [int]$selectedCapability.configurationSchemaVersion -or
            [string]$credentialResponse.credential.sourceSystem -cne $sourceSystem -or
            [long]$credentialResponse.credential.version -ne 1 -or
            [string]::IsNullOrWhiteSpace($adapterToken) -or
            $adapterToken.Length -gt 512 -or
            @($adapterToken.ToCharArray() | Where-Object {
                    [char]::IsWhiteSpace($_) -or [char]::IsControl($_)
                }).Count -gt 0) {
            throw 'The synthetic ingress credential issuance response is invalid.'
        }
        $initialCredentialVersion = 1
        $credentialResponse.token = $null
        $checks.Add([ordered]@{ name = 'ingress-credential-issued-once'; status = 'passed' })

        $credentialReplay = Read-SmokeJson `
            -Response (Invoke-CreateCredential -Label $credentialLabel) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Ingestion ingress credential issuance'
        if ([Guid]$credentialReplay.credential.credentialId -ne $credentialId -or
            -not (Test-SmokeEnumValue -Value $credentialReplay.outcome -NumericValue 2 -Name 'alreadyIssued') -or
            $null -ne $credentialReplay.token -or
            [long]$credentialReplay.credential.version -ne 1) {
            throw 'Exact credential issuance replay redisclosed or drifted from the one-time result.'
        }
        $checks.Add([ordered]@{ name = 'ingress-credential-replay-withholds-token'; status = 'passed' })

        $credentialConflict = Invoke-CreateCredential -Label "$credentialLabel conflict"
        Assert-SmokeProblem -Response $credentialConflict -ExpectedStatus 409 -ExpectedCode 'Ingestion.ConnectionManagementOperationConflict' -Operation 'Conflicting credential issuance operation reuse'
        $checks.Add([ordered]@{ name = 'ingress-credential-create-conflict-rejected'; status = 'passed' })

        $credential = Get-SmokeCredentialMatch
        if (-not (Test-SmokeEnumValue -Value $credential.status -NumericValue 1 -Name 'active') -or
            [long]$credential.version -ne 1 -or
            $null -ne $credential.lastAuthenticatedAtUtc) {
            throw 'The newly issued credential directory projection is invalid.'
        }
        $checks.Add([ordered]@{ name = 'ingress-credential-directory-visible'; status = 'passed' })

        $claimId = [Guid]::NewGuid()
        $workerId = [Guid]::NewGuid()
        $claim = Read-SmokeJson `
            -Response (Invoke-AdapterApi `
                -Path "/api/ingestion/adapter-ingress/connections/$($connectionId.ToString('D'))/remote-leases/claim" `
                -Token $adapterToken `
                -Body ([ordered]@{
                    claimId = $claimId.ToString('D')
                    workerId = $workerId.ToString('D')
                    adapterType = [string]$selectedCapability.adapterType
                    protocolVersion = [int]$selectedCapability.protocolVersion
                    configurationSchemaVersion = [int]$selectedCapability.configurationSchemaVersion
                    requestedLeaseSeconds = 120
                })) `
            -ExpectedStatus 200 `
            -Operation 'Claim synthetic remote adapter lease'
        $runId = [Guid]$claim.assignment.runId
        $leaseId = [Guid]$claim.assignment.leaseId
        if ($runId -eq [Guid]::Empty -or $leaseId -eq [Guid]::Empty -or
            [Guid]$claim.assignment.connectionId -ne $connectionId -or
            [Guid]$claim.assignment.propertyId -ne $PropertyId -or
            [string]$claim.assignment.adapterType -cne [string]$selectedCapability.adapterType -or
            [long]$claim.leaseEpoch -le 0 -or
            [int]$claim.renewAfterSeconds -lt 10) {
            throw 'The synthetic remote lease assignment is invalid.'
        }
        $leaseProof = [ordered]@{
            runId = $runId.ToString('D')
            leaseId = $leaseId.ToString('D')
            leaseEpoch = [long]$claim.leaseEpoch
            workerId = $workerId.ToString('D')
        }
        $leaseCheckpoint = $claim.assignment.checkpoint
        $leaseClaimed = $true
        $checks.Add([ordered]@{ name = 'remote-lease-claimed-with-issued-credential'; status = 'passed' })

        $completion = Read-SmokeJson `
            -Response (Invoke-AdapterApi `
                -Path "/api/ingestion/adapter-ingress/connections/$($connectionId.ToString('D'))/remote-leases/complete" `
                -Token $adapterToken `
                -Body ([ordered]@{
                    lease = $leaseProof
                    outcome = 1
                    observedCount = 0
                    acceptedCount = 0
                    rejectedCount = 0
                    acceptedCheckpoint = $leaseCheckpoint
                    errorCode = $null
                })) `
            -ExpectedStatus 200 `
            -Operation 'Complete synthetic zero-observation remote run'
        if ([Guid]$completion.runId -ne $runId -or
            [Guid]$completion.leaseId -ne $leaseId -or
            [long]$completion.leaseEpoch -ne [long]$claim.leaseEpoch -or
            -not (Test-SmokeEnumValue -Value $completion.outcome -NumericValue 1 -Name 'succeeded') -or
            $null -ne $completion.acceptedCheckpoint) {
            throw 'The synthetic zero-observation run completion receipt is invalid.'
        }
        $runTerminal = $true
        $checks.Add([ordered]@{ name = 'zero-observation-run-completed'; status = 'passed' })

        $run = Get-SmokeRun
        $health = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/health" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read terminal synthetic Ingestion health'
        if ([Guid]$run.connectionId -ne $connectionId -or
            -not (Test-SmokeEnumValue -Value $run.executionKind -NumericValue 2 -Name 'remoteLease') -or
            -not (Test-SmokeEnumValue -Value $run.status -NumericValue 2 -Name 'succeeded') -or
            [int]$run.observedCount -ne 0 -or [int]$run.acceptedCount -ne 0 -or
            [int]$run.rejectedCount -ne 0 -or $null -eq $run.completedAtUtc -or
            [Guid]$health.latestRunId -ne $runId -or
            -not (Test-SmokeEnumValue -Value $health.latestRunStatus -NumericValue 2 -Name 'succeeded') -or
            -not (Test-SmokeEnumValue -Value $health.operationalState -NumericValue 4 -Name 'lastRunSucceeded') -or
            -not (Test-SmokeEnumValue -Value $health.capabilityStatus -NumericValue 1 -Name 'available')) {
            throw 'The terminal remote run and connection health projections are inconsistent.'
        }
        $checks.Add([ordered]@{ name = 'terminal-run-and-health-visible'; status = 'passed' })

        $credential = Get-SmokeCredentialMatch
        if ($null -eq $credential.lastAuthenticatedAtUtc -or
            [long]$credential.version -ne 1 -or
            -not (Test-SmokeEnumValue -Value $credential.status -NumericValue 1 -Name 'active')) {
            throw 'Credential authentication telemetry did not become visible without changing its optimistic version.'
        }
        $checks.Add([ordered]@{ name = 'credential-authentication-telemetry-visible'; status = 'passed' })

        $revoked = Read-SmokeJson `
            -Response (Invoke-RevokeCredential `
                -OperationId $revokeCredentialOperationId `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Revoke synthetic Ingestion ingress credential'
        if ([Guid]$revoked.credentialId -ne $credentialId -or
            [Guid]$revoked.connectionId -ne $connectionId -or
            -not (Test-SmokeEnumValue -Value $revoked.status -NumericValue 2 -Name 'revoked') -or
            [long]$revoked.version -ne 2) {
            throw 'The synthetic credential revocation receipt is invalid.'
        }
        $credentialRevoked = $true
        $finalCredentialVersion = 2
        $checks.Add([ordered]@{ name = 'ingress-credential-revoked'; status = 'passed' })

        $revokeReplay = Read-SmokeJson `
            -Response (Invoke-RevokeCredential `
                -OperationId $revokeCredentialOperationId `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Ingestion credential revocation'
        if ([Guid]$revokeReplay.credentialId -ne [Guid]$revoked.credentialId -or
            [string]$revokeReplay.status -cne [string]$revoked.status -or
            [long]$revokeReplay.version -ne [long]$revoked.version) {
            throw 'Exact credential revocation replay was not stable.'
        }
        $checks.Add([ordered]@{ name = 'ingress-credential-revoke-replay-stable'; status = 'passed' })

        $revokeConflict = Invoke-RevokeCredential `
            -OperationId $revokeCredentialOperationId `
            -ExpectedVersion 0
        Assert-SmokeProblem -Response $revokeConflict -ExpectedStatus 409 -ExpectedCode 'Ingestion.ConnectionManagementOperationConflict' -Operation 'Conflicting credential revocation operation reuse'
        $staleRevoke = Invoke-RevokeCredential `
            -OperationId ([Guid]::NewGuid()) `
            -ExpectedVersion 1
        Assert-SmokeProblem -Response $staleRevoke -ExpectedStatus 409 -ExpectedCode 'Ingestion.VersionConflict' -Operation 'Stale credential revocation'
        $checks.Add([ordered]@{ name = 'ingress-credential-revoke-conflict-and-stale-write-rejected'; status = 'passed' })

        $revokedClaim = Invoke-AdapterApi `
            -Path "/api/ingestion/adapter-ingress/connections/$($connectionId.ToString('D'))/remote-leases/claim" `
            -Token $adapterToken `
            -Body ([ordered]@{
                claimId = [Guid]::NewGuid().ToString('D')
                workerId = [Guid]::NewGuid().ToString('D')
                adapterType = [string]$selectedCapability.adapterType
                protocolVersion = [int]$selectedCapability.protocolVersion
                configurationSchemaVersion = [int]$selectedCapability.configurationSchemaVersion
                requestedLeaseSeconds = 120
            })
        Assert-SmokeStatus -Response $revokedClaim -ExpectedStatus 401 -Operation 'Lease claim with revoked ingress credential'
        $adapterToken = $null
        $checks.Add([ordered]@{ name = 'revoked-credential-denied'; status = 'passed' })

        $connection = Get-SmokeConnection
        $finalDisabled = Read-SmokeJson `
            -Response (Invoke-ConnectionControl `
                -Control disable `
                -OperationId $finalDisableOperationId `
                -ExpectedVersion ([long]$connection.version)) `
            -ExpectedStatus 200 `
            -Operation 'Finally disable synthetic Ingestion connection'
        if ([Guid]$finalDisabled.connectionId -ne $connectionId -or
            -not (Test-SmokeEnumValue -Value $finalDisabled.status -NumericValue 2 -Name 'disabled') -or
            [long]$finalDisabled.version -le [long]$connection.version) {
            throw 'The final synthetic connection disable receipt is invalid.'
        }
        $connectionDisabled = $true
        $finalConnectionVersion = [long]$finalDisabled.version
        $checks.Add([ordered]@{ name = 'connection-finally-disabled'; status = 'passed' })

        $connection = Get-SmokeConnection
        $directoryConnection = Get-SmokeConnectionDirectoryMatch
        $credential = Get-SmokeCredentialMatch
        $run = Get-SmokeRun
        $health = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/health" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read final synthetic Ingestion connection health'
        if (-not (Test-SmokeEnumValue -Value $connection.status -NumericValue 2 -Name 'disabled') -or
            [long]$connection.version -ne $finalConnectionVersion -or
            [bool]$connection.hasSecretReference -or
            -not (Test-SmokeEnumValue -Value $directoryConnection.status -NumericValue 2 -Name 'disabled') -or
            -not (Test-SmokeEnumValue -Value $credential.status -NumericValue 2 -Name 'revoked') -or
            [long]$credential.version -ne $finalCredentialVersion -or
            -not (Test-SmokeEnumValue -Value $run.status -NumericValue 2 -Name 'succeeded') -or
            -not (Test-SmokeEnumValue -Value $health.connectionStatus -NumericValue 2 -Name 'disabled') -or
            -not (Test-SmokeEnumValue -Value $health.operationalState -NumericValue 1 -Name 'disabled') -or
            [Guid]$health.latestRunId -ne $runId -or
            -not (Test-SmokeEnumValue -Value $health.latestRunStatus -NumericValue 2 -Name 'succeeded')) {
            throw 'The final disabled connection, revoked credential, run, directory, and health projections are inconsistent.'
        }
        $checks.Add([ordered]@{ name = 'terminal-projections-consistent'; status = 'passed' })

        $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
            -Client $client `
            -Origin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -TimeoutSeconds $RequestTimeoutSeconds `
            -ObservedAdmissionEvidenceReference ([ref]$observedAdmissionEvidenceReference)
        if ($observedReleaseId -cne $releaseIdBefore) {
            throw 'The public API release identity changed during Ingestion lifecycle verification.'
        }
        $checks.Add([ordered]@{ name = 'release-identity-continuous'; status = 'passed' })
    }
    catch {
        $workflowError = $_.Exception
    }
    finally {
        try {
            Complete-SmokeLeaseForCleanup
        }
        catch {
            $cleanupErrors.Add("remote-run: $($_.Exception.Message)")
        }
        try {
            Revoke-SmokeCredentialForCleanup
        }
        catch {
            $cleanupErrors.Add("credential: $($_.Exception.Message)")
        }
        try {
            Disable-SmokeConnectionForCleanup
        }
        catch {
            $cleanupErrors.Add("connection: $($_.Exception.Message)")
        }
    }
}
finally {
    $client.Dispose()
    $operatorToken = $null
    $deniedToken = $null
    $adapterToken = $null
    $initialConfigurationReference = $null
    $updatedConfigurationReference = $null
    $syntheticSecretReference = $null
    $credentialLabel = $null
    $sourceSystem = $null
    $credentialExpiresAtUtc = $null
}

if ($cleanupErrors.Count -gt 0) {
    $cleanupSummary = $cleanupErrors -join '; '
    if ($null -ne $workflowError) {
        throw "Ingestion connection lifecycle workflow failed: $($workflowError.Message) Cleanup also failed: $cleanupSummary"
    }
    throw "Ingestion connection lifecycle cleanup failed: $cleanupSummary"
}
if ($null -ne $workflowError) {
    throw $workflowError
}
if (-not $connectionDisabled -or -not $credentialRevoked -or
    -not $leaseClaimed -or -not $runTerminal) {
    throw 'Ingestion connection lifecycle verification did not reach its required terminal cleanup state.'
}
if ($checks.Count -ne 32) {
    throw "Ingestion connection lifecycle verification recorded $($checks.Count) checks; expected 32."
}

$evidence = [ordered]@{
    schemaVersion = 2
    evidenceKind = 'bunkfy-deployed-ingestion-connection-lifecycle-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    admissionEvidenceReference = $observedAdmissionEvidenceReference
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-fixture' }
    result = 'passed'
    workflow = [ordered]@{
        executionMode = 'remote-polling'
        protocolVersion = [int]$selectedCapability.protocolVersion
        configurationSchemaVersion = [int]$selectedCapability.configurationSchemaVersion
        connectionFinalStatus = 'disabled'
        connectionVersionAdvanced = $finalConnectionVersion -gt $initialConnectionVersion
        secretReferenceLifecycle = 'set-then-cleared'
        credentialFinalStatus = 'revoked'
        credentialVersionAdvanced = $finalCredentialVersion -gt $initialCredentialVersion
        credentialIssuance = 'one-time-nonredisclosing'
        independentAuthentication = 'issued-accepted-then-revoked-denied'
        runFinalStatus = 'succeeded'
        runObservedCount = 0
        activeLease = $false
    }
    cleanup = [ordered]@{
        connectionDisposition = 'synthetic-disabled-retained'
        credentialDisposition = 'synthetic-revoked-retained'
        runDisposition = 'synthetic-succeeded-empty-retained'
        parentPropertyLifecycleOwnedByCaller = $true
    }
    checks = @($checks)
    limitations = @(
        'provider-record-receipt-proposal-and-checkpoint-not-exercised',
        'country-policy-activation-and-rebinding-not-exercised',
        'production-secret-manager-and-orchestrator-rotation-not-exercised',
        'synthetic-disabled-control-state-retained'
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

Write-Host "BunkFy deployed Ingestion connection lifecycle verification passed for '$ExpectedReleaseId'."
Write-Host "Evidence: $OutputPath"
