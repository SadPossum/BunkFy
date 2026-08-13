[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][Guid] $WorkspaceId,
    [Parameter(Mandatory = $true)][Guid] $PropertyId,
    [Parameter(Mandatory = $true)][Guid] $InventoryUnitId,
    [Parameter(Mandatory = $true)][DateTime] $Arrival,
    [Parameter(Mandatory = $true)][DateTime] $Departure,
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

$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackHttp
if ($WorkspaceId -eq [Guid]::Empty -or
    $PropertyId -eq [Guid]::Empty -or
    $InventoryUnitId -eq [Guid]::Empty) {
    throw 'WorkspaceId, PropertyId, and InventoryUnitId must not be empty GUIDs.'
}
$arrivalDate = $Arrival.Date
$departureDate = $Departure.Date
if ($departureDate -le $arrivalDate) {
    throw 'Departure must be later than Arrival.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/ingestion-conflict-proposal-lifecycle-$stamp.json"
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
    -EnvironmentVariable 'BUNKFY_SMOKE_INGESTION_PROPOSAL_OPERATOR_TOKEN' `
    -Prompt 'Ingestion proposal lifecycle operator access token'
$deniedToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $DeniedAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_INGESTION_PROPOSAL_DENIED_TOKEN' `
    -Prompt 'Ingestion proposal lifecycle nonmember access token'
if ([string]::IsNullOrWhiteSpace($operatorToken) -or
    [string]::IsNullOrWhiteSpace($deniedToken)) {
    throw 'Both Ingestion proposal lifecycle access tokens are required.'
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
    'BunkFy-Deployed-Ingestion-Conflict-Proposal-Lifecycle-Probe/1')

$checks = [Collections.Generic.List[object]]::new()
$connectionId = [Guid]::NewGuid()
$credentialId = [Guid]::NewGuid()
$revokeCredentialOperationId = [Guid]::NewGuid()
$disableConnectionOperationId = [Guid]::NewGuid()
$staffEditOperationId = [Guid]::NewGuid()
$cleanupCancelOperationId = [Guid]::NewGuid()
$externalRecordId = "proposal-proof-$($connectionId.ToString('N'))"
$suffix = $connectionId.ToString('N').Substring(0, 12)
$configurationReference = "synthetic://ingestion-proposal/$suffix/configuration"
$credentialLabel = "Ingestion proposal proof $suffix"
$sourceSystem = "bunkfy.proposal.$suffix"
$credentialExpiresAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(45).ToString('O')
$guestNames = [ordered]@{
    Initial = "Synthetic initial $suffix"
    Automatic = "Synthetic automatic $suffix"
    Staff = "Synthetic staff $suffix"
    FirstProposal = "Synthetic first proposal $suffix"
    RejectedProposal = "Synthetic rejected proposal $suffix"
    AcceptedProposal = "Synthetic accepted proposal $suffix"
}
$connectionCreateAttempted = $false
$credentialCreateAttempted = $false
$credentialRevoked = $false
$connectionDisabled = $false
$reservationCancelled = $false
$adapterToken = $null
$reservationId = [Guid]::Empty
$firstProposalId = [Guid]::Empty
$rejectedProposalId = [Guid]::Empty
$acceptedProposalId = [Guid]::Empty
$initialDetailsRevision = 0L
$automaticDetailsRevision = 0L
$staffDetailsRevision = 0L
$acceptedDetailsRevision = 0L
$finalCredentialVersion = 0L
$finalConnectionVersion = 0L
$observedReleaseId = $null
$cleanupErrors = [Collections.Generic.List[string]]::new()
$workflowError = $null

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
            $length = $response.Content.Headers.ContentLength
            if ($null -ne $length -and $length -gt 256KB) {
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

function Get-SmokeWorkspaceMembership {
    $matches = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $directory = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/organizations?page=$page&pageSize=100" `
                -Method GET `
                -Body $null `
                -TenantId 'global') `
            -ExpectedStatus 200 `
            -Operation 'List proposal lifecycle operator workspaces'
        foreach ($entry in @($directory.items)) {
            if ([Guid]$entry.organization.organizationId -eq $WorkspaceId) {
                [void]$matches.Add($entry.membership)
            }
        }
        $page++
        if ($page -gt 100) {
            throw 'The operator workspace preflight exceeded 100 pages.'
        }
    } while ([bool]$directory.hasMore)

    if ($matches.Count -ne 1 -or
        [string]$matches[0].status -cne 'active' -or
        [string]::IsNullOrWhiteSpace([string]$matches[0].subjectId)) {
        throw 'The operator must have one active membership in the target workspace.'
    }
}

function Invoke-CreateConnection {
    param([Parameter(Mandatory = $true)][string] $AdapterType)

    return Invoke-SmokeApi `
        -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections" `
        -Method POST `
        -Body ([ordered]@{
            operationId = $connectionId.ToString('D')
            adapterType = $AdapterType
            executionMode = 3
            conflictPolicy = 2
            configurationReference = $configurationReference
            secretReference = $null
        })
}

function Invoke-CreateConnectionWithConvergence {
    param([Parameter(Mandatory = $true)][string] $AdapterType)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $response = Invoke-CreateConnection -AdapterType $AdapterType
        if ($response.StatusCode -eq 200) {
            return Read-SmokeJson `
                -Response $response `
                -ExpectedStatus 200 `
                -Operation 'Create synthetic proposal lifecycle connection'
        }
        $problemCode = Get-BunkFyAuthenticatedProblemCode -Response $response
        if ($response.StatusCode -ne 409 -or
            $problemCode -cne 'Ingestion.CountryPolicyDenied.MissingBinding') {
            return Read-SmokeJson `
                -Response $response `
                -ExpectedStatus 200 `
                -Operation 'Create synthetic proposal lifecycle connection'
        }
        Clear-SmokeResponseBody -Response $response
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "The Ingestion country-policy projection did not converge within $ConvergenceTimeoutSeconds seconds."
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
        -Operation 'Read synthetic proposal lifecycle connection'
}

function Invoke-CreateCredential {
    return Invoke-SmokeApi `
        -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/credentials" `
        -Method POST `
        -Body ([ordered]@{
            operationId = $credentialId.ToString('D')
            label = $credentialLabel
            expiresAtUtc = $credentialExpiresAtUtc
            sourceSystem = $sourceSystem
        })
}

function Get-SmokeCredentialOptional {
    $page = 1
    do {
        $response = Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/credentials?page=$page&pageSize=100" `
            -Method GET `
            -Body $null
        if ($response.StatusCode -eq 404) {
            Clear-SmokeResponseBody -Response $response
            return $null
        }
        $directory = Read-SmokeJson `
            -Response $response `
            -ExpectedStatus 200 `
            -Operation 'List proposal lifecycle credentials'
        foreach ($credential in @($directory.credentials)) {
            if ([Guid]$credential.credentialId -eq $credentialId) {
                return $credential
            }
        }
        $page++
        if ($page -gt 100) {
            throw 'The proposal lifecycle credential directory exceeded 100 pages.'
        }
    } while ([bool]$directory.hasMore)
    return $null
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

function Invoke-DisableConnection {
    param(
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion
    )

    return Invoke-SmokeApi `
        -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/connections/$($connectionId.ToString('D'))/disable" `
        -Method POST `
        -Body ([ordered]@{
            operationId = $OperationId.ToString('D')
            expectedVersion = $ExpectedVersion
        })
}

function New-SmokeObservation {
    param(
        [Parameter(Mandatory = $true)][long] $Sequence,
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][ValidateSet('upsert', 'cancel')][string] $Kind,
        [AllowNull()][string] $GuestName
    )

    $payload = if ($Kind -ceq 'cancel') {
        [ordered]@{
            operation = 'cancel'
            sourceSequence = $Sequence
            arrival = $null
            departure = $null
            expectedArrivalTime = $null
            expectedDepartureTime = $null
            inventoryUnitIds = $null
            primaryGuestName = $null
            email = $null
            phone = $null
            guestCount = $null
            notes = $null
        }
    }
    else {
        [ordered]@{
            operation = 'upsert'
            sourceSequence = $Sequence
            arrival = $arrivalDate.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            departure = $departureDate.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            expectedArrivalTime = '15:00:00'
            expectedDepartureTime = '11:00:00'
            inventoryUnitIds = @($InventoryUnitId.ToString('D'))
            primaryGuestName = $GuestName
            email = $null
            phone = $null
            guestCount = 1
            notes = $null
        }
    }
    $json = $payload | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $hash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $now = [DateTimeOffset]::UtcNow.ToString('O')
    return [pscustomobject]@{
        OperationId = $OperationId
        Body = [ordered]@{
            records = @([ordered]@{
                operationId = $OperationId.ToString('D')
                recordType = 'reservation.v1'
                externalRecordId = $externalRecordId
                sourceRevision = $Sequence.ToString([Globalization.CultureInfo]::InvariantCulture)
                sourceUpdatedAtUtc = $now
                observedAtUtc = $now
                contentType = 'application/json'
                payload = [Convert]::ToBase64String($bytes)
                contentSha256 = $hash
            })
        }
        Bytes = $bytes
    }
}

function Submit-SmokeObservation {
    param(
        [Parameter(Mandatory = $true)][object] $Observation,
        [Parameter(Mandatory = $true)][int] $ExpectedDisposition,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    try {
        $submission = Read-SmokeJson `
            -Response (Invoke-AdapterApi `
                -Path "/api/ingestion/adapter-ingress/connections/$($connectionId.ToString('D'))/observations" `
                -Body $Observation.Body `
                -Token $adapterToken) `
            -ExpectedStatus 200 `
            -Operation $Operation
        $result = @($submission.results)
        if ($result.Count -ne 1 -or
            [Guid]$result[0].operationId -ne $Observation.OperationId -or
            -not (Test-SmokeEnumValue `
                -Value $result[0].disposition `
                -NumericValue $ExpectedDisposition `
                -Name $(if ($ExpectedDisposition -eq 1) { 'accepted' } elseif ($ExpectedDisposition -eq 2) { 'duplicate' } else { 'rejected' }))) {
            throw "$Operation returned an invalid observation acknowledgement."
        }
        return $result[0]
    }
    finally {
        if ($null -ne $Observation.Bytes -and $Observation.Bytes.Length -gt 0) {
            [Array]::Clear($Observation.Bytes, 0, $Observation.Bytes.Length)
        }
    }
}

function Get-SmokeReceipt {
    param([Parameter(Mandatory = $true)][Guid] $ReceiptId)

    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/receipts/$($ReceiptId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read proposal lifecycle observation receipt'
}

function Get-SmokeReservationOptional {
    $search = [Uri]::EscapeDataString($externalRecordId)
    $directory = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/reservations/properties/$($PropertyId.ToString('D'))?search=$search&page=1&pageSize=10" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Find proposal lifecycle reservation'
    $items = @($directory.reservations)
    if ($items.Count -eq 0) {
        return $null
    }
    if ($items.Count -ne 1) {
        throw 'The synthetic external source matched more than one reservation.'
    }
    $script:reservationId = [Guid]$items[0].reservationId
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/reservations/properties/$($PropertyId.ToString('D'))/$($reservationId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read proposal lifecycle reservation'
}

function Wait-SmokeReservation {
    param(
        [Parameter(Mandatory = $true)][Guid] $ReceiptId,
        [Parameter(Mandatory = $true)][long] $ExpectedDetailsRevision,
        [Parameter(Mandatory = $true)][string] $ExpectedGuestName,
        [Parameter(Mandatory = $true)][int] $ExpectedOrigin,
        [int] $ExpectedStatus = 2
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $receipt = Get-SmokeReceipt -ReceiptId $ReceiptId
        if (Test-SmokeEnumValue -Value $receipt.status -NumericValue 3 -Name 'rejected') {
            throw "The observation receipt was rejected: $([string]$receipt.rejectionReason)."
        }
        $reservation = Get-SmokeReservationOptional
        if ($null -ne $reservation -and
            (Test-SmokeEnumValue -Value $receipt.status -NumericValue 2 -Name 'processed') -and
            (Test-SmokeEnumValue -Value $reservation.status -NumericValue $ExpectedStatus -Name $(if ($ExpectedStatus -eq 2) { 'confirmed' } else { 'cancelled' })) -and
            [long]$reservation.detailsRevision -eq $ExpectedDetailsRevision -and
            [string]$reservation.primaryGuestName -ceq $ExpectedGuestName -and
            (Test-SmokeEnumValue -Value $reservation.lastDetailsChangeOrigin -NumericValue $ExpectedOrigin -Name $(if ($ExpectedOrigin -eq 1) { 'staff' } else { 'adapter' }))) {
            return $reservation
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "The reservation did not converge to details revision $ExpectedDetailsRevision."
}

function Get-SmokeTargetProposals {
    $matches = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $directory = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/proposals?page=$page&pageSize=100" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List proposal lifecycle proposals'
        foreach ($proposal in @($directory.proposals)) {
            if ($reservationId -ne [Guid]::Empty -and
                [Guid]$proposal.reservationId -eq $reservationId) {
                [void]$matches.Add($proposal)
            }
        }
        $page++
        if ($page -gt 100) {
            throw 'The proposal lifecycle directory exceeded 100 pages.'
        }
    } while ([bool]$directory.hasMore)
    return @($matches)
}

function Get-SmokeProposal {
    param([Parameter(Mandatory = $true)][Guid] $ProposalId)

    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/proposals/$($ProposalId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read proposal lifecycle proposal'
}

function Wait-SmokeProposalSet {
    param(
        [Parameter(Mandatory = $true)][int] $ExpectedCount,
        [Parameter(Mandatory = $true)][int] $ExpectedPendingCount
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $proposals = @(Get-SmokeTargetProposals)
        $pending = @($proposals | Where-Object {
                Test-SmokeEnumValue -Value $_.status -NumericValue 1 -Name 'pending'
            })
        if ($proposals.Count -eq $ExpectedCount -and
            $pending.Count -eq $ExpectedPendingCount) {
            return [pscustomobject]@{
                All = $proposals
                Pending = $pending
            }
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "The proposal set did not converge to $ExpectedCount total and $ExpectedPendingCount pending."
}

function Wait-SmokeProposalStatus {
    param(
        [Parameter(Mandatory = $true)][Guid] $ProposalId,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $ExpectedName
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $proposal = Get-SmokeProposal -ProposalId $ProposalId
        if (Test-SmokeEnumValue -Value $proposal.status -NumericValue $ExpectedStatus -Name $ExpectedName) {
            return $proposal
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "The proposal did not converge to status '$ExpectedName'."
}

function Invoke-RejectProposal {
    param(
        [Parameter(Mandatory = $true)][Guid] $ProposalId,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion,
        [Parameter(Mandatory = $true)][string] $Reason
    )

    return Invoke-SmokeApi `
        -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/proposals/$($ProposalId.ToString('D'))/reject" `
        -Method POST `
        -Body ([ordered]@{
            expectedProposalVersion = $ExpectedVersion
            reason = $Reason
        })
}

function Invoke-AcceptProposal {
    param(
        [Parameter(Mandatory = $true)][Guid] $ProposalId,
        [Parameter(Mandatory = $true)][long] $ExpectedProposalVersion,
        [Parameter(Mandatory = $true)][long] $ExpectedReservationDetailsRevision
    )

    return Invoke-SmokeApi `
        -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/proposals/$($ProposalId.ToString('D'))/accept" `
        -Method POST `
        -Body ([ordered]@{
            expectedProposalVersion = $ExpectedProposalVersion
            expectedReservationDetailsRevision = $ExpectedReservationDetailsRevision
        })
}

function Reject-PendingProposalsForCleanup {
    if (-not $connectionCreateAttempted) {
        return
    }
    if ($reservationId -eq [Guid]::Empty) {
        [void](Get-SmokeReservationOptional)
    }
    if ($reservationId -eq [Guid]::Empty) {
        return
    }
    foreach ($item in @(Get-SmokeTargetProposals)) {
        if (-not (Test-SmokeEnumValue -Value $item.status -NumericValue 1 -Name 'pending')) {
            continue
        }
        $proposal = Get-SmokeProposal -ProposalId ([Guid]$item.proposalId)
        [void](Read-SmokeJson `
                -Response (Invoke-RejectProposal `
                    -ProposalId ([Guid]$proposal.proposalId) `
                    -ExpectedVersion ([long]$proposal.version) `
                    -Reason 'Synthetic proof cleanup') `
                -ExpectedStatus 200 `
                -Operation 'Reject pending synthetic proposal during cleanup')
    }
}

function Cancel-SmokeReservationForCleanup {
    if (-not $connectionCreateAttempted) {
        return
    }
    if ($reservationId -eq [Guid]::Empty) {
        [void](Get-SmokeReservationOptional)
    }
    if ($reservationId -eq [Guid]::Empty) {
        return
    }
    $reservation = Get-SmokeReservationOptional
    if ($null -eq $reservation) {
        return
    }
    if (Test-SmokeEnumValue -Value $reservation.status -NumericValue 5 -Name 'cancelled') {
        $script:reservationCancelled = $true
        return
    }
    if (Test-SmokeEnumValue -Value $reservation.status -NumericValue 4 -Name 'cancellationPending') {
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
        do {
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            $reservation = Get-SmokeReservationOptional
            if (Test-SmokeEnumValue -Value $reservation.status -NumericValue 5 -Name 'cancelled') {
                $script:reservationCancelled = $true
                return
            }
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        throw 'The synthetic reservation cancellation did not converge during cleanup.'
    }

    $receipt = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/reservations/properties/$($PropertyId.ToString('D'))/$($reservationId.ToString('D'))/cancel" `
            -Method POST `
            -Body ([ordered]@{
                operationId = $cleanupCancelOperationId.ToString('D')
                expectedVersion = [long]$reservation.version
            })) `
        -ExpectedStatus 200 `
        -Operation 'Cancel synthetic reservation during cleanup'
    if ([Guid]$receipt.reservationId -ne $reservationId) {
        throw 'Synthetic reservation cleanup returned an invalid receipt.'
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $reservation = Get-SmokeReservationOptional
        if (Test-SmokeEnumValue -Value $reservation.status -NumericValue 5 -Name 'cancelled') {
            $script:reservationCancelled = $true
            return
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'The synthetic reservation did not become cancelled during cleanup.'
}

function Revoke-SmokeCredentialForCleanup {
    if (-not $credentialCreateAttempted) {
        return
    }
    $credential = Get-SmokeCredentialOptional
    if ($null -eq $credential) {
        return
    }
    if (Test-SmokeEnumValue -Value $credential.status -NumericValue 2 -Name 'revoked') {
        $script:credentialRevoked = $true
        $script:finalCredentialVersion = [long]$credential.version
        return
    }
    $receipt = Read-SmokeJson `
        -Response (Invoke-RevokeCredential `
            -OperationId ([Guid]::NewGuid()) `
            -ExpectedVersion ([long]$credential.version)) `
        -ExpectedStatus 200 `
        -Operation 'Revoke proposal lifecycle credential during cleanup'
    if ([Guid]$receipt.credentialId -ne $credentialId -or
        -not (Test-SmokeEnumValue -Value $receipt.status -NumericValue 2 -Name 'revoked')) {
        throw 'Proposal lifecycle credential cleanup returned an invalid receipt.'
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
    $receipt = Read-SmokeJson `
        -Response (Invoke-DisableConnection `
            -OperationId ([Guid]::NewGuid()) `
            -ExpectedVersion ([long]$connection.version)) `
        -ExpectedStatus 200 `
        -Operation 'Disable proposal lifecycle connection during cleanup'
    if ([Guid]$receipt.connectionId -ne $connectionId -or
        -not (Test-SmokeEnumValue -Value $receipt.status -NumericValue 2 -Name 'disabled')) {
        throw 'Proposal lifecycle connection cleanup returned an invalid receipt.'
    }
    $script:connectionDisabled = $true
    $script:finalConnectionVersion = [long]$receipt.version
}

try {
    try {
        $releaseIdBefore = Assert-BunkFyPublicApiReleaseIdentity `
            -Client $client `
            -Origin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -TimeoutSeconds $RequestTimeoutSeconds
        Get-SmokeWorkspaceMembership
        $property = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($PropertyId.ToString('D'))" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read proposal lifecycle property'
        $processing = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($PropertyId.ToString('D'))/processing" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read proposal lifecycle processing state'
        if (-not (Test-SmokeEnumValue -Value $property.status -NumericValue 1 -Name 'active') -or
            -not (Test-SmokeEnumValue -Value $processing.effectiveStatus -NumericValue 2 -Name 'enabled')) {
            throw 'The target property must be active with effective processing enabled.'
        }
        $checks.Add([ordered]@{ name = 'scoped-operator-processing-and-inventory-preflight'; status = 'passed' })

        $denied = Invoke-SmokeApi `
            -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/proposals?page=1&pageSize=1" `
            -Method GET `
            -Body $null `
            -Token $deniedToken
        Assert-SmokeStatus `
            -Response $denied `
            -ExpectedStatus 403 `
            -Operation 'Nonmember proposal directory read'
        $checks.Add([ordered]@{ name = 'nonmember-proposal-read-denied'; status = 'passed' })

        $capabilities = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/ingestion/properties/$($PropertyId.ToString('D'))/adapter-types" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List push-capable adapter types'
        $pushCapabilities = @($capabilities.adapterTypes | Where-Object {
                @($_.executionModes | Where-Object {
                        Test-SmokeEnumValue -Value $_ -NumericValue 3 -Name 'push'
                    }).Count -gt 0
            } | Sort-Object -Property adapterType)
        if ($pushCapabilities.Count -lt 1 -or
            [string]::IsNullOrWhiteSpace([string]$pushCapabilities[0].adapterType) -or
            [int]$pushCapabilities[0].protocolVersion -le 0 -or
            [int]$pushCapabilities[0].configurationSchemaVersion -le 0) {
            throw 'The deployment does not expose a valid push-capable adapter type.'
        }
        $selectedCapability = $pushCapabilities[0]
        $checks.Add([ordered]@{ name = 'push-capability-discovered'; status = 'passed' })

        if (-not $PSCmdlet.ShouldProcess(
                "workspace $($WorkspaceId.ToString('D')) property $($PropertyId.ToString('D'))",
                'Exercise and terminally clean a synthetic Ingestion proposal lifecycle')) {
            return
        }

        $connectionCreateAttempted = $true
        $createdConnection = Invoke-CreateConnectionWithConvergence `
            -AdapterType ([string]$selectedCapability.adapterType)
        if ([Guid]$createdConnection.connectionId -ne $connectionId -or
            [long]$createdConnection.version -ne 1 -or
            -not (Test-SmokeEnumValue -Value $createdConnection.status -NumericValue 1 -Name 'enabled')) {
            throw 'The synthetic push connection returned an invalid creation receipt.'
        }
        $credentialCreateAttempted = $true
        $issued = Read-SmokeJson `
            -Response (Invoke-CreateCredential) `
            -ExpectedStatus 200 `
            -Operation 'Issue proposal lifecycle ingress credential'
        if (-not (Test-SmokeEnumValue -Value $issued.outcome -NumericValue 1 -Name 'issued') -or
            [Guid]$issued.credential.credentialId -ne $credentialId -or
            [string]::IsNullOrWhiteSpace([string]$issued.token)) {
            throw 'The proposal lifecycle ingress credential was not issued once.'
        }
        $adapterToken = [string]$issued.token
        $checks.Add([ordered]@{ name = 'push-connection-and-credential-created'; status = 'passed' })

        $jwtIngress = Invoke-SmokeApi `
            -Path "/api/ingestion/adapter-ingress/connections/$($connectionId.ToString('D'))/observations" `
            -Method POST `
            -Body ([ordered]@{ records = @() })
        Assert-SmokeStatus `
            -Response $jwtIngress `
            -ExpectedStatus 401 `
            -Operation 'Member JWT substitution at adapter ingress'
        $checks.Add([ordered]@{ name = 'adapter-ingress-requires-independent-authentication'; status = 'passed' })

        $initialObservation = New-SmokeObservation `
            -Sequence 1 `
            -OperationId ([Guid]::NewGuid()) `
            -Kind upsert `
            -GuestName $guestNames.Initial
        $initialAck = Submit-SmokeObservation `
            -Observation $initialObservation `
            -ExpectedDisposition 1 `
            -Operation 'Submit initial reservation observation'
        $initialReceiptId = [Guid]$initialAck.receiptId
        $initialReservation = Wait-SmokeReservation `
            -ReceiptId $initialReceiptId `
            -ExpectedDetailsRevision 1 `
            -ExpectedGuestName $guestNames.Initial `
            -ExpectedOrigin 2
        $initialDetailsRevision = [long]$initialReservation.detailsRevision
        $checks.Add([ordered]@{ name = 'initial-observation-auto-created-reservation'; status = 'passed' })

        $duplicateAck = Submit-SmokeObservation `
            -Observation $initialObservation `
            -ExpectedDisposition 2 `
            -Operation 'Replay initial reservation observation'
        if ([Guid]$duplicateAck.receiptId -ne $initialReceiptId) {
            throw 'The exact adapter observation replay did not return the original receipt.'
        }
        $checks.Add([ordered]@{ name = 'observation-replay-is-stable'; status = 'passed' })

        $automaticObservation = New-SmokeObservation `
            -Sequence 2 `
            -OperationId ([Guid]::NewGuid()) `
            -Kind upsert `
            -GuestName $guestNames.Automatic
        $automaticAck = Submit-SmokeObservation `
            -Observation $automaticObservation `
            -ExpectedDisposition 1 `
            -Operation 'Submit baseline-current adapter update'
        $automaticReservation = Wait-SmokeReservation `
            -ReceiptId ([Guid]$automaticAck.receiptId) `
            -ExpectedDetailsRevision 2 `
            -ExpectedGuestName $guestNames.Automatic `
            -ExpectedOrigin 2
        $automaticDetailsRevision = [long]$automaticReservation.detailsRevision
        if (@(Get-SmokeTargetProposals).Count -ne 0) {
            throw 'A baseline-current adapter update unexpectedly created a proposal.'
        }
        $checks.Add([ordered]@{ name = 'baseline-current-update-auto-applied'; status = 'passed' })

        $staffReceipt = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/reservations/properties/$($PropertyId.ToString('D'))/$($reservationId.ToString('D'))/guest-details" `
                -Method PUT `
                -Body ([ordered]@{
                    operationId = $staffEditOperationId.ToString('D')
                    primaryGuestName = $guestNames.Staff
                    email = $null
                    phone = $null
                    guestCount = 1
                    notes = 'Synthetic staff authority marker'
                    expectedArrivalTime = '15:00:00'
                    expectedDepartureTime = '11:00:00'
                    expectedDetailsRevision = [long]$automaticReservation.detailsRevision
                })) `
            -ExpectedStatus 200 `
            -Operation 'Apply synthetic staff reservation edit'
        $staffReservation = Get-SmokeReservationOptional
        if ([Guid]$staffReceipt.reservationId -ne $reservationId -or
            [long]$staffReceipt.detailsRevision -ne 3 -or
            [long]$staffReservation.detailsRevision -ne 3 -or
            [string]$staffReservation.primaryGuestName -cne $guestNames.Staff -or
            -not (Test-SmokeEnumValue -Value $staffReservation.lastDetailsChangeOrigin -NumericValue 1 -Name 'staff')) {
            throw 'The synthetic staff edit did not establish staff authority.'
        }
        $staffDetailsRevision = [long]$staffReservation.detailsRevision
        $checks.Add([ordered]@{ name = 'staff-edit-established-new-authority'; status = 'passed' })

        $firstConflictObservation = New-SmokeObservation `
            -Sequence 3 `
            -OperationId ([Guid]::NewGuid()) `
            -Kind upsert `
            -GuestName $guestNames.FirstProposal
        $firstConflictAck = Submit-SmokeObservation `
            -Observation $firstConflictObservation `
            -ExpectedDisposition 1 `
            -Operation 'Submit first staff-conflicting adapter update'
        $firstSet = Wait-SmokeProposalSet -ExpectedCount 1 -ExpectedPendingCount 1
        $firstProposalId = [Guid]$firstSet.Pending[0].proposalId
        $firstProposal = Get-SmokeProposal -ProposalId $firstProposalId
        $preserved = Get-SmokeReservationOptional
        $firstReceipt = Get-SmokeReceipt -ReceiptId ([Guid]$firstConflictAck.receiptId)
        if ([Guid]$firstProposal.receiptId -ne [Guid]$firstConflictAck.receiptId -or
            [long]$firstProposal.baseReservationDetailsRevision -ne 2 -or
            [string]$firstProposal.reasonCode -cne 'reservation-details-revision-conflict' -or
            -not (Test-SmokeEnumValue -Value $firstReceipt.status -NumericValue 2 -Name 'processed') -or
            [long]$preserved.detailsRevision -ne 3 -or
            [string]$preserved.primaryGuestName -cne $guestNames.Staff) {
            throw 'The first adapter conflict did not preserve staff authority and create a proposal.'
        }
        $checks.Add([ordered]@{ name = 'staff-conflict-created-pending-proposal'; status = 'passed' })
        $checks.Add([ordered]@{ name = 'pending-proposal-did-not-overwrite-staff-state'; status = 'passed' })

        $secondConflictObservation = New-SmokeObservation `
            -Sequence 4 `
            -OperationId ([Guid]::NewGuid()) `
            -Kind upsert `
            -GuestName $guestNames.RejectedProposal
        $secondConflictAck = Submit-SmokeObservation `
            -Observation $secondConflictObservation `
            -ExpectedDisposition 1 `
            -Operation 'Submit newer staff-conflicting adapter update'
        $secondSet = Wait-SmokeProposalSet -ExpectedCount 2 -ExpectedPendingCount 1
        $rejectedProposalId = [Guid]$secondSet.Pending[0].proposalId
        $superseded = Wait-SmokeProposalStatus `
            -ProposalId $firstProposalId `
            -ExpectedStatus 5 `
            -ExpectedName superseded
        $newest = Get-SmokeProposal -ProposalId $rejectedProposalId
        if ([Guid]$newest.receiptId -ne [Guid]$secondConflictAck.receiptId -or
            [string]$superseded.decisionActor -cne 'system' -or
            [string]::IsNullOrWhiteSpace([string]$superseded.decisionReason) -or
            $null -eq $superseded.sensitiveDataRetainUntilUtc) {
            throw 'The newer proposal did not terminally supersede the older suggestion.'
        }
        $checks.Add([ordered]@{ name = 'newer-source-proposal-superseded-older-pending'; status = 'passed' })
        $checks.Add([ordered]@{ name = 'only-newest-proposal-remains-actionable'; status = 'passed' })

        $supersededDecision = Invoke-AcceptProposal `
            -ProposalId $firstProposalId `
            -ExpectedProposalVersion ([long]$superseded.version) `
            -ExpectedReservationDetailsRevision $staffDetailsRevision
        Assert-SmokeProblem `
            -Response $supersededDecision `
            -ExpectedStatus 409 `
            -ExpectedCode 'Ingestion.ProposalDecisionConflict' `
            -Operation 'Decide superseded proposal'
        $checks.Add([ordered]@{ name = 'superseded-proposal-decision-rejected'; status = 'passed' })

        $rejectReason = 'Synthetic source update rejected as obsolete'
        $rejected = Read-SmokeJson `
            -Response (Invoke-RejectProposal `
                -ProposalId $rejectedProposalId `
                -ExpectedVersion ([long]$newest.version) `
                -Reason $rejectReason) `
            -ExpectedStatus 200 `
            -Operation 'Reject newest synthetic proposal'
        if ([Guid]$rejected.proposalId -ne $rejectedProposalId -or
            -not (Test-SmokeEnumValue -Value $rejected.status -NumericValue 4 -Name 'rejected')) {
            throw 'The newest synthetic proposal was not rejected.'
        }
        $checks.Add([ordered]@{ name = 'newest-proposal-rejected-with-audit-reason'; status = 'passed' })

        $rejectReplay = Read-SmokeJson `
            -Response (Invoke-RejectProposal `
                -ProposalId $rejectedProposalId `
                -ExpectedVersion ([long]$newest.version) `
                -Reason $rejectReason) `
            -ExpectedStatus 200 `
            -Operation 'Replay newest proposal rejection'
        if ([Guid]$rejectReplay.proposalId -ne $rejectedProposalId -or
            [long]$rejectReplay.version -ne [long]$rejected.version -or
            [string]$rejectReplay.status -cne [string]$rejected.status) {
            throw 'The exact proposal rejection replay was not stable.'
        }
        $rejectConflict = Invoke-RejectProposal `
            -ProposalId $rejectedProposalId `
            -ExpectedVersion ([long]$newest.version) `
            -Reason 'Changed synthetic rejection reason'
        Assert-SmokeProblem `
            -Response $rejectConflict `
            -ExpectedStatus 409 `
            -ExpectedCode 'Ingestion.ProposalDecisionConflict' `
            -Operation 'Conflicting proposal rejection replay'
        $checks.Add([ordered]@{ name = 'proposal-rejection-replay-and-conflict-safe'; status = 'passed' })

        $acceptedObservation = New-SmokeObservation `
            -Sequence 5 `
            -OperationId ([Guid]::NewGuid()) `
            -Kind upsert `
            -GuestName $guestNames.AcceptedProposal
        $acceptedAck = Submit-SmokeObservation `
            -Observation $acceptedObservation `
            -ExpectedDisposition 1 `
            -Operation 'Submit proposal selected for acceptance'
        $thirdSet = Wait-SmokeProposalSet -ExpectedCount 3 -ExpectedPendingCount 1
        $acceptedProposalId = [Guid]$thirdSet.Pending[0].proposalId
        $acceptedProposal = Get-SmokeProposal -ProposalId $acceptedProposalId
        if ([Guid]$acceptedProposal.receiptId -ne [Guid]$acceptedAck.receiptId) {
            throw 'The acceptance candidate does not match the newest source receipt.'
        }
        $checks.Add([ordered]@{ name = 'later-source-update-created-fresh-proposal'; status = 'passed' })

        $acceptRequestVersion = [long]$acceptedProposal.version
        $acceptStarted = Read-SmokeJson `
            -Response (Invoke-AcceptProposal `
                -ProposalId $acceptedProposalId `
                -ExpectedProposalVersion $acceptRequestVersion `
                -ExpectedReservationDetailsRevision $staffDetailsRevision) `
            -ExpectedStatus 200 `
            -Operation 'Accept latest synthetic proposal'
        if ([Guid]$acceptStarted.proposalId -ne $acceptedProposalId -or
            -not (Test-SmokeEnumValue -Value $acceptStarted.status -NumericValue 2 -Name 'applying') -or
            $null -eq $acceptStarted.productOperationId) {
            throw 'The latest synthetic proposal did not begin applying.'
        }
        $checks.Add([ordered]@{ name = 'proposal-acceptance-started-versioned-operation'; status = 'passed' })

        $acceptedTerminal = Wait-SmokeProposalStatus `
            -ProposalId $acceptedProposalId `
            -ExpectedStatus 3 `
            -ExpectedName applied
        $acceptedReservation = Wait-SmokeReservation `
            -ReceiptId ([Guid]$acceptedAck.receiptId) `
            -ExpectedDetailsRevision 4 `
            -ExpectedGuestName $guestNames.AcceptedProposal `
            -ExpectedOrigin 2
        $acceptedDetailsRevision = [long]$acceptedReservation.detailsRevision
        if ([Guid]$acceptedTerminal.productOperationId -ne [Guid]$acceptStarted.productOperationId) {
            throw 'The applied proposal changed product operation identity.'
        }
        $checks.Add([ordered]@{ name = 'accepted-proposal-converged-in-reservations'; status = 'passed' })

        $acceptReplay = Read-SmokeJson `
            -Response (Invoke-AcceptProposal `
                -ProposalId $acceptedProposalId `
                -ExpectedProposalVersion $acceptRequestVersion `
                -ExpectedReservationDetailsRevision $staffDetailsRevision) `
            -ExpectedStatus 200 `
            -Operation 'Replay accepted proposal decision'
        if ([Guid]$acceptReplay.productOperationId -ne [Guid]$acceptStarted.productOperationId -or
            -not (Test-SmokeEnumValue -Value $acceptReplay.status -NumericValue 3 -Name 'applied')) {
            throw 'The exact accepted-proposal replay did not preserve the applied operation.'
        }
        $acceptConflict = Invoke-AcceptProposal `
            -ProposalId $acceptedProposalId `
            -ExpectedProposalVersion $acceptRequestVersion `
            -ExpectedReservationDetailsRevision $acceptedDetailsRevision
        Assert-SmokeProblem `
            -Response $acceptConflict `
            -ExpectedStatus 409 `
            -ExpectedCode 'Ingestion.ProposalDecisionConflict' `
            -Operation 'Conflicting accepted-proposal replay'
        $checks.Add([ordered]@{ name = 'proposal-acceptance-replay-and-conflict-safe'; status = 'passed' })

        $staleObservation = New-SmokeObservation `
            -Sequence 0 `
            -OperationId ([Guid]::NewGuid()) `
            -Kind upsert `
            -GuestName $guestNames.RejectedProposal
        $staleAck = Submit-SmokeObservation `
            -Observation $staleObservation `
            -ExpectedDisposition 1 `
            -Operation 'Submit stale ordered source observation'
        $staleReceiptId = [Guid]$staleAck.receiptId
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
        do {
            $staleReceipt = Get-SmokeReceipt -ReceiptId $staleReceiptId
            if (Test-SmokeEnumValue -Value $staleReceipt.status -NumericValue 2 -Name 'processed') {
                break
            }
            if (Test-SmokeEnumValue -Value $staleReceipt.status -NumericValue 3 -Name 'rejected') {
                throw 'The stale observation was rejected instead of terminally classified.'
            }
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        if (-not (Test-SmokeEnumValue -Value $staleReceipt.status -NumericValue 2 -Name 'processed') -or
            @(Get-SmokeTargetProposals).Count -ne 3) {
            throw 'Stale source input created additional proposal work.'
        }
        $unchangedAfterStale = Get-SmokeReservationOptional
        if ([long]$unchangedAfterStale.detailsRevision -ne $acceptedDetailsRevision -or
            [string]$unchangedAfterStale.primaryGuestName -cne $guestNames.AcceptedProposal) {
            throw 'Stale source input changed the reservation.'
        }
        $checks.Add([ordered]@{ name = 'stale-source-input-created-no-actionable-work'; status = 'passed' })

        $history = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/reservations/properties/$($PropertyId.ToString('D'))/$($reservationId.ToString('D'))/details-history?page=1&pageSize=100" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read proposal lifecycle reservation history'
        $historyItems = @($history.items | Sort-Object -Property toRevision)
        $expectedRevisions = @(1L, 2L, 3L, 4L)
        $actualRevisions = @($historyItems | ForEach-Object { [long]$_.toRevision })
        $adapterOrigins = @($historyItems | Where-Object {
                Test-SmokeEnumValue -Value $_.origin -NumericValue 2 -Name 'adapter'
            })
        $staffOrigins = @($historyItems | Where-Object {
                Test-SmokeEnumValue -Value $_.origin -NumericValue 1 -Name 'staff'
            })
        if ($historyItems.Count -ne 4 -or
            [string]::Join(',', $actualRevisions) -cne [string]::Join(',', $expectedRevisions) -or
            $adapterOrigins.Count -ne 3 -or
            $staffOrigins.Count -ne 1) {
            throw 'Reservations history does not preserve adapter and staff provenance across the proposal lifecycle.'
        }
        $checks.Add([ordered]@{ name = 'reservation-history-preserved-authority-provenance'; status = 'passed' })

        $cancelObservation = New-SmokeObservation `
            -Sequence 6 `
            -OperationId ([Guid]::NewGuid()) `
            -Kind cancel `
            -GuestName $null
        $cancelAck = Submit-SmokeObservation `
            -Observation $cancelObservation `
            -ExpectedDisposition 1 `
            -Operation 'Submit terminal adapter cancellation'
        $cancelled = Wait-SmokeReservation `
            -ReceiptId ([Guid]$cancelAck.receiptId) `
            -ExpectedDetailsRevision $acceptedDetailsRevision `
            -ExpectedGuestName $guestNames.AcceptedProposal `
            -ExpectedOrigin 2 `
            -ExpectedStatus 5
        $reservationCancelled = $true
        $checks.Add([ordered]@{ name = 'adapter-cancellation-completed-terminally'; status = 'passed' })

        $credential = Get-SmokeCredentialOptional
        $revoked = Read-SmokeJson `
            -Response (Invoke-RevokeCredential `
                -OperationId $revokeCredentialOperationId `
                -ExpectedVersion ([long]$credential.version)) `
            -ExpectedStatus 200 `
            -Operation 'Revoke proposal lifecycle credential'
        if (-not (Test-SmokeEnumValue -Value $revoked.status -NumericValue 2 -Name 'revoked')) {
            throw 'The proposal lifecycle credential did not become revoked.'
        }
        $credentialRevoked = $true
        $finalCredentialVersion = [long]$revoked.version
        $connection = Get-SmokeConnectionOptional
        $disabled = Read-SmokeJson `
            -Response (Invoke-DisableConnection `
                -OperationId $disableConnectionOperationId `
                -ExpectedVersion ([long]$connection.version)) `
            -ExpectedStatus 200 `
            -Operation 'Disable proposal lifecycle connection'
        if (-not (Test-SmokeEnumValue -Value $disabled.status -NumericValue 2 -Name 'disabled')) {
            throw 'The proposal lifecycle connection did not become disabled.'
        }
        $connectionDisabled = $true
        $finalConnectionVersion = [long]$disabled.version
        $checks.Add([ordered]@{ name = 'credential-revoked-and-connection-disabled'; status = 'passed' })

        $releaseIdAfter = Assert-BunkFyPublicApiReleaseIdentity `
            -Client $client `
            -Origin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -TimeoutSeconds $RequestTimeoutSeconds
        if ($releaseIdBefore -cne $releaseIdAfter) {
            throw 'The release identity changed during the Ingestion proposal lifecycle.'
        }
        $observedReleaseId = $releaseIdAfter
        $checks.Add([ordered]@{ name = 'release-identity-continuous'; status = 'passed' })
    }
    catch {
        $workflowError = $_
    }
    finally {
        foreach ($cleanup in @(
                [pscustomobject]@{ Name = 'pending-proposals'; Action = { Reject-PendingProposalsForCleanup } },
                [pscustomobject]@{ Name = 'reservation'; Action = { Cancel-SmokeReservationForCleanup } },
                [pscustomobject]@{ Name = 'credential'; Action = { Revoke-SmokeCredentialForCleanup } },
                [pscustomobject]@{ Name = 'connection'; Action = { Disable-SmokeConnectionForCleanup } })) {
            try {
                & $cleanup.Action
            }
            catch {
                $cleanupErrors.Add("$($cleanup.Name):$($_.Exception.GetType().Name)")
            }
        }
        $adapterToken = $null
    }

    if ($null -ne $workflowError) {
        if ($cleanupErrors.Count -gt 0) {
            throw [AggregateException]::new(
                'The Ingestion proposal lifecycle failed and cleanup was incomplete.',
                @($workflowError.Exception) + @($cleanupErrors | ForEach-Object { [InvalidOperationException]::new($_) }))
        }
        throw $workflowError
    }
    if ($cleanupErrors.Count -gt 0) {
        throw "The Ingestion proposal lifecycle passed but cleanup failed: $([string]::Join(', ', $cleanupErrors))."
    }
    if (-not $reservationCancelled -or
        -not $credentialRevoked -or
        -not $connectionDisabled) {
        throw 'The Ingestion proposal lifecycle did not reach its required terminal cleanup state.'
    }

    $finalProposals = @(Get-SmokeTargetProposals)
    $pendingFinal = @($finalProposals | Where-Object {
            Test-SmokeEnumValue -Value $_.status -NumericValue 1 -Name 'pending'
        })
    if ($finalProposals.Count -ne 3 -or $pendingFinal.Count -ne 0) {
        throw 'The terminal proposal projection is not consistent.'
    }
    $checks.Add([ordered]@{ name = 'terminal-proposal-projection-consistent'; status = 'passed' })

    $evidence = [ordered]@{
        schemaVersion = 1
        evidenceKind = 'bunkfy-deployed-ingestion-conflict-proposal-lifecycle-probe'
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        origin = $origin.GetLeftPart([UriPartial]::Authority)
        releaseId = $observedReleaseId
        transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-preview' }
        result = 'passed'
        adapterContract = [ordered]@{
            executionMode = 'push'
            protocolVersion = [int]$selectedCapability.protocolVersion
            configurationSchemaVersion = [int]$selectedCapability.configurationSchemaVersion
        }
        authorityRevisions = [ordered]@{
            initialAdapter = $initialDetailsRevision
            automaticAdapter = $automaticDetailsRevision
            staff = $staffDetailsRevision
            acceptedAdapter = $acceptedDetailsRevision
        }
        proposalSummary = [ordered]@{
            total = $finalProposals.Count
            superseded = @($finalProposals | Where-Object {
                    Test-SmokeEnumValue -Value $_.status -NumericValue 5 -Name 'superseded'
                }).Count
            rejected = @($finalProposals | Where-Object {
                    Test-SmokeEnumValue -Value $_.status -NumericValue 4 -Name 'rejected'
                }).Count
            applied = @($finalProposals | Where-Object {
                    Test-SmokeEnumValue -Value $_.status -NumericValue 3 -Name 'applied'
                }).Count
            pending = $pendingFinal.Count
        }
        cleanup = [ordered]@{
            reservation = 'cancelled'
            credential = 'revoked'
            connection = 'disabled'
            credentialVersion = $finalCredentialVersion
            connectionVersion = $finalConnectionVersion
        }
        checks = @($checks)
        limitations = @(
            'synthetic-reservation-data-only',
            'loopback-preview-is-not-hosted-production-proof',
            'provider-acquisition-and-parser-correctness-not-exercised',
            'proposal-acceptance-race-to-stale-covered-by-focused-integration-tests',
            'production-country-policy-and-provider-credential-approval-not-exercised'
        )
    }

    $outputDirectory = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
    }
    Write-BunkFyPrivateJsonEvidence `
        -Path $OutputPath `
        -Value $evidence `
        -Depth 12 `
        -Overwrite:$Force `
        -Description 'Ingestion conflict and proposal lifecycle evidence'
    Write-Host "BunkFy deployed Ingestion conflict and proposal lifecycle passed $($checks.Count) checks."
    Write-Host "Evidence: $OutputPath"
}
finally {
    $operatorToken = $null
    $deniedToken = $null
    $client.Dispose()
}
