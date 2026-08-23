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
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [ValidateRange(10, 300)][int] $ConvergenceTimeoutSeconds = 90,
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
foreach ($identifier in @(
        [pscustomobject]@{ Name = 'WorkspaceId'; Value = $WorkspaceId },
        [pscustomobject]@{ Name = 'PropertyId'; Value = $PropertyId },
        [pscustomobject]@{ Name = 'InventoryUnitId'; Value = $InventoryUnitId })) {
    if ($identifier.Value -eq [Guid]::Empty) {
        throw "$($identifier.Name) must not be an empty GUID."
    }
}

$arrivalDate = $Arrival.Date
$departureDate = $Departure.Date
if ($arrivalDate -ge $departureDate) {
    throw 'Arrival must be before Departure.'
}
if (($departureDate - $arrivalDate).TotalDays -gt 30) {
    throw 'The verification stay must not exceed 30 nights.'
}
$arrivalText = $arrivalDate.ToString(
    'yyyy-MM-dd',
    [Globalization.CultureInfo]::InvariantCulture)
$departureText = $departureDate.ToString(
    'yyyy-MM-dd',
    [Globalization.CultureInfo]::InvariantCulture)

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/reservations-inventory-$stamp.json"
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

$operatorToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $OperatorAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_RESERVATION_OPERATOR_TOKEN' `
    -Prompt 'Reservation lifecycle operator access token'
if ([string]::IsNullOrWhiteSpace($operatorToken)) {
    throw 'The Reservation lifecycle operator access token is required.'
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
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Deployed-Reservations-Inventory-Probe/1')

$checks = [Collections.Generic.List[object]]::new()
$deniedWorkspaceId = [Guid]::NewGuid()
$operationId = [Guid]::NewGuid()
$checkInOperationId = [Guid]::NewGuid()
$checkOutOperationId = [Guid]::NewGuid()
$reservationId = $operationId
$reservationCreated = $false
$observedReleaseId = $null
$guestLabel = 'BunkFy deployment verification'

function Invoke-SmokeApi {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string] $Method,
        [AllowNull()][object] $Body
    )

    return Invoke-BunkFyAuthenticatedJsonRequest `
        -Client $client `
        -Origin $origin `
        -Path $Path `
        -Method $Method `
        -TenantId $WorkspaceId.ToString('D') `
        -AccessToken $operatorToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body $Body
}

function Read-SmokeJson {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    return ConvertFrom-BunkFyAuthenticatedJsonResponse `
        -Response $Response `
        -ExpectedStatus $ExpectedStatus `
        -Operation $Operation
}

function Get-SmokeWorkspaceMembership {
    $matches = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $response = Read-SmokeJson `
            -Response (Invoke-BunkFyAuthenticatedJsonRequest `
                -Client $client `
                -Origin $origin `
                -Path "/api/organizations?page=$page&pageSize=100" `
                -Method GET `
                -TenantId 'global' `
                -AccessToken $operatorToken `
                -TimeoutSeconds $RequestTimeoutSeconds `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List operator workspaces'
        foreach ($item in @($response.items)) {
            if ([Guid]$item.organization.organizationId -eq $WorkspaceId) {
                [void]$matches.Add($item.membership)
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

    return $matches[0]
}

function Get-SmokeAvailabilityUnit {
    $response = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/inventory/properties/$($PropertyId.ToString('D'))/availability?arrival=$arrivalText&departure=$departureText" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read Inventory availability'
    if ([Guid]$response.propertyId -ne $PropertyId -or
        [string]$response.arrival -cne $arrivalText -or
        [string]$response.departure -cne $departureText) {
        throw 'Inventory availability returned a different property or stay range.'
    }

    $matches = @($response.units | Where-Object {
            [Guid]$_.unit.inventoryUnitId -eq $InventoryUnitId
        })
    if ($matches.Count -ne 1) {
        throw 'The selected Inventory unit was not unique in availability.'
    }
    return $matches[0]
}

function Get-SmokeReservation {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/reservations/properties/$($PropertyId.ToString('D'))/$($reservationId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read Reservation lifecycle state'
}

function Wait-SmokeReservationStatus {
    param(
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][int[]] $AllowedStatuses,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $reservation = Get-SmokeReservation
        if ([Guid]$reservation.reservationId -ne $reservationId -or
            [Guid]$reservation.propertyId -ne $PropertyId) {
            throw "$Operation returned a different Reservation coordinate."
        }
        $status = [int]$reservation.status
        if ($status -eq $ExpectedStatus) {
            return $reservation
        }
        if ($status -notin $AllowedStatuses) {
            throw "$Operation entered unexpected Reservation status '$status'."
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "$Operation did not converge within $ConvergenceTimeoutSeconds seconds."
}

function Invoke-SmokeReservationCreate {
    $body = [ordered]@{
        operationId = $operationId.ToString('D')
        arrival = $arrivalText
        departure = $departureText
        expectedArrivalTime = $null
        expectedDepartureTime = $null
        inventoryUnitIds = @($InventoryUnitId.ToString('D'))
        primaryGuestName = $guestLabel
        email = $null
        phone = $null
        guestCount = 1
        sourceKind = 1
        sourceSystem = $null
        sourceReference = $null
        notes = $null
    }
    return Invoke-BunkFyAuthenticatedJsonRequestWithConvergence `
        -Client $client `
        -Origin $origin `
        -Path "/api/reservations/properties/$($PropertyId.ToString('D'))" `
        -Method POST `
        -TenantId $WorkspaceId.ToString('D') `
        -AccessToken $operatorToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body $body `
        -ExpectedStatus 200 `
        -Operation 'Create Reservation' `
        -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
        -PollIntervalMilliseconds $PollIntervalMilliseconds `
        -RetryableProblemCodes @('Reservations.CountryPolicyDenied.MissingBinding')
}

function Invoke-SmokeLifecycleMutation {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('cancel', 'check-in', 'check-out')][string] $Action,
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion
    )

    $body = if ($Action -ceq 'cancel') {
        [ordered]@{
            operationId = $OperationId.ToString('D')
            expectedVersion = $ExpectedVersion
        }
    }
    else {
        [ordered]@{
            operationId = $OperationId.ToString('D')
            businessDate = $arrivalText
            expectedVersion = $ExpectedVersion
        }
    }
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/reservations/properties/$($PropertyId.ToString('D'))/$($reservationId.ToString('D'))/$Action" `
            -Method POST `
            -Body $body) `
        -ExpectedStatus 200 `
        -Operation "Reservation $Action"
}

function Complete-SmokeReservationBestEffort {
    if (-not $reservationCreated) {
        return
    }

    try {
        $reservation = Get-SmokeReservation
        switch ([int]$reservation.status) {
            { $_ -in @(1, 2) } {
                [void](Invoke-SmokeLifecycleMutation `
                        -Action cancel `
                        -OperationId ([Guid]::NewGuid()) `
                        -ExpectedVersion ([long]$reservation.version))
                [void](Wait-SmokeReservationStatus `
                        -ExpectedStatus 5 `
                        -AllowedStatuses @(4, 5) `
                        -Operation 'Reservation cleanup cancellation')
                break
            }
            4 {
                [void](Wait-SmokeReservationStatus `
                        -ExpectedStatus 5 `
                        -AllowedStatuses @(4, 5) `
                        -Operation 'Reservation cleanup cancellation')
                break
            }
            6 {
                [void](Invoke-SmokeLifecycleMutation `
                        -Action check-out `
                        -OperationId ([Guid]::NewGuid()) `
                        -ExpectedVersion ([long]$reservation.version))
                [void](Wait-SmokeReservationStatus `
                        -ExpectedStatus 10 `
                        -AllowedStatuses @(9, 10) `
                        -Operation 'Reservation cleanup checkout')
                break
            }
            9 {
                [void](Wait-SmokeReservationStatus `
                        -ExpectedStatus 10 `
                        -AllowedStatuses @(9, 10) `
                        -Operation 'Reservation cleanup checkout')
                break
            }
        }
    }
    catch {
        Write-Warning "Reservation lifecycle cleanup did not converge: $($_.Exception.Message)"
    }
}

try {
    $releaseIdBefore = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -ObservedAdmissionEvidenceReference ([ref]$observedAdmissionEvidenceReference)

    $crossWorkspaceAvailability = Invoke-BunkFyAuthenticatedJsonRequest `
        -Client $client `
        -Origin $origin `
        -Path "/api/inventory/properties/$($PropertyId.ToString('D'))/availability?arrival=$arrivalText&departure=$departureText" `
        -Method GET `
        -TenantId $deniedWorkspaceId.ToString('D') `
        -AccessToken $operatorToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body $null
    Assert-BunkFyAuthenticatedStatus `
        -Response $crossWorkspaceAvailability `
        -ExpectedStatus 403 `
        -Operation 'Cross-workspace Inventory availability read'
    $checks.Add([ordered]@{ name = 'cross-workspace-inventory-read-denied'; status = 'passed' })

    [void](Get-SmokeWorkspaceMembership)
    $property = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/properties/$($PropertyId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read smoke property'
    if ([Guid]$property.propertyId -ne $PropertyId) {
        throw 'The property preflight returned a different property.'
    }
    $checks.Add([ordered]@{ name = 'scoped-operator-and-property-preflight'; status = 'passed' })

    $availableBefore = Get-SmokeAvailabilityUnit
    if (-not ([bool]$availableBefore.isAvailable) -or
        @($availableBefore.activeAllocationIds).Count -ne 0) {
        throw "The selected Inventory unit is not available before creation (available=$([bool]$availableBefore.isAvailable), activeAllocations=$(@($availableBefore.activeAllocationIds).Count))."
    }
    $checks.Add([ordered]@{ name = 'inventory-available-before-create'; status = 'passed' })

    if (-not $PSCmdlet.ShouldProcess(
            "property $($PropertyId.ToString('D'))",
            'Create, check in, and check out a synthetic Reservation')) {
        return
    }

    $reservationCreated = $true
    $created = Invoke-SmokeReservationCreate
    if ([Guid]$created.reservationId -ne $reservationId -or
        [Guid]$created.propertyId -ne $PropertyId -or
        [int]$created.status -notin @(1, 2)) {
        throw 'Reservation creation returned an unexpected receipt.'
    }

    $confirmed = Wait-SmokeReservationStatus `
        -ExpectedStatus 2 `
        -AllowedStatuses @(1, 2) `
        -Operation 'Reservation allocation'
    $checks.Add([ordered]@{ name = 'reservation-allocation-confirmed'; status = 'passed' })

    $replayed = Invoke-SmokeReservationCreate
    if ([Guid]$replayed.reservationId -ne $reservationId -or
        [Guid]$replayed.propertyId -ne $PropertyId -or
        [int]$replayed.status -ne 2 -or
        [long]$replayed.version -ne [long]$confirmed.version -or
        [long]$replayed.detailsRevision -ne [long]$confirmed.detailsRevision) {
        throw 'The exact Reservation create replay did not return the current stable receipt.'
    }
    $checks.Add([ordered]@{ name = 'reservation-create-replay-stable'; status = 'passed' })

    $allocated = Get-SmokeAvailabilityUnit
    if ([bool]$allocated.isAvailable -or
        @($allocated.activeAllocationIds).Count -ne 1) {
        throw 'The confirmed Reservation did not make the selected Inventory unit unavailable.'
    }
    $checks.Add([ordered]@{ name = 'allocated-inventory-unavailable'; status = 'passed' })

    $checkedIn = Invoke-SmokeLifecycleMutation `
        -Action check-in `
        -OperationId $checkInOperationId `
        -ExpectedVersion ([long]$confirmed.version)
    if ([Guid]$checkedIn.reservationId -ne $reservationId -or
        [int]$checkedIn.status -ne 6) {
        throw 'Reservation check-in was not recorded synchronously.'
    }
    $checks.Add([ordered]@{ name = 'reservation-check-in-recorded'; status = 'passed' })

    $checkInReplay = Invoke-SmokeLifecycleMutation `
        -Action check-in `
        -OperationId $checkInOperationId `
        -ExpectedVersion ([long]$confirmed.version)
    if ([Guid]$checkInReplay.reservationId -ne $reservationId -or
        [int]$checkInReplay.status -ne 6 -or
        [long]$checkInReplay.version -ne [long]$checkedIn.version -or
        [long]$checkInReplay.detailsRevision -ne [long]$checkedIn.detailsRevision) {
        throw 'The exact Reservation check-in replay did not return the current stable receipt.'
    }
    $checks.Add([ordered]@{ name = 'reservation-check-in-replay-stable'; status = 'passed' })

    $checkoutRequested = Invoke-SmokeLifecycleMutation `
        -Action check-out `
        -OperationId $checkOutOperationId `
        -ExpectedVersion ([long]$checkedIn.version)
    if ([Guid]$checkoutRequested.reservationId -ne $reservationId -or
        [int]$checkoutRequested.status -notin @(9, 10)) {
        throw 'Reservation checkout returned an unexpected receipt.'
    }
    $checkedOut = if ([int]$checkoutRequested.status -eq 10) {
        Get-SmokeReservation
    }
    else {
        Wait-SmokeReservationStatus `
            -ExpectedStatus 10 `
            -AllowedStatuses @(9, 10) `
            -Operation 'Reservation checkout'
    }
    if ([int]$checkedOut.status -ne 10) {
        throw 'Reservation checkout did not converge to CheckedOut.'
    }
    $checks.Add([ordered]@{ name = 'reservation-checkout-converged'; status = 'passed' })

    $checkOutReplay = Invoke-SmokeLifecycleMutation `
        -Action check-out `
        -OperationId $checkOutOperationId `
        -ExpectedVersion ([long]$checkedIn.version)
    if ([Guid]$checkOutReplay.reservationId -ne $reservationId -or
        [int]$checkOutReplay.status -ne 10 -or
        [long]$checkOutReplay.version -ne [long]$checkedOut.version -or
        [long]$checkOutReplay.detailsRevision -ne [long]$checkedOut.detailsRevision) {
        throw 'The exact Reservation checkout replay did not return the current terminal receipt.'
    }
    $checks.Add([ordered]@{ name = 'reservation-checkout-replay-current'; status = 'passed' })

    $released = Get-SmokeAvailabilityUnit
    if (-not ([bool]$released.isAvailable) -or
        @($released.activeAllocationIds).Count -ne 0) {
        throw 'The checked-out Reservation did not release the selected Inventory unit.'
    }
    $checks.Add([ordered]@{ name = 'inventory-released-after-checkout'; status = 'passed' })

    $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -ObservedAdmissionEvidenceReference ([ref]$observedAdmissionEvidenceReference)
    if ($observedReleaseId -cne $releaseIdBefore) {
        throw 'The public API release identity changed during Reservation lifecycle verification.'
    }
    $checks.Add([ordered]@{ name = 'release-identity-continuous'; status = 'passed' })
}
catch {
    Complete-SmokeReservationBestEffort
    throw
}
finally {
    $client.Dispose()
    $operatorToken = $null
    $guestLabel = $null
}

$evidence = [ordered]@{
    schemaVersion = 3
    evidenceKind = 'bunkfy-deployed-reservations-inventory-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    admissionEvidenceReference = $observedAdmissionEvidenceReference
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-preview' }
    result = 'passed'
    workflow = [ordered]@{
        bookingSource = 'direct'
        allocationLifecycle = 'available-confirmed-released'
        occupancyLifecycle = 'confirmed-checked-in-checked-out'
        createReplay = 'stable-current'
        checkInReplay = 'stable-current'
        checkOutReplay = 'stable-current'
        durableGuestRecordCreated = $false
    }
    cleanup = [ordered]@{
        reservationDisposition = 'synthetic-checked-out-retained'
        selectedInventoryUnit = 'available'
        activeAllocationCount = 0
        topologyMutated = $false
    }
    checks = @($checks)
    limitations = @(
        'browser-workflow-not-exercised',
        'durable-guest-record-not-created',
        'concurrent-overbooking-contention-not-exercised',
        'synthetic-checked-out-reservation-retained'
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

Write-Host "BunkFy deployed Reservations and Inventory verification passed for '$ExpectedReleaseId'."
Write-Host "Evidence: $OutputPath"
