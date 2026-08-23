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
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/guests-stay-history-$stamp.json"
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
    -EnvironmentVariable 'BUNKFY_SMOKE_GUESTS_OPERATOR_TOKEN' `
    -Prompt 'Guests workflow operator access token'
$deniedToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $DeniedAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_GUESTS_DENIED_TOKEN' `
    -Prompt 'Guests workflow nonmember access token'
if ([string]::IsNullOrWhiteSpace($operatorToken) -or
    [string]::IsNullOrWhiteSpace($deniedToken)) {
    throw 'Both Guests verification access tokens are required.'
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
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Deployed-Guests-Stay-History-Probe/1')

$checks = [Collections.Generic.List[object]]::new()
$guestPath = "/api/guests/properties/$($PropertyId.ToString('D'))"
$reservationPath = "/api/reservations/properties/$($PropertyId.ToString('D'))"
$guestCreateOperationId = [Guid]::NewGuid()
$guestUpdateOperationId = [Guid]::NewGuid()
$guestArchiveOperationId = [Guid]::NewGuid()
$reservationOperationId = [Guid]::NewGuid()
$checkInOperationId = [Guid]::NewGuid()
$checkOutOperationId = [Guid]::NewGuid()
$guestId = $guestCreateOperationId
$reservationId = $reservationOperationId
$guestCreateAttempted = $false
$guestArchived = $false
$guestArchiveExpectedVersion = $null
$reservationCreateAttempted = $false
$reservationTerminal = $false
$inventoryReleased = $false
$observedReleaseId = $null
$labelSuffix = $guestCreateOperationId.ToString('N').Substring(0, 8)
$initialGuestLabel = "BunkFy guest proof $labelSuffix"
$updatedGuestLabel = "BunkFy guest proof updated $labelSuffix"
$finalGuestVersion = 0L
$finalReservationVersion = 0L
$finalStayVersion = 0L

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

function Clear-SmokeResponseBody {
    param([AllowNull()][object] $Response)

    if ($null -ne $Response -and
        $null -ne $Response.Body -and
        $Response.Body.Length -gt 0) {
        [Array]::Clear($Response.Body, 0, $Response.Body.Length)
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

function Test-SmokeTimestampReplayEquivalent {
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset] $Left,
        [Parameter(Mandatory = $true)][DateTimeOffset] $Right
    )

    return [Math]::Abs(($Left - $Right).Ticks) -le
        [TimeSpan]::FromMilliseconds(1).Ticks
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

function Get-SmokeAvailabilityUnit {
    $response = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/inventory/properties/$($PropertyId.ToString('D'))/availability?arrival=$arrivalText&departure=$departureText" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read Guests proof Inventory availability'
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

function Get-SmokeGuest {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "$guestPath/$($guestId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read synthetic Guest'
}

function Get-SmokeGuestDirectory {
    param(
        [Parameter(Mandatory = $true)][ValidateSet(1, 2)][int] $Status,
        [Parameter(Mandatory = $true)][string] $Search
    )

    $encodedSearch = [Uri]::EscapeDataString($Search)
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "$guestPath`?search=$encodedSearch&status=$Status&page=1&pageSize=10" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read synthetic Guest directory result'
}

function Invoke-SmokeGuestCreate {
    param([Parameter(Mandatory = $true)][string] $DisplayName)

    return Invoke-BunkFyAuthenticatedJsonRequestWithConvergence `
        -Client $client `
        -Origin $origin `
        -Path $guestPath `
        -Method POST `
        -TenantId $WorkspaceId.ToString('D') `
        -AccessToken $operatorToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body ([ordered]@{
            operationId = $guestCreateOperationId.ToString('D')
            displayName = $DisplayName
            legalName = $null
            email = $null
            phone = $null
            dateOfBirth = $null
            nationalityCountryCode = $null
            preferredLanguageTag = $null
            notes = $null
        }) `
        -ExpectedStatus 200 `
        -Operation 'Create synthetic Guest' `
        -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
        -PollIntervalMilliseconds $PollIntervalMilliseconds `
        -RetryableProblemCodes @('Guests.CountryPolicyDenied.MissingBinding')
}

function Invoke-SmokeGuestUpdate {
    param(
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][string] $DisplayName,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion
    )

    return Invoke-SmokeApi `
        -Path "$guestPath/$($guestId.ToString('D'))" `
        -Method PUT `
        -Body ([ordered]@{
            operationId = $OperationId.ToString('D')
            displayName = $DisplayName
            legalName = $null
            email = $null
            phone = $null
            dateOfBirth = $null
            nationalityCountryCode = $null
            preferredLanguageTag = $null
            notes = $null
            expectedVersion = $ExpectedVersion
        })
}

function Invoke-SmokeGuestArchive {
    param([Parameter(Mandatory = $true)][long] $ExpectedVersion)

    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "$guestPath/$($guestId.ToString('D'))/archive" `
            -Method POST `
            -Body ([ordered]@{
                operationId = $guestArchiveOperationId.ToString('D')
                expectedVersion = $ExpectedVersion
                confirmed = $true
            })) `
        -ExpectedStatus 200 `
        -Operation 'Archive synthetic Guest'
}

function Get-SmokeReservation {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "$reservationPath/$($reservationId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read Guests proof Reservation'
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
    return Invoke-BunkFyAuthenticatedJsonRequestWithConvergence `
        -Client $client `
        -Origin $origin `
        -Path $reservationPath `
        -Method POST `
        -TenantId $WorkspaceId.ToString('D') `
        -AccessToken $operatorToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body ([ordered]@{
            operationId = $reservationOperationId.ToString('D')
            arrival = $arrivalText
            departure = $departureText
            expectedArrivalTime = $null
            expectedDepartureTime = $null
            inventoryUnitIds = @($InventoryUnitId.ToString('D'))
            primaryGuestName = $updatedGuestLabel
            email = $null
            phone = $null
            guestCount = 1
            sourceKind = 1
            sourceSystem = $null
            sourceReference = $null
            notes = $null
        }) `
        -ExpectedStatus 200 `
        -Operation 'Create Guests proof Reservation' `
        -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
        -PollIntervalMilliseconds $PollIntervalMilliseconds `
        -RetryableProblemCodes @('Reservations.CountryPolicyDenied.MissingBinding')
}

function Invoke-SmokeReservationLink {
    param([Parameter(Mandatory = $true)][long] $ExpectedVersion)

    return Invoke-BunkFyAuthenticatedJsonRequestWithConvergence `
        -Client $client `
        -Origin $origin `
        -Path "$reservationPath/$($reservationId.ToString('D'))/guests" `
        -Method PUT `
        -TenantId $WorkspaceId.ToString('D') `
        -AccessToken $operatorToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body ([ordered]@{
            guestId = $guestId.ToString('D')
            role = 1
            replaceExistingRole = $false
            expectedVersion = $ExpectedVersion
        }) `
        -ExpectedStatus 200 `
        -Operation 'Link canonical Guest to Reservation' `
        -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
        -PollIntervalMilliseconds $PollIntervalMilliseconds `
        -RetryableProblemCodes @(
            'Reservations.GuestNotLinkable',
            'Reservations.CountryPolicyDenied.MissingBinding')
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
            -Path "$reservationPath/$($reservationId.ToString('D'))/$Action" `
            -Method POST `
            -Body $body) `
        -ExpectedStatus 200 `
        -Operation "Reservation $Action"
}

function Wait-SmokeGuestStay {
    param(
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][int[]] $AllowedStatuses,
        [Parameter(Mandatory = $true)][long] $MinimumReservationVersion,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $history = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "$guestPath/$($guestId.ToString('D'))/stays?page=1&pageSize=10" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation $Operation
        $matches = @($history.stays | Where-Object {
                [Guid]$_.reservationId -eq $reservationId
            })
        if ($matches.Count -gt 1) {
            throw "$Operation returned duplicate stay-history entries."
        }
        if ($matches.Count -eq 1) {
            $stay = $matches[0]
            if ([Guid]$stay.propertyId -ne $PropertyId -or
                [int]$stay.role -ne 1 -or
                [string]$stay.arrival -cne $arrivalText -or
                [string]$stay.departure -cne $departureText -or
                -not [bool]$stay.isCurrentParticipant) {
                throw "$Operation returned an invalid stay-history projection."
            }
            $status = [int]$stay.status
            $version = [long]$stay.reservationVersion
            if ($status -eq $ExpectedStatus -and $version -ge $MinimumReservationVersion) {
                return $stay
            }
            if ($status -notin $AllowedStatuses -or $version -gt $MinimumReservationVersion + 4) {
                throw "$Operation observed unexpected stay status '$status' at Reservation version '$version'."
            }
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "$Operation did not converge within $ConvergenceTimeoutSeconds seconds."
}

function Complete-SmokeReservationCleanup {
    if (-not $reservationCreateAttempted) {
        return
    }

    $response = Invoke-SmokeApi `
        -Path "$reservationPath/$($reservationId.ToString('D'))" `
        -Method GET `
        -Body $null
    if ($response.StatusCode -eq 404) {
        Clear-SmokeResponseBody -Response $response
        return
    }
    $reservation = Read-SmokeJson `
        -Response $response `
        -ExpectedStatus 200 `
        -Operation 'Read Reservation during cleanup'
    switch ([int]$reservation.status) {
        { $_ -in @(1, 2) } {
            [void](Invoke-SmokeLifecycleMutation `
                    -Action cancel `
                    -OperationId ([Guid]::NewGuid()) `
                    -ExpectedVersion ([long]$reservation.version))
            [void](Wait-SmokeReservationStatus `
                    -ExpectedStatus 5 `
                    -AllowedStatuses @(4, 5) `
                    -Operation 'Guests proof Reservation cleanup cancellation')
            $reservationTerminal = $true
            return
        }
        4 {
            [void](Wait-SmokeReservationStatus `
                    -ExpectedStatus 5 `
                    -AllowedStatuses @(4, 5) `
                    -Operation 'Guests proof Reservation cleanup cancellation')
            $reservationTerminal = $true
            return
        }
        6 {
            [void](Invoke-SmokeLifecycleMutation `
                    -Action check-out `
                    -OperationId ([Guid]::NewGuid()) `
                    -ExpectedVersion ([long]$reservation.version))
            [void](Wait-SmokeReservationStatus `
                    -ExpectedStatus 10 `
                    -AllowedStatuses @(9, 10) `
                    -Operation 'Guests proof Reservation cleanup checkout')
            $reservationTerminal = $true
            return
        }
        9 {
            [void](Wait-SmokeReservationStatus `
                    -ExpectedStatus 10 `
                    -AllowedStatuses @(9, 10) `
                    -Operation 'Guests proof Reservation cleanup checkout')
            $reservationTerminal = $true
            return
        }
        { $_ -in @(3, 5, 8, 10) } {
            $reservationTerminal = $true
            return
        }
        default {
            throw "Guests proof Reservation cleanup found unsupported status '$([int]$reservation.status)'."
        }
    }
}

function Archive-SmokeGuestCleanup {
    if (-not $guestCreateAttempted -or $guestArchived) {
        return
    }

    $response = Invoke-SmokeApi `
        -Path "$guestPath/$($guestId.ToString('D'))" `
        -Method GET `
        -Body $null
    if ($response.StatusCode -eq 404) {
        Clear-SmokeResponseBody -Response $response
        return
    }
    $guest = Read-SmokeJson `
        -Response $response `
        -ExpectedStatus 200 `
        -Operation 'Read Guest during cleanup'
    if ([int]$guest.status -eq 2) {
        $guestArchived = $true
        $finalGuestVersion = [long]$guest.version
        return
    }
    if ([int]$guest.status -ne 1) {
        throw "Guests proof cleanup found unsupported Guest status '$([int]$guest.status)'."
    }
    if ($null -eq $guestArchiveExpectedVersion) {
        $guestArchiveExpectedVersion = [long]$guest.version
    }
    $archived = Invoke-SmokeGuestArchive -ExpectedVersion $guestArchiveExpectedVersion
    if ([int]$archived.status -ne 2) {
        throw 'Guests proof cleanup did not archive the synthetic Guest.'
    }
    $guestArchived = $true
    $finalGuestVersion = [long]$archived.version
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
            -Operation 'Read Guests proof property'
        if ([Guid]$property.propertyId -ne $PropertyId) {
            throw 'The Guests proof property preflight returned a different property.'
        }
        $availableBefore = Get-SmokeAvailabilityUnit
        if (-not [bool]$availableBefore.isAvailable -or
            @($availableBefore.activeAllocationIds).Count -ne 0) {
            throw "The selected Inventory unit is not available before the Guests workflow (available=$([bool]$availableBefore.isAvailable), activeAllocations=$(@($availableBefore.activeAllocationIds).Count))."
        }
        $checks.Add([ordered]@{ name = 'scoped-operator-property-and-inventory-preflight'; status = 'passed' })

        $deniedDirectory = Invoke-SmokeApi `
            -Path "$guestPath`?page=1&pageSize=1" `
            -Method GET `
            -Body $null `
            -Token $deniedToken
        Assert-BunkFyAuthenticatedStatus `
            -Response $deniedDirectory `
            -ExpectedStatus 403 `
            -Operation 'Nonmember Guest directory read'
        Clear-SmokeResponseBody -Response $deniedDirectory
        $checks.Add([ordered]@{ name = 'nonmember-guest-directory-denied'; status = 'passed' })

        if (-not $PSCmdlet.ShouldProcess(
                "property $($PropertyId.ToString('D'))",
                'Create, manage, link, complete, and archive a synthetic Guest workflow')) {
            return
        }

        $guestCreateAttempted = $true
        $created = Invoke-SmokeGuestCreate -DisplayName $initialGuestLabel
        if ([Guid]$created.guestId -ne $guestId -or
            [int]$created.status -ne 1 -or
            [long]$created.version -ne 1) {
            throw 'Synthetic Guest creation returned an unexpected receipt.'
        }
        $createdAtUtc = [DateTimeOffset]$created.lastChangedAtUtc
        $checks.Add([ordered]@{ name = 'guest-created-with-minimal-profile'; status = 'passed' })

        $createReplay = Invoke-SmokeGuestCreate -DisplayName $initialGuestLabel
        if ([Guid]$createReplay.guestId -ne $guestId -or
            [int]$createReplay.status -ne 1 -or
            [long]$createReplay.version -ne 1 -or
            -not (Test-SmokeTimestampReplayEquivalent `
                -Left ([DateTimeOffset]$createReplay.lastChangedAtUtc) `
                -Right $createdAtUtc)) {
            throw 'The exact Guest create replay did not return the stable receipt.'
        }
        $checks.Add([ordered]@{ name = 'guest-create-replay-stable'; status = 'passed' })

        $createConflict = Invoke-SmokeApi `
            -Path $guestPath `
            -Method POST `
            -Body ([ordered]@{
                operationId = $guestCreateOperationId.ToString('D')
                displayName = "$initialGuestLabel conflict"
                legalName = $null
                email = $null
                phone = $null
                dateOfBirth = $null
                nationalityCountryCode = $null
                preferredLanguageTag = $null
                notes = $null
            })
        Assert-SmokeProblem `
            -Response $createConflict `
            -ExpectedStatus 409 `
            -ExpectedCode 'Guests.CreationOperationConflict' `
            -Operation 'Conflicting Guest creation operation reuse'
        $checks.Add([ordered]@{ name = 'guest-create-conflict-rejected'; status = 'passed' })

        $detail = Get-SmokeGuest
        if ([Guid]$detail.guestId -ne $guestId -or
            [Guid]$detail.originPropertyId -ne $PropertyId -or
            [string]$detail.displayName -cne $initialGuestLabel -or
            [int]$detail.status -ne 1 -or
            $null -ne $detail.legalName -or
            $null -ne $detail.email -or
            $null -ne $detail.phone -or
            $null -ne $detail.dateOfBirth -or
            $null -ne $detail.nationalityCountryCode -or
            $null -ne $detail.preferredLanguageTag -or
            $null -ne $detail.notes) {
            throw 'The created Guest detail was not the exact minimal profile.'
        }
        $activeDirectory = Get-SmokeGuestDirectory -Status 1 -Search $initialGuestLabel
        $activeMatches = @($activeDirectory.guests | Where-Object {
                [Guid]$_.guestId -eq $guestId
            })
        if ($activeMatches.Count -ne 1 -or [int]$activeMatches[0].status -ne 1) {
            throw 'The active Guest directory did not expose the created Guest exactly once.'
        }
        $checks.Add([ordered]@{ name = 'guest-detail-and-active-directory-visible'; status = 'passed' })

        $updated = Read-SmokeJson `
            -Response (Invoke-SmokeGuestUpdate `
                -OperationId $guestUpdateOperationId `
                -DisplayName $updatedGuestLabel `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Update synthetic Guest'
        if ([Guid]$updated.guestId -ne $guestId -or
            [int]$updated.status -ne 1 -or
            [long]$updated.version -ne 2) {
            throw 'Synthetic Guest update returned an unexpected receipt.'
        }
        $updatedAtUtc = [DateTimeOffset]$updated.lastChangedAtUtc
        $checks.Add([ordered]@{ name = 'guest-versioned-update-recorded'; status = 'passed' })

        $updateReplay = Read-SmokeJson `
            -Response (Invoke-SmokeGuestUpdate `
                -OperationId $guestUpdateOperationId `
                -DisplayName $updatedGuestLabel `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Guest update'
        if ([Guid]$updateReplay.guestId -ne $guestId -or
            [long]$updateReplay.version -ne 2 -or
            -not (Test-SmokeTimestampReplayEquivalent `
                -Left ([DateTimeOffset]$updateReplay.lastChangedAtUtc) `
                -Right $updatedAtUtc)) {
            throw 'The exact Guest update replay did not return the stable receipt.'
        }
        $checks.Add([ordered]@{ name = 'guest-update-replay-stable'; status = 'passed' })

        $updateConflict = Invoke-SmokeGuestUpdate `
            -OperationId $guestUpdateOperationId `
            -DisplayName "$updatedGuestLabel conflict" `
            -ExpectedVersion 1
        Assert-SmokeProblem `
            -Response $updateConflict `
            -ExpectedStatus 409 `
            -ExpectedCode 'Guests.ManagementOperationConflict' `
            -Operation 'Conflicting Guest update operation reuse'
        $staleUpdate = Invoke-SmokeGuestUpdate `
            -OperationId ([Guid]::NewGuid()) `
            -DisplayName $updatedGuestLabel `
            -ExpectedVersion 1
        Assert-SmokeProblem `
            -Response $staleUpdate `
            -ExpectedStatus 409 `
            -ExpectedCode 'Guests.VersionConflict' `
            -Operation 'Stale Guest update'
        $checks.Add([ordered]@{ name = 'guest-conflicting-and-stale-updates-rejected'; status = 'passed' })

        $updatedDetail = Get-SmokeGuest
        if ([string]$updatedDetail.displayName -cne $updatedGuestLabel -or
            [long]$updatedDetail.version -ne 2) {
            throw 'The Guest detail did not expose the committed update.'
        }
        $checks.Add([ordered]@{ name = 'guest-update-visible'; status = 'passed' })

        $reservationCreateAttempted = $true
        $reservationCreated = Invoke-SmokeReservationCreate
        if ([Guid]$reservationCreated.reservationId -ne $reservationId -or
            [int]$reservationCreated.status -notin @(1, 2)) {
            throw 'Guests proof Reservation creation returned an unexpected receipt.'
        }
        $confirmed = Wait-SmokeReservationStatus `
            -ExpectedStatus 2 `
            -AllowedStatuses @(1, 2) `
            -Operation 'Guests proof Reservation allocation'
        $checks.Add([ordered]@{ name = 'reservation-allocation-confirmed'; status = 'passed' })

        $linked = Invoke-SmokeReservationLink -ExpectedVersion ([long]$confirmed.version)
        if ([Guid]$linked.reservationId -ne $reservationId -or
            [int]$linked.status -ne 2 -or
            [long]$linked.version -le [long]$confirmed.version) {
            throw 'Canonical Guest link returned an unexpected Reservation receipt.'
        }
        $linkReplay = Invoke-SmokeReservationLink -ExpectedVersion ([long]$confirmed.version)
        if ([Guid]$linkReplay.reservationId -ne $reservationId -or
            [long]$linkReplay.version -ne [long]$linked.version -or
            [long]$linkReplay.detailsRevision -ne [long]$linked.detailsRevision) {
            throw 'The exact Reservation Guest link replay was not stable.'
        }
        $linkedReservation = Get-SmokeReservation
        $linkedGuests = @($linkedReservation.guests)
        if ($linkedGuests.Count -ne 1 -or
            [Guid]$linkedGuests[0].guestId -ne $guestId -or
            [int]$linkedGuests[0].role -ne 1 -or
            [long]$linkedReservation.version -ne [long]$linked.version) {
            throw 'The Reservation did not expose the canonical primary Guest link.'
        }
        $checks.Add([ordered]@{ name = 'reservation-primary-guest-link-replay-stable'; status = 'passed' })

        $confirmedStay = Wait-SmokeGuestStay `
            -ExpectedStatus 2 `
            -AllowedStatuses @(1, 2) `
            -MinimumReservationVersion ([long]$linked.version) `
            -Operation 'Wait for confirmed Guest stay projection'
        if ($null -ne $confirmedStay.checkedInBusinessDate -or
            $null -ne $confirmedStay.checkedOutBusinessDate) {
            throw 'The confirmed Guest stay projection contains terminal lifecycle dates.'
        }
        $checks.Add([ordered]@{ name = 'guest-stay-confirmed-projection-converged'; status = 'passed' })

        $checkedIn = Invoke-SmokeLifecycleMutation `
            -Action check-in `
            -OperationId $checkInOperationId `
            -ExpectedVersion ([long]$linked.version)
        if ([int]$checkedIn.status -ne 6) {
            throw 'Guests proof Reservation check-in was not recorded synchronously.'
        }
        $checkedInStay = Wait-SmokeGuestStay `
            -ExpectedStatus 6 `
            -AllowedStatuses @(2, 6) `
            -MinimumReservationVersion ([long]$checkedIn.version) `
            -Operation 'Wait for checked-in Guest stay projection'
        if ([string]$checkedInStay.checkedInBusinessDate -cne $arrivalText -or
            $null -ne $checkedInStay.checkedOutBusinessDate -or
            [long]$checkedInStay.reservationVersion -le [long]$confirmedStay.reservationVersion) {
            throw 'The checked-in Guest stay projection was not monotonic and date-complete.'
        }
        $checks.Add([ordered]@{ name = 'guest-stay-check-in-projection-converged'; status = 'passed' })

        $checkoutRequested = Invoke-SmokeLifecycleMutation `
            -Action check-out `
            -OperationId $checkOutOperationId `
            -ExpectedVersion ([long]$checkedIn.version)
        if ([int]$checkoutRequested.status -notin @(9, 10)) {
            throw 'Guests proof Reservation checkout returned an unexpected receipt.'
        }
        $checkedOutReservation = if ([int]$checkoutRequested.status -eq 10) {
            Get-SmokeReservation
        }
        else {
            Wait-SmokeReservationStatus `
                -ExpectedStatus 10 `
                -AllowedStatuses @(9, 10) `
                -Operation 'Guests proof Reservation checkout'
        }
        $reservationTerminal = $true
        $finalReservationVersion = [long]$checkedOutReservation.version
        $checkedOutStay = Wait-SmokeGuestStay `
            -ExpectedStatus 10 `
            -AllowedStatuses @(6, 9, 10) `
            -MinimumReservationVersion $finalReservationVersion `
            -Operation 'Wait for checked-out Guest stay projection'
        if ([string]$checkedOutStay.checkedInBusinessDate -cne $arrivalText -or
            [string]$checkedOutStay.checkedOutBusinessDate -cne $arrivalText -or
            [long]$checkedOutStay.reservationVersion -ne $finalReservationVersion -or
            [long]$checkedOutStay.reservationVersion -le [long]$checkedInStay.reservationVersion) {
            throw 'The checked-out Guest stay projection was not terminal and monotonic.'
        }
        $finalStayVersion = [long]$checkedOutStay.reservationVersion
        $checks.Add([ordered]@{ name = 'guest-stay-checkout-projection-converged'; status = 'passed' })

        $terminalReservation = Get-SmokeReservation
        $terminalGuests = @($terminalReservation.guests)
        if ([int]$terminalReservation.status -ne 10 -or
            $terminalGuests.Count -ne 1 -or
            [Guid]$terminalGuests[0].guestId -ne $guestId) {
            throw 'The terminal Reservation did not retain its canonical Guest reference.'
        }
        $availableAfter = Get-SmokeAvailabilityUnit
        if (-not [bool]$availableAfter.isAvailable -or
            @($availableAfter.activeAllocationIds).Count -ne 0) {
            throw 'The checked-out Guest workflow did not release its Inventory unit.'
        }
        $inventoryReleased = $true
        $checks.Add([ordered]@{ name = 'terminal-reservation-retained-and-inventory-released'; status = 'passed' })

        $guestArchiveExpectedVersion = [long]$updated.version
        $archived = Invoke-SmokeGuestArchive -ExpectedVersion $guestArchiveExpectedVersion
        if ([Guid]$archived.guestId -ne $guestId -or
            [int]$archived.status -ne 2 -or
            [long]$archived.version -ne $guestArchiveExpectedVersion + 1) {
            throw 'Synthetic Guest archive returned an unexpected receipt.'
        }
        $guestArchived = $true
        $finalGuestVersion = [long]$archived.version
        $archiveReplay = Invoke-SmokeGuestArchive -ExpectedVersion $guestArchiveExpectedVersion
        if ([Guid]$archiveReplay.guestId -ne $guestId -or
            [int]$archiveReplay.status -ne 2 -or
            [long]$archiveReplay.version -ne $finalGuestVersion -or
            -not (Test-SmokeTimestampReplayEquivalent `
                -Left ([DateTimeOffset]$archiveReplay.lastChangedAtUtc) `
                -Right ([DateTimeOffset]$archived.lastChangedAtUtc))) {
            throw 'The exact Guest archive replay did not return the stable terminal receipt.'
        }
        $checks.Add([ordered]@{ name = 'guest-archive-replay-stable'; status = 'passed' })

        $archivedDetail = Get-SmokeGuest
        if ([int]$archivedDetail.status -ne 2 -or
            [long]$archivedDetail.version -ne $finalGuestVersion -or
            $null -eq $archivedDetail.archivedAtUtc) {
            throw 'The archived Guest detail did not expose its terminal state.'
        }
        $activeAfterArchive = Get-SmokeGuestDirectory -Status 1 -Search $updatedGuestLabel
        if (@($activeAfterArchive.guests | Where-Object {
                    [Guid]$_.guestId -eq $guestId
                }).Count -ne 0) {
            throw 'The archived Guest remained in the active Guest directory.'
        }
        $archivedDirectory = Get-SmokeGuestDirectory -Status 2 -Search $updatedGuestLabel
        $archivedMatches = @($archivedDirectory.guests | Where-Object {
                [Guid]$_.guestId -eq $guestId
            })
        if ($archivedMatches.Count -ne 1 -or [int]$archivedMatches[0].status -ne 2) {
            throw 'The archived Guest was not explicitly queryable in the archived directory.'
        }
        $archivedStay = Wait-SmokeGuestStay `
            -ExpectedStatus 10 `
            -AllowedStatuses @(10) `
            -MinimumReservationVersion $finalStayVersion `
            -Operation 'Read archived Guest stay history'
        if ([long]$archivedStay.reservationVersion -ne $finalStayVersion) {
            throw 'The archived Guest did not retain the terminal stay history.'
        }
        $checks.Add([ordered]@{ name = 'archived-guest-directory-and-history-consistent'; status = 'passed' })

        $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
            -Client $client `
            -Origin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -TimeoutSeconds $RequestTimeoutSeconds `
            -ObservedAdmissionEvidenceReference ([ref]$observedAdmissionEvidenceReference)
        if ($observedReleaseId -cne $releaseIdBefore) {
            throw 'The public API release identity changed during Guests verification.'
        }
        $checks.Add([ordered]@{ name = 'release-identity-continuous'; status = 'passed' })
    }
    catch {
        $workflowError = $_.Exception
    }
    finally {
        try {
            Complete-SmokeReservationCleanup
        }
        catch {
            $cleanupErrors.Add("reservation: $($_.Exception.Message)")
        }
        try {
            Archive-SmokeGuestCleanup
        }
        catch {
            $cleanupErrors.Add("guest: $($_.Exception.Message)")
        }
    }
}
finally {
    $client.Dispose()
    $operatorToken = $null
    $deniedToken = $null
    $initialGuestLabel = $null
    $updatedGuestLabel = $null
}

if ($cleanupErrors.Count -gt 0) {
    $cleanupSummary = $cleanupErrors -join '; '
    if ($null -ne $workflowError) {
        throw "Guests workflow failed: $($workflowError.Message) Cleanup also failed: $cleanupSummary"
    }
    throw "Guests workflow cleanup failed: $cleanupSummary"
}
if ($null -ne $workflowError) {
    throw $workflowError
}
if (-not $guestArchived -or -not $reservationTerminal -or -not $inventoryReleased) {
    throw 'Guests verification did not reach its required terminal cleanup state.'
}

$evidence = [ordered]@{
    schemaVersion = 2
    evidenceKind = 'bunkfy-deployed-guests-stay-history-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    admissionEvidenceReference = $observedAdmissionEvidenceReference
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-fixture' }
    result = 'passed'
    workflow = [ordered]@{
        guestFinalStatus = 'archived'
        reservationFinalStatus = 'checked-out'
        participantRole = 'primary'
        stayFinalStatus = 'checked-out'
        stayCount = 1
        guestVersionAdvanced = $finalGuestVersion -gt 1
        reservationVersionsMonotonic = $finalReservationVersion -eq $finalStayVersion
    }
    cleanup = [ordered]@{
        guestArchived = $guestArchived
        reservationDisposition = 'synthetic-checked-out-retained'
        inventoryReleased = $inventoryReleased
        roomDisposition = 'parent-rehearsal-owned'
    }
    checks = @($checks)
    limitations = @(
        'browser-guest-workflow-not-exercised',
        'guest-deduplication-merge-and-consent-not-exercised',
        'concurrent-participant-and-overbooking-contention-not-exercised',
        'synthetic-archived-guest-and-checked-out-reservation-retained'
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

Write-Host "BunkFy deployed Guests stay-history verification passed for '$ExpectedReleaseId'."
Write-Host "Evidence: $OutputPath"
