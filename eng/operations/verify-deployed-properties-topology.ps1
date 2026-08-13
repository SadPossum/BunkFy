[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][Guid] $WorkspaceId,
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
if ($WorkspaceId -eq [Guid]::Empty) {
    throw 'WorkspaceId must not be an empty GUID.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/properties-topology-$stamp.json"
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
    -EnvironmentVariable 'BUNKFY_SMOKE_PROPERTIES_OPERATOR_TOKEN' `
    -Prompt 'Properties topology workflow operator access token'
$deniedToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $DeniedAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_PROPERTIES_DENIED_TOKEN' `
    -Prompt 'Properties topology workflow nonmember access token'
if ([string]::IsNullOrWhiteSpace($operatorToken) -or
    [string]::IsNullOrWhiteSpace($deniedToken)) {
    throw 'Both Properties topology verification access tokens are required.'
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
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Deployed-Properties-Topology-Probe/1')

$checks = [Collections.Generic.List[object]]::new()
$createPropertyOperationId = [Guid]::NewGuid()
$propertyId = $createPropertyOperationId
$updatePropertyOperationId = [Guid]::NewGuid()
$createRoomOperationId = [Guid]::NewGuid()
$updateRoomOperationId = [Guid]::NewGuid()
$addBedsOperationId = [Guid]::NewGuid()
$updateBedOperationId = [Guid]::NewGuid()
$bedRetirementOperationId = [Guid]::NewGuid()
$roomRetirementOperationId = [Guid]::NewGuid()
$propertyRetirementOperationId = [Guid]::NewGuid()
$roomId = [Guid]::Empty
$bedIds = [Collections.Generic.List[Guid]]::new()
$bedRetirementId = [Guid]::Empty
$roomRetirementId = [Guid]::Empty
$propertyCreateAttempted = $false
$bedRetirementRequested = $false
$roomRetirementRequested = $false
$propertyRetirementExpectedVersion = 0L
$propertyRetired = $false
$roomRetired = $false
$retiredBedCount = 0
$topologyRetirementsCompleted = $false
$directRetirementDenied = $false
$observedReleaseId = $null
$initialPropertyVersion = 0L
$finalPropertyVersion = 0L
$initialRoomVersion = 0L
$finalRoomVersion = 0L
$bedVersionsAdvanced = $false
$suffix = $propertyId.ToString('N').Substring(0, 10)
$initialPropertyName = "BunkFy topology proof $suffix"
$updatedPropertyName = "BunkFy topology proof updated $suffix"
$initialPropertyCode = "bf-topo-$suffix"
$updatedPropertyCode = "bf-topo-u-$suffix"
$initialRoomName = "Topology room $suffix"
$updatedRoomName = "Topology room updated $suffix"
$buildingLabel = 'BunkFy topology verification'
$floorLabel = 'Verification floor'
$bedLabels = @("A-$suffix", "B-$suffix")
$updatedBedLabel = "A-updated-$suffix"
$bedRetirementReason = 'Synthetic topology bed retirement'
$roomRetirementReason = 'Synthetic topology room retirement'

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

function Get-SmokeProperty {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/properties/$($propertyId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read synthetic property'
}

function Get-SmokePropertyOptional {
    $response = Invoke-SmokeApi `
        -Path "/api/properties/$($propertyId.ToString('D'))" `
        -Method GET `
        -Body $null
    if ($response.StatusCode -eq 404) {
        Clear-SmokeResponseBody -Response $response
        return $null
    }
    return Read-SmokeJson -Response $response -ExpectedStatus 200 -Operation 'Read synthetic property during cleanup'
}

function Get-SmokePropertyDirectoryMatch {
    $matches = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $response = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties?page=$page&pageSize=100" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read property directory'
        foreach ($entry in @($response.properties)) {
            if ([Guid]$entry.propertyId -eq $propertyId) {
                [void]$matches.Add($entry)
            }
        }
        $page++
        if ($page -gt 100) {
            throw 'The property directory lookup exceeded 100 pages.'
        }
    } while ([bool]$response.hasMore)

    if ($matches.Count -ne 1) {
        throw "The property directory exposed $($matches.Count) synthetic matches; expected one."
    }
    return $matches[0]
}

function Get-SmokeRoom {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read synthetic room'
}

function Find-SmokeRoomForCleanup {
    if ($roomId -ne [Guid]::Empty) {
        $response = Invoke-SmokeApi `
            -Path "/api/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))" `
            -Method GET `
            -Body $null
        if ($response.StatusCode -eq 404) {
            Clear-SmokeResponseBody -Response $response
            return $null
        }
        return Read-SmokeJson -Response $response -ExpectedStatus 200 -Operation 'Read synthetic room during cleanup'
    }

    $page = 1
    do {
        $response = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($propertyId.ToString('D'))/rooms?page=$page&pageSize=100" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Discover synthetic room during cleanup'
        $matches = @($response.rooms | Where-Object {
                [string]$_.name -ceq $initialRoomName -or
                [string]$_.name -ceq $updatedRoomName
            })
        if ($matches.Count -gt 1) {
            throw 'Cleanup discovered duplicate synthetic rooms.'
        }
        if ($matches.Count -eq 1) {
            $script:roomId = [Guid]$matches[0].roomId
            return Get-SmokeRoom
        }
        $page++
        if ($page -gt 100) {
            throw 'Cleanup room discovery exceeded 100 pages.'
        }
    } while ([bool]$response.hasMore)
    return $null
}

function Get-SmokeRoomDirectoryMatch {
    $matches = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $response = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($propertyId.ToString('D'))/rooms?page=$page&pageSize=100" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read room directory'
        foreach ($entry in @($response.rooms)) {
            if ([Guid]$entry.roomId -eq $roomId) {
                [void]$matches.Add($entry)
            }
        }
        $page++
        if ($page -gt 100) {
            throw 'The room directory lookup exceeded 100 pages.'
        }
    } while ([bool]$response.hasMore)

    if ($matches.Count -ne 1) {
        throw "The room directory exposed $($matches.Count) synthetic matches; expected one."
    }
    return $matches[0]
}

function Get-SmokeBeds {
    $items = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $response = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))/beds?page=$page&pageSize=100" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read bed directory'
        foreach ($entry in @($response.beds)) {
            [void]$items.Add($entry)
        }
        $page++
        if ($page -gt 100) {
            throw 'The bed directory lookup exceeded 100 pages.'
        }
    } while ([bool]$response.hasMore)
    return @($items)
}

function Invoke-SmokePropertyCreate {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Code
    )

    return Invoke-SmokeApi `
        -Path '/api/properties' `
        -Method POST `
        -Body ([ordered]@{
            operationId = $createPropertyOperationId.ToString('D')
            name = $Name
            code = $Code
            timeZoneId = 'UTC'
        })
}

function Invoke-SmokePropertyUpdate {
    param(
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion
    )

    return Invoke-SmokeApi `
        -Path "/api/properties/$($propertyId.ToString('D'))" `
        -Method PUT `
        -Body ([ordered]@{
            operationId = $OperationId.ToString('D')
            name = $Name
            code = $Code
            timeZoneId = 'UTC'
            expectedVersion = $ExpectedVersion
        })
}

function Invoke-SmokeRoomCreate {
    param([Parameter(Mandatory = $true)][string] $Name)

    return Invoke-SmokeApi `
        -Path "/api/properties/$($propertyId.ToString('D'))/rooms" `
        -Method POST `
        -Body ([ordered]@{
            operationId = $createRoomOperationId.ToString('D')
            name = $Name
            expectedPropertyVersion = 2
            buildingLabel = $buildingLabel
            floorLabel = $floorLabel
        })
}

function Invoke-SmokeRoomUpdate {
    param(
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion
    )

    return Invoke-SmokeApi `
        -Path "/api/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))" `
        -Method PUT `
        -Body ([ordered]@{
            operationId = $OperationId.ToString('D')
            name = $Name
            expectedVersion = $ExpectedVersion
            buildingLabel = $buildingLabel
            floorLabel = $floorLabel
        })
}

function Invoke-SmokeBedBatch {
    param([Parameter(Mandatory = $true)][string[]] $Labels)

    return Invoke-SmokeApi `
        -Path "/api/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))/beds/batch" `
        -Method POST `
        -Body ([ordered]@{
            operationId = $addBedsOperationId.ToString('D')
            labels = $Labels
            expectedRoomVersion = 2
        })
}

function Invoke-SmokeBedUpdate {
    param(
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][Guid] $BedId,
        [Parameter(Mandatory = $true)][string] $Label,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion
    )

    return Invoke-SmokeApi `
        -Path "/api/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))/beds/$($BedId.ToString('D'))" `
        -Method PUT `
        -Body ([ordered]@{
            operationId = $OperationId.ToString('D')
            label = $Label
            expectedRoomVersion = $ExpectedVersion
        })
}

function Assert-SmokePropertyReceipt {
    param(
        [Parameter(Mandatory = $true)][object] $Receipt,
        [Parameter(Mandatory = $true)][int] $Status,
        [Parameter(Mandatory = $true)][long] $Version,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ([Guid]$Receipt.propertyId -ne $propertyId -or
        -not (Test-SmokeEnumValue -Value $Receipt.status -NumericValue $Status -Name $(if ($Status -eq 1) { 'active' } else { 'retired' })) -or
        -not (Test-SmokeEnumValue -Value $Receipt.processingStatus -NumericValue 1 -Name 'unconfigured') -or
        [long]$Receipt.version -ne $Version) {
        throw "$Operation returned an unexpected property receipt."
    }
}

function Assert-SmokePropertyReceiptReplay {
    param(
        [Parameter(Mandatory = $true)][object] $Original,
        [Parameter(Mandatory = $true)][object] $Replay,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ([Guid]$Replay.propertyId -ne [Guid]$Original.propertyId -or
        [string]$Replay.status -cne [string]$Original.status -or
        [string]$Replay.processingStatus -cne [string]$Original.processingStatus -or
        [long]$Replay.version -ne [long]$Original.version) {
        throw "$Operation did not return the stable property receipt."
    }
}

function Assert-SmokeRoomReceiptReplay {
    param(
        [Parameter(Mandatory = $true)][object] $Original,
        [Parameter(Mandatory = $true)][object] $Replay,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ([Guid]$Replay.propertyId -ne [Guid]$Original.propertyId -or
        [Guid]$Replay.roomId -ne [Guid]$Original.roomId -or
        [string]$Replay.status -cne [string]$Original.status -or
        [long]$Replay.version -ne [long]$Original.version) {
        throw "$Operation did not return the stable room receipt."
    }
}

function Assert-SmokeBedReceiptReplay {
    param(
        [Parameter(Mandatory = $true)][object] $Original,
        [Parameter(Mandatory = $true)][object] $Replay,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ([Guid]$Replay.propertyId -ne [Guid]$Original.propertyId -or
        [Guid]$Replay.roomId -ne [Guid]$Original.roomId -or
        [Guid]$Replay.bedId -ne [Guid]$Original.bedId -or
        [string]$Replay.status -cne [string]$Original.status -or
        [long]$Replay.version -ne [long]$Original.version -or
        [long]$Replay.roomVersion -ne [long]$Original.roomVersion) {
        throw "$Operation did not return the stable bed receipt."
    }
}

function Invoke-SmokeRetirementRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('bed', 'room')][string] $Kind,
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][string] $Reason,
        [switch] $AllowConvergence
    )

    $path = if ($Kind -ceq 'bed') {
        "/api/inventory/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))/beds/$($bedIds[0].ToString('D'))/retirement"
    }
    else {
        "/api/inventory/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))/retirement"
    }
    $body = [ordered]@{
        operationId = $OperationId.ToString('D')
        confirmed = $true
        reason = $Reason
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $response = Invoke-SmokeApi -Path $path -Method POST -Body $body
        if ($response.StatusCode -eq 200) {
            return Read-SmokeJson -Response $response -ExpectedStatus 200 -Operation "Request synthetic $Kind retirement"
        }
        $problem = Get-BunkFyAuthenticatedProblemCode -Response $response
        $retryable = $AllowConvergence -and (
            ($Kind -ceq 'bed' -and
                $response.StatusCode -eq 404 -and
                $problem -ceq 'Inventory.InventoryUnitNotFound') -or
            ($Kind -ceq 'room' -and
                (($response.StatusCode -eq 404 -and $problem -ceq 'Inventory.RoomNotFound') -or
                 ($response.StatusCode -eq 409 -and $problem -ceq 'Inventory.BedRetirementInProgress'))))
        if (-not $retryable) {
            return Read-SmokeJson -Response $response -ExpectedStatus 200 -Operation "Request synthetic $Kind retirement"
        }
        Clear-SmokeResponseBody -Response $response
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "The synthetic $Kind retirement request did not converge before the timeout."
}

function Assert-SmokeRetirementReplay {
    param(
        [Parameter(Mandatory = $true)][object] $Original,
        [Parameter(Mandatory = $true)][object] $Replay,
        [Parameter(Mandatory = $true)][ValidateSet('bed', 'room')][string] $Kind
    )

    $identityMatches = [Guid]$Replay.topologyChangeId -eq [Guid]$Original.topologyChangeId -and
        [Guid]$Replay.propertyId -eq $propertyId -and
        [Guid]$Replay.roomId -eq $roomId -and
        [string]$Replay.reason -ceq [string]$Original.reason -and
        [string]$Replay.requestedBy -ceq [string]$Original.requestedBy -and
        [long]$Replay.version -ge [long]$Original.version
    if ($Kind -ceq 'bed') {
        $identityMatches = $identityMatches -and [Guid]$Replay.bedId -eq $bedIds[0]
    }
    if (-not $identityMatches) {
        throw "The exact $Kind retirement replay did not preserve process identity and monotonic state."
    }
}

function Wait-SmokeRetirementCompleted {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('bed', 'room')][string] $Kind,
        [Parameter(Mandatory = $true)][Guid] $TopologyChangeId
    )

    $path = "/api/inventory/properties/$($propertyId.ToString('D'))/$Kind-retirements/$($TopologyChangeId.ToString('D'))"
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $process = Read-SmokeJson `
            -Response (Invoke-SmokeApi -Path $path -Method GET -Body $null) `
            -ExpectedStatus 200 `
            -Operation "Read synthetic $Kind retirement"
        if ([Guid]$process.topologyChangeId -ne $TopologyChangeId -or
            [Guid]$process.propertyId -ne $propertyId -or
            [Guid]$process.roomId -ne $roomId -or
            ($Kind -ceq 'bed' -and [Guid]$process.bedId -ne $bedIds[0])) {
            throw "The synthetic $Kind retirement query changed identity."
        }
        if (Test-SmokeEnumValue -Value $process.status -NumericValue 4 -Name 'completed') {
            if ([int]$process.activeAllocationCount -ne 0 -or
                [int]$process.activeManualBlockCount -ne 0 -or
                @($process.affectedReservationIds).Count -ne 0 -or
                [bool]$process.affectedReservationIdsTruncated -or
                $null -eq $process.completedAtUtc) {
                throw "The completed synthetic $Kind retirement retained an unexpected active impact."
            }
            if ($Kind -ceq 'room' -and [int]$process.activeBedRetirementCount -ne 0) {
                throw 'The completed synthetic room retirement retained an active bed retirement.'
            }
            return $process
        }
        if ((Test-SmokeEnumValue -Value $process.status -NumericValue 5 -Name 'rejected') -or
            (Test-SmokeEnumValue -Value $process.status -NumericValue 6 -Name 'canceled')) {
            throw "The synthetic $Kind retirement reached a non-terminal-success state."
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "The synthetic $Kind retirement did not complete before the timeout."
}

function Complete-SmokePropertiesCleanup {
    if (-not $propertyCreateAttempted) {
        return
    }

    $property = Get-SmokePropertyOptional
    if ($null -eq $property) {
        return
    }

    $room = Find-SmokeRoomForCleanup
    if ($null -ne $room -and
        (Test-SmokeEnumValue -Value $room.status -NumericValue 1 -Name 'active')) {
        if ($bedRetirementRequested -and $bedIds.Count -gt 0) {
            $bedProcess = Invoke-SmokeRetirementRequest `
                -Kind bed `
                -OperationId $bedRetirementOperationId `
                -Reason $bedRetirementReason `
                -AllowConvergence
            $script:bedRetirementId = [Guid]$bedProcess.topologyChangeId
            [void](Wait-SmokeRetirementCompleted -Kind bed -TopologyChangeId $bedRetirementId)
        }

        $roomProcess = Invoke-SmokeRetirementRequest `
            -Kind room `
            -OperationId $roomRetirementOperationId `
            -Reason $roomRetirementReason `
            -AllowConvergence
        $script:roomRetirementRequested = $true
        $script:roomRetirementId = [Guid]$roomProcess.topologyChangeId
        [void](Wait-SmokeRetirementCompleted -Kind room -TopologyChangeId $roomRetirementId)
    }

    $room = Find-SmokeRoomForCleanup
    if ($null -ne $room) {
        $script:roomRetired = Test-SmokeEnumValue -Value $room.status -NumericValue 2 -Name 'retired'
        $script:finalRoomVersion = [long]$room.version
        $beds = Get-SmokeBeds
        $script:retiredBedCount = @($beds | Where-Object {
                Test-SmokeEnumValue -Value $_.status -NumericValue 2 -Name 'retired'
            }).Count
        $script:bedVersionsAdvanced = $beds.Count -eq 2 -and
            @($beds | Where-Object { [long]$_.version -gt 1 }).Count -eq 2
    }

    $property = Get-SmokeProperty
    if (Test-SmokeEnumValue -Value $property.status -NumericValue 1 -Name 'active') {
        if ($propertyRetirementExpectedVersion -le 0) {
            $script:propertyRetirementExpectedVersion = [long]$property.version
        }
        $retired = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($propertyId.ToString('D'))/retire" `
                -Method POST `
                -Body ([ordered]@{
                    operationId = $propertyRetirementOperationId.ToString('D')
                    confirmed = $true
                    expectedVersion = $propertyRetirementExpectedVersion
                })) `
            -ExpectedStatus 200 `
            -Operation 'Retire synthetic property during cleanup'
        $script:finalPropertyVersion = [long]$retired.version
    }

    $property = Get-SmokeProperty
    $script:propertyRetired = Test-SmokeEnumValue -Value $property.status -NumericValue 2 -Name 'retired'
    $script:finalPropertyVersion = [long]$property.version
    $script:topologyRetirementsCompleted = $script:roomRetired -and
        $script:retiredBedCount -eq 2
}

$workflowError = $null
$cleanupErrors = [Collections.Generic.List[string]]::new()
try {
    try {
        $releaseIdBefore = Assert-BunkFyPublicApiReleaseIdentity `
            -Client $client `
            -Origin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -TimeoutSeconds $RequestTimeoutSeconds
        Get-SmokeWorkspaceMembership
        $checks.Add([ordered]@{ name = 'scoped-operator-preflight'; status = 'passed' })

        $deniedDirectory = Invoke-SmokeApi `
            -Path '/api/properties?page=1&pageSize=1' `
            -Method GET `
            -Body $null `
            -Token $deniedToken
        Assert-BunkFyAuthenticatedStatus `
            -Response $deniedDirectory `
            -ExpectedStatus 403 `
            -Operation 'Nonmember property directory read'
        Clear-SmokeResponseBody -Response $deniedDirectory
        $checks.Add([ordered]@{ name = 'nonmember-property-directory-denied'; status = 'passed' })

        if (-not $PSCmdlet.ShouldProcess(
                "workspace $($WorkspaceId.ToString('D'))",
                'Create, mutate, and retire synthetic property topology')) {
            return
        }

        $propertyCreateAttempted = $true
        $createdProperty = Read-SmokeJson `
            -Response (Invoke-SmokePropertyCreate `
                -Name $initialPropertyName `
                -Code $initialPropertyCode) `
            -ExpectedStatus 200 `
            -Operation 'Create synthetic property'
        Assert-SmokePropertyReceipt -Receipt $createdProperty -Status 1 -Version 1 -Operation 'Synthetic property creation'
        $initialPropertyVersion = 1
        $checks.Add([ordered]@{ name = 'property-created'; status = 'passed' })

        $createPropertyReplay = Read-SmokeJson `
            -Response (Invoke-SmokePropertyCreate `
                -Name $initialPropertyName `
                -Code $initialPropertyCode) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic property creation'
        Assert-SmokePropertyReceiptReplay -Original $createdProperty -Replay $createPropertyReplay -Operation 'Exact property create replay'
        $checks.Add([ordered]@{ name = 'property-create-replay-stable'; status = 'passed' })

        $createPropertyConflict = Invoke-SmokePropertyCreate `
            -Name "$initialPropertyName conflict" `
            -Code $initialPropertyCode
        Assert-SmokeProblem -Response $createPropertyConflict -ExpectedStatus 409 -ExpectedCode 'Properties.CreationOperationConflict' -Operation 'Conflicting property creation operation reuse'
        $checks.Add([ordered]@{ name = 'property-create-conflict-rejected'; status = 'passed' })

        $property = Get-SmokeProperty
        $propertyDirectory = Get-SmokePropertyDirectoryMatch
        if ([string]$property.name -cne $initialPropertyName -or
            [string]$property.code -cne $initialPropertyCode -or
            [string]$property.timeZoneId -cne 'UTC' -or
            [long]$property.version -ne 1 -or
            -not (Test-SmokeEnumValue -Value $property.status -NumericValue 1 -Name 'active') -or
            [string]$propertyDirectory.name -cne $initialPropertyName -or
            [long]$propertyDirectory.version -ne 1) {
            throw 'The property detail and directory did not expose the created topology root.'
        }
        $checks.Add([ordered]@{ name = 'property-detail-and-directory-visible'; status = 'passed' })

        $updatedProperty = Read-SmokeJson `
            -Response (Invoke-SmokePropertyUpdate `
                -OperationId $updatePropertyOperationId `
                -Name $updatedPropertyName `
                -Code $updatedPropertyCode `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Update synthetic property'
        Assert-SmokePropertyReceipt -Receipt $updatedProperty -Status 1 -Version 2 -Operation 'Synthetic property update'
        $checks.Add([ordered]@{ name = 'property-versioned-update-recorded'; status = 'passed' })

        $updatedPropertyReplay = Read-SmokeJson `
            -Response (Invoke-SmokePropertyUpdate `
                -OperationId $updatePropertyOperationId `
                -Name $updatedPropertyName `
                -Code $updatedPropertyCode `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic property update'
        Assert-SmokePropertyReceiptReplay -Original $updatedProperty -Replay $updatedPropertyReplay -Operation 'Exact property update replay'
        $checks.Add([ordered]@{ name = 'property-update-replay-stable'; status = 'passed' })

        $propertyUpdateConflict = Invoke-SmokePropertyUpdate `
            -OperationId $updatePropertyOperationId `
            -Name "$updatedPropertyName conflict" `
            -Code $updatedPropertyCode `
            -ExpectedVersion 1
        Assert-SmokeProblem -Response $propertyUpdateConflict -ExpectedStatus 409 -ExpectedCode 'Properties.ManagementOperationConflict' -Operation 'Conflicting property update operation reuse'
        $propertyStaleUpdate = Invoke-SmokePropertyUpdate `
            -OperationId ([Guid]::NewGuid()) `
            -Name $updatedPropertyName `
            -Code $updatedPropertyCode `
            -ExpectedVersion 1
        Assert-SmokeProblem -Response $propertyStaleUpdate -ExpectedStatus 409 -ExpectedCode 'Properties.VersionConflict' -Operation 'Stale property update'
        $checks.Add([ordered]@{ name = 'property-update-conflict-and-stale-write-rejected'; status = 'passed' })

        $property = Get-SmokeProperty
        if ([string]$property.name -cne $updatedPropertyName -or
            [string]$property.code -cne $updatedPropertyCode -or
            [long]$property.version -ne 2) {
            throw 'The property detail did not expose the committed update.'
        }
        $checks.Add([ordered]@{ name = 'property-update-visible'; status = 'passed' })

        $createdRoom = Read-SmokeJson `
            -Response (Invoke-SmokeRoomCreate -Name $initialRoomName) `
            -ExpectedStatus 200 `
            -Operation 'Create synthetic room'
        if ([Guid]$createdRoom.propertyId -ne $propertyId -or
            [Guid]$createdRoom.roomId -eq [Guid]::Empty -or
            -not (Test-SmokeEnumValue -Value $createdRoom.status -NumericValue 1 -Name 'active') -or
            [long]$createdRoom.version -ne 1) {
            throw 'Synthetic room creation returned an unexpected receipt.'
        }
        $roomId = [Guid]$createdRoom.roomId
        $initialRoomVersion = 1
        $checks.Add([ordered]@{ name = 'room-created'; status = 'passed' })

        $createdRoomReplay = Read-SmokeJson `
            -Response (Invoke-SmokeRoomCreate -Name $initialRoomName) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic room creation'
        Assert-SmokeRoomReceiptReplay -Original $createdRoom -Replay $createdRoomReplay -Operation 'Exact room create replay'
        $roomCreateConflict = Invoke-SmokeRoomCreate -Name "$initialRoomName conflict"
        Assert-SmokeProblem -Response $roomCreateConflict -ExpectedStatus 409 -ExpectedCode 'Properties.ManagementOperationConflict' -Operation 'Conflicting room creation operation reuse'
        $checks.Add([ordered]@{ name = 'room-create-replay-stable-and-conflict-rejected'; status = 'passed' })

        $updatedRoom = Read-SmokeJson `
            -Response (Invoke-SmokeRoomUpdate `
                -OperationId $updateRoomOperationId `
                -Name $updatedRoomName `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Update synthetic room'
        if ([Guid]$updatedRoom.roomId -ne $roomId -or
            [long]$updatedRoom.version -ne 2 -or
            -not (Test-SmokeEnumValue -Value $updatedRoom.status -NumericValue 1 -Name 'active')) {
            throw 'Synthetic room update returned an unexpected receipt.'
        }
        $checks.Add([ordered]@{ name = 'room-versioned-update-recorded'; status = 'passed' })

        $updatedRoomReplay = Read-SmokeJson `
            -Response (Invoke-SmokeRoomUpdate `
                -OperationId $updateRoomOperationId `
                -Name $updatedRoomName `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic room update'
        Assert-SmokeRoomReceiptReplay -Original $updatedRoom -Replay $updatedRoomReplay -Operation 'Exact room update replay'
        $roomUpdateConflict = Invoke-SmokeRoomUpdate `
            -OperationId $updateRoomOperationId `
            -Name "$updatedRoomName conflict" `
            -ExpectedVersion 1
        Assert-SmokeProblem -Response $roomUpdateConflict -ExpectedStatus 409 -ExpectedCode 'Properties.ManagementOperationConflict' -Operation 'Conflicting room update operation reuse'
        $roomStaleUpdate = Invoke-SmokeRoomUpdate `
            -OperationId ([Guid]::NewGuid()) `
            -Name $updatedRoomName `
            -ExpectedVersion 1
        Assert-SmokeProblem -Response $roomStaleUpdate -ExpectedStatus 409 -ExpectedCode 'Properties.VersionConflict' -Operation 'Stale room update'
        $checks.Add([ordered]@{ name = 'room-update-replay-conflict-and-stale-write-enforced'; status = 'passed' })

        $room = Get-SmokeRoom
        $roomDirectory = Get-SmokeRoomDirectoryMatch
        if ([string]$room.name -cne $updatedRoomName -or
            [string]$room.buildingLabel -cne $buildingLabel -or
            [string]$room.floorLabel -cne $floorLabel -or
            [long]$room.version -ne 2 -or
            [string]$roomDirectory.name -cne $updatedRoomName -or
            [long]$roomDirectory.version -ne 2) {
            throw 'The room detail and directory did not expose the committed update.'
        }
        $checks.Add([ordered]@{ name = 'room-detail-and-directory-visible'; status = 'passed' })

        $bedBatch = Read-SmokeJson `
            -Response (Invoke-SmokeBedBatch -Labels $bedLabels) `
            -ExpectedStatus 200 `
            -Operation 'Add synthetic bed batch'
        if ([Guid]$bedBatch.propertyId -ne $propertyId -or
            [Guid]$bedBatch.roomId -ne $roomId -or
            [int]$bedBatch.affectedBedCount -ne 2 -or
            [long]$bedBatch.roomVersion -ne 4) {
            throw 'The synthetic bed batch did not advance the room atomically.'
        }
        $checks.Add([ordered]@{ name = 'bed-batch-created-atomically'; status = 'passed' })

        $bedBatchReplay = Read-SmokeJson `
            -Response (Invoke-SmokeBedBatch -Labels $bedLabels) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic bed batch'
        if ([Guid]$bedBatchReplay.propertyId -ne $propertyId -or
            [Guid]$bedBatchReplay.roomId -ne $roomId -or
            [int]$bedBatchReplay.affectedBedCount -ne 2 -or
            [long]$bedBatchReplay.roomVersion -ne 4) {
            throw 'The exact bed-batch replay did not return the stable receipt.'
        }
        $bedBatchConflict = Invoke-SmokeBedBatch -Labels @($bedLabels[0], "$($bedLabels[1])-conflict")
        Assert-SmokeProblem -Response $bedBatchConflict -ExpectedStatus 409 -ExpectedCode 'Properties.ManagementOperationConflict' -Operation 'Conflicting bed batch operation reuse'
        $checks.Add([ordered]@{ name = 'bed-batch-replay-stable-and-conflict-rejected'; status = 'passed' })

        $beds = @(Get-SmokeBeds)
        if ($beds.Count -ne 2 -or
            @($beds | Where-Object {
                    [string]$_.label -cin $bedLabels -and
                    (Test-SmokeEnumValue -Value $_.status -NumericValue 1 -Name 'active') -and
                    [long]$_.version -eq 1 -and
                    [long]$_.roomVersion -eq 4
                }).Count -ne 2) {
            throw 'The bed directory did not expose the complete atomic batch.'
        }
        foreach ($bed in @($beds | Sort-Object label)) {
            [void]$bedIds.Add([Guid]$bed.bedId)
        }
        $checks.Add([ordered]@{ name = 'bed-directory-visible'; status = 'passed' })

        $updatedBed = Read-SmokeJson `
            -Response (Invoke-SmokeBedUpdate `
                -OperationId $updateBedOperationId `
                -BedId $bedIds[0] `
                -Label $updatedBedLabel `
                -ExpectedVersion 4) `
            -ExpectedStatus 200 `
            -Operation 'Update synthetic bed'
        if ([Guid]$updatedBed.bedId -ne $bedIds[0] -or
            [long]$updatedBed.version -ne 2 -or
            [long]$updatedBed.roomVersion -ne 5 -or
            -not (Test-SmokeEnumValue -Value $updatedBed.status -NumericValue 1 -Name 'active')) {
            throw 'Synthetic bed update returned an unexpected receipt.'
        }
        $checks.Add([ordered]@{ name = 'bed-versioned-update-recorded'; status = 'passed' })

        $updatedBedReplay = Read-SmokeJson `
            -Response (Invoke-SmokeBedUpdate `
                -OperationId $updateBedOperationId `
                -BedId $bedIds[0] `
                -Label $updatedBedLabel `
                -ExpectedVersion 4) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic bed update'
        Assert-SmokeBedReceiptReplay -Original $updatedBed -Replay $updatedBedReplay -Operation 'Exact bed update replay'
        $bedUpdateConflict = Invoke-SmokeBedUpdate `
            -OperationId $updateBedOperationId `
            -BedId $bedIds[0] `
            -Label "$updatedBedLabel-conflict" `
            -ExpectedVersion 4
        Assert-SmokeProblem -Response $bedUpdateConflict -ExpectedStatus 409 -ExpectedCode 'Properties.ManagementOperationConflict' -Operation 'Conflicting bed update operation reuse'
        $bedStaleUpdate = Invoke-SmokeBedUpdate `
            -OperationId ([Guid]::NewGuid()) `
            -BedId $bedIds[0] `
            -Label $updatedBedLabel `
            -ExpectedVersion 4
        Assert-SmokeProblem -Response $bedStaleUpdate -ExpectedStatus 409 -ExpectedCode 'Properties.VersionConflict' -Operation 'Stale bed update'
        $checks.Add([ordered]@{ name = 'bed-update-replay-conflict-and-stale-write-enforced'; status = 'passed' })

        $beds = @(Get-SmokeBeds)
        $updatedBedMatches = @($beds | Where-Object {
                [Guid]$_.bedId -eq $bedIds[0] -and
                [string]$_.label -ceq $updatedBedLabel -and
                [long]$_.version -eq 2 -and
                [long]$_.roomVersion -eq 5
            })
        if ($beds.Count -ne 2 -or $updatedBedMatches.Count -ne 1) {
            throw 'The bed directory did not expose the committed update.'
        }
        $checks.Add([ordered]@{ name = 'bed-update-visible'; status = 'passed' })

        $property = Get-SmokeProperty
        $propertyRetirementExpectedVersion = [long]$property.version
        $blockedPropertyRetirement = Invoke-SmokeApi `
            -Path "/api/properties/$($propertyId.ToString('D'))/retire" `
            -Method POST `
            -Body ([ordered]@{
                operationId = $propertyRetirementOperationId.ToString('D')
                confirmed = $true
                expectedVersion = $propertyRetirementExpectedVersion
            })
        Assert-SmokeProblem -Response $blockedPropertyRetirement -ExpectedStatus 409 -ExpectedCode 'Properties.PropertyHasActiveRooms' -Operation 'Property retirement with active room'
        $checks.Add([ordered]@{ name = 'property-retirement-blocked-by-active-room'; status = 'passed' })

        $directBedRetirement = Invoke-SmokeApi `
            -Path "/api/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))/beds/$($bedIds[0].ToString('D'))/retire" `
            -Method POST `
            -Body ([ordered]@{ confirmed = $true; expectedRoomVersion = 5 })
        Assert-SmokeProblem -Response $directBedRetirement -ExpectedStatus 409 -ExpectedCode 'Properties.BedRetirementRequiresInventory' -Operation 'Direct bed retirement'
        $directRoomRetirement = Invoke-SmokeApi `
            -Path "/api/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))/retire" `
            -Method POST `
            -Body ([ordered]@{ confirmed = $true; expectedVersion = 5; cascadeBeds = $true })
        Assert-SmokeProblem -Response $directRoomRetirement -ExpectedStatus 409 -ExpectedCode 'Properties.RoomRetirementRequiresInventory' -Operation 'Direct room retirement'
        $directRetirementDenied = $true
        $checks.Add([ordered]@{ name = 'direct-topology-retirement-requires-inventory'; status = 'passed' })

        $bedRetirementRequested = $true
        $bedRetirement = Invoke-SmokeRetirementRequest `
            -Kind bed `
            -OperationId $bedRetirementOperationId `
            -Reason $bedRetirementReason `
            -AllowConvergence
        $bedRetirementId = [Guid]$bedRetirement.topologyChangeId
        if ($bedRetirementId -eq [Guid]::Empty -or
            [Guid]$bedRetirement.bedId -ne $bedIds[0]) {
            throw 'The bed retirement request returned an invalid process.'
        }
        $bedRetirementReplay = Invoke-SmokeRetirementRequest `
            -Kind bed `
            -OperationId $bedRetirementOperationId `
            -Reason $bedRetirementReason
        Assert-SmokeRetirementReplay -Original $bedRetirement -Replay $bedRetirementReplay -Kind bed
        $checks.Add([ordered]@{ name = 'bed-retirement-request-replay-stable'; status = 'passed' })

        [void](Wait-SmokeRetirementCompleted -Kind bed -TopologyChangeId $bedRetirementId)
        $beds = @(Get-SmokeBeds)
        if (@($beds | Where-Object {
                    [Guid]$_.bedId -eq $bedIds[0] -and
                    (Test-SmokeEnumValue -Value $_.status -NumericValue 2 -Name 'retired')
                }).Count -ne 1 -or
            @($beds | Where-Object {
                    [Guid]$_.bedId -eq $bedIds[1] -and
                    (Test-SmokeEnumValue -Value $_.status -NumericValue 1 -Name 'active')
                }).Count -ne 1) {
            throw 'Bed retirement did not retire exactly the selected bed.'
        }
        $checks.Add([ordered]@{ name = 'bed-retirement-completed'; status = 'passed' })

        $roomRetirementRequested = $true
        $roomRetirement = Invoke-SmokeRetirementRequest `
            -Kind room `
            -OperationId $roomRetirementOperationId `
            -Reason $roomRetirementReason `
            -AllowConvergence
        $roomRetirementId = [Guid]$roomRetirement.topologyChangeId
        if ($roomRetirementId -eq [Guid]::Empty) {
            throw 'The room retirement request returned an invalid process.'
        }
        $roomRetirementReplay = Invoke-SmokeRetirementRequest `
            -Kind room `
            -OperationId $roomRetirementOperationId `
            -Reason $roomRetirementReason
        Assert-SmokeRetirementReplay -Original $roomRetirement -Replay $roomRetirementReplay -Kind room
        $checks.Add([ordered]@{ name = 'room-retirement-request-replay-stable'; status = 'passed' })

        [void](Wait-SmokeRetirementCompleted -Kind room -TopologyChangeId $roomRetirementId)
        $room = Get-SmokeRoom
        $beds = @(Get-SmokeBeds)
        if (-not (Test-SmokeEnumValue -Value $room.status -NumericValue 2 -Name 'retired') -or
            $null -eq $room.retiredAtUtc -or
            $beds.Count -ne 2 -or
            @($beds | Where-Object {
                    Test-SmokeEnumValue -Value $_.status -NumericValue 2 -Name 'retired'
                }).Count -ne 2) {
            throw 'Room retirement did not retire the room and all owned beds.'
        }
        $roomRetired = $true
        $finalRoomVersion = [long]$room.version
        $retiredBedCount = 2
        $bedVersionsAdvanced = @($beds | Where-Object { [long]$_.version -gt 1 }).Count -eq 2
        $topologyRetirementsCompleted = $true
        $checks.Add([ordered]@{ name = 'room-and-beds-retirement-completed'; status = 'passed' })

        $retiredProperty = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($propertyId.ToString('D'))/retire" `
                -Method POST `
                -Body ([ordered]@{
                    operationId = $propertyRetirementOperationId.ToString('D')
                    confirmed = $true
                    expectedVersion = $propertyRetirementExpectedVersion
                })) `
            -ExpectedStatus 200 `
            -Operation 'Retire synthetic property'
        Assert-SmokePropertyReceipt -Receipt $retiredProperty -Status 2 -Version ($propertyRetirementExpectedVersion + 1) -Operation 'Synthetic property retirement'
        $propertyRetired = $true
        $finalPropertyVersion = [long]$retiredProperty.version
        $retiredPropertyReplay = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($propertyId.ToString('D'))/retire" `
                -Method POST `
                -Body ([ordered]@{
                    operationId = $propertyRetirementOperationId.ToString('D')
                    confirmed = $true
                    expectedVersion = $propertyRetirementExpectedVersion
                })) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic property retirement'
        Assert-SmokePropertyReceiptReplay -Original $retiredProperty -Replay $retiredPropertyReplay -Operation 'Exact property retirement replay'
        $checks.Add([ordered]@{ name = 'property-retirement-replay-stable'; status = 'passed' })

        $propertyRetirementConflict = Invoke-SmokeApi `
            -Path "/api/properties/$($propertyId.ToString('D'))/retire" `
            -Method POST `
            -Body ([ordered]@{
                operationId = $propertyRetirementOperationId.ToString('D')
                confirmed = $true
                expectedVersion = $propertyRetirementExpectedVersion - 1
            })
        Assert-SmokeProblem -Response $propertyRetirementConflict -ExpectedStatus 409 -ExpectedCode 'Properties.ManagementOperationConflict' -Operation 'Conflicting property retirement operation reuse'
        $checks.Add([ordered]@{ name = 'property-retirement-conflict-rejected'; status = 'passed' })

        $property = Get-SmokeProperty
        $propertyDirectory = Get-SmokePropertyDirectoryMatch
        $roomDirectory = Get-SmokeRoomDirectoryMatch
        $processing = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($propertyId.ToString('D'))/processing" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read retired property processing state'
        if (-not (Test-SmokeEnumValue -Value $property.status -NumericValue 2 -Name 'retired') -or
            [long]$property.version -ne $finalPropertyVersion -or
            $null -eq $property.retiredAtUtc -or
            -not (Test-SmokeEnumValue -Value $propertyDirectory.status -NumericValue 2 -Name 'retired') -or
            -not (Test-SmokeEnumValue -Value $roomDirectory.status -NumericValue 2 -Name 'retired') -or
            -not (Test-SmokeEnumValue -Value $processing.configuredStatus -NumericValue 1 -Name 'unconfigured') -or
            -not (Test-SmokeEnumValue -Value $processing.effectiveStatus -NumericValue 3 -Name 'suspended') -or
            [string]$processing.reasonCode -cne 'Properties.PropertyRetired' -or
            $null -ne $processing.governancePolicy -or
            [long]$processing.propertyVersion -ne $finalPropertyVersion) {
            throw 'The retired property topology and effective processing state are inconsistent.'
        }
        $checks.Add([ordered]@{ name = 'retired-topology-directories-and-processing-consistent'; status = 'passed' })

        $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
            -Client $client `
            -Origin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -TimeoutSeconds $RequestTimeoutSeconds
        if ($observedReleaseId -cne $releaseIdBefore) {
            throw 'The public API release identity changed during Properties topology verification.'
        }
        $checks.Add([ordered]@{ name = 'release-identity-continuous'; status = 'passed' })
    }
    catch {
        $workflowError = $_.Exception
    }
    finally {
        try {
            Complete-SmokePropertiesCleanup
        }
        catch {
            $cleanupErrors.Add("properties-topology: $($_.Exception.Message)")
        }
    }
}
finally {
    $client.Dispose()
    $operatorToken = $null
    $deniedToken = $null
    $initialPropertyName = $null
    $updatedPropertyName = $null
    $initialRoomName = $null
    $updatedRoomName = $null
    $buildingLabel = $null
    $floorLabel = $null
    $bedLabels = $null
    $updatedBedLabel = $null
    $bedRetirementReason = $null
    $roomRetirementReason = $null
}

if ($cleanupErrors.Count -gt 0) {
    $cleanupSummary = $cleanupErrors -join '; '
    if ($null -ne $workflowError) {
        throw "Properties topology workflow failed: $($workflowError.Message) Cleanup also failed: $cleanupSummary"
    }
    throw "Properties topology workflow cleanup failed: $cleanupSummary"
}
if ($null -ne $workflowError) {
    throw $workflowError
}
if (-not $propertyRetired -or
    -not $roomRetired -or
    $retiredBedCount -ne 2 -or
    -not $topologyRetirementsCompleted) {
    throw 'Properties topology verification did not reach its required terminal cleanup state.'
}
if ($checks.Count -ne 31) {
    throw "Properties topology verification recorded $($checks.Count) checks; expected 31."
}

$evidence = [ordered]@{
    schemaVersion = 1
    evidenceKind = 'bunkfy-deployed-properties-topology-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-fixture' }
    result = 'passed'
    workflow = [ordered]@{
        propertyFinalStatus = 'retired'
        propertyVersionAdvanced = $finalPropertyVersion -gt $initialPropertyVersion
        processingFinalStatus = 'suspended-by-retirement'
        roomFinalStatus = 'retired'
        roomVersionAdvanced = $finalRoomVersion -gt $initialRoomVersion
        bedCount = 2
        retiredBedCount = $retiredBedCount
        bedVersionsAdvanced = $bedVersionsAdvanced
        retirementLifecycle = 'bed-then-room-completed'
        directRetirementDenied = $directRetirementDenied
    }
    cleanup = [ordered]@{
        propertyDisposition = 'synthetic-retired-retained'
        roomDisposition = 'synthetic-retired-retained'
        activeBedCount = 0
        topologyRetirementsCompleted = $topologyRetirementsCompleted
        parentCleanupRequired = $false
    }
    checks = @($checks)
    limitations = @(
        'browser-properties-workflow-not-exercised',
        'country-policy-activation-suspension-and-rebinding-not-exercised',
        'occupied-and-blocked-topology-drain-not-exercised',
        'synthetic-retired-topology-retained'
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

Write-Host "BunkFy deployed Properties topology verification passed for '$ExpectedReleaseId'."
Write-Host "Evidence: $OutputPath"
