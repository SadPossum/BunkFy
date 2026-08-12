Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'operations\preview-sellable-room-fixture.common.ps1')

$propertyId = [Guid]'11111111-1111-4111-8111-111111111111'
$roomId = [Guid]'22222222-2222-4222-8222-222222222222'
$unitId = [Guid]'33333333-3333-4333-8333-333333333333'
$topologyChangeId = [Guid]'44444444-4444-4444-8444-444444444444'
$script:inventoryReads = 0
$script:retirementReads = 0
$script:configured = $false
$calls = [Collections.Generic.List[string]]::new()

$invokeApi = {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Method,
        [AllowNull()][object] $Body,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    $calls.Add("$Method $Path")
    if ($Method -ceq 'GET' -and $Path -ceq "/api/properties/$($propertyId.ToString('D'))") {
        return [pscustomobject]@{ propertyId = $propertyId; status = 'active'; version = 1 }
    }
    if ($Method -ceq 'POST' -and $Path -ceq "/api/properties/$($propertyId.ToString('D'))/rooms") {
        if ([long]$Body.expectedPropertyVersion -ne 1 -or
            [string]$Body.name -cne 'Preview room fixture') {
            throw 'Fixture room creation used an invalid request body.'
        }
        return [pscustomobject]@{ propertyId = $propertyId; roomId = $roomId; status = 'active'; version = 1 }
    }
    if ($Method -ceq 'GET' -and $Path -match '/api/inventory/.+/rooms\?') {
        $script:inventoryReads++
        if ($script:inventoryReads -eq 1) {
            return [pscustomobject]@{ rooms = @(); page = 1; pageSize = 100; hasMore = $false }
        }
        $salesMode = if ($script:configured) { 'roomLevel' } else { 'unconfigured' }
        return [pscustomobject]@{
            rooms = @([pscustomobject]@{
                    propertyId = $propertyId
                    roomId = $roomId
                    salesMode = $salesMode
                    version = if ($script:configured) { 2 } else { 1 }
                    units = @([pscustomobject]@{
                            inventoryUnitId = $unitId
                            propertyId = $propertyId
                            roomId = $roomId
                            bedId = $null
                            kind = 'room'
                            isSellable = $script:configured
                            isTopologyActive = $true
                        })
                })
            page = 1
            pageSize = 100
            hasMore = $false
        }
    }
    if ($Method -ceq 'PUT' -and $Path.EndsWith('/sales-mode', [StringComparison]::Ordinal)) {
        if ([int]$Body.salesMode -ne 2 -or [long]$Body.expectedVersion -ne 1) {
            throw 'Fixture sales-mode configuration used an invalid request body.'
        }
        $script:configured = $true
        return [pscustomobject]@{
            propertyId = $propertyId
            roomId = $roomId
            salesMode = 'roomLevel'
            version = 2
        }
    }
    if ($Method -ceq 'POST' -and $Path.EndsWith('/retirement', [StringComparison]::Ordinal)) {
        if (-not $Body.ContainsKey('confirmed') -or
            -not [bool]$Body.confirmed -or
            [Guid]$Body.operationId -eq [Guid]::Empty -or
            [string]$Body.reason -cne 'Preview sellable-room fixture cleanup') {
            throw 'Fixture room retirement used an invalid confirmation body.'
        }
        return [pscustomobject]@{
            topologyChangeId = $topologyChangeId
            propertyId = $propertyId
            roomId = $roomId
            status = 'finalizationRequested'
        }
    }
    if ($Method -ceq 'GET' -and $Path.Contains('/room-retirements/', [StringComparison]::Ordinal)) {
        $script:retirementReads++
        return [pscustomobject]@{
            topologyChangeId = $topologyChangeId
            propertyId = $propertyId
            roomId = $roomId
            status = if ($script:retirementReads -ge 2) { 'completed' } else { 'finalizedAwaitingTopology' }
        }
    }

    throw "Unexpected preview sellable-room fixture call '$Method $Path' ($Operation)."
}

$state = $null
$fixture = New-BunkFyPreviewSellableRoomFixture `
    -InvokeApi $invokeApi `
    -PropertyId $propertyId `
    -RoomName 'Preview room fixture' `
    -State ([ref]$state) `
    -ConvergenceTimeoutSeconds 2 `
    -PollIntervalMilliseconds 1
if ($null -eq $state -or
    $fixture -ne $state -or
    [Guid]$fixture.RoomId -ne $roomId -or
    [Guid]$fixture.InventoryUnitId -ne $unitId -or
    [string]$fixture.Status -cne 'ready') {
    throw 'Preview sellable-room fixture provisioning did not retain exact cleanup state.'
}

$retired = Remove-BunkFyPreviewSellableRoomFixture `
    -InvokeApi $invokeApi `
    -Fixture $fixture `
    -ConvergenceTimeoutSeconds 2 `
    -PollIntervalMilliseconds 1
if ([Guid]$retired.TopologyChangeId -ne $topologyChangeId -or
    [string]$retired.Status -cne 'retired' -or
    $script:retirementReads -ne 2) {
    throw 'Preview sellable-room fixture cleanup did not wait for coordinated room retirement.'
}

$partialState = $null
$invalidProjection = {
    param($Path, $Method, $Body, $Operation)
    if ($Method -ceq 'GET' -and $Path -ceq "/api/properties/$($propertyId.ToString('D'))") {
        return [pscustomobject]@{ propertyId = $propertyId; status = 1; version = 1 }
    }
    if ($Method -ceq 'POST') {
        return [pscustomobject]@{ propertyId = $propertyId; roomId = $roomId; version = 1 }
    }
    return [pscustomobject]@{
        rooms = @([pscustomobject]@{
                roomId = $roomId
                salesMode = 1
                version = 1
                units = @(
                    [pscustomobject]@{
                        inventoryUnitId = $unitId
                        propertyId = $propertyId
                        roomId = $roomId
                        bedId = $null
                        kind = 1
                        isSellable = $false
                        isTopologyActive = $true
                    },
                    [pscustomobject]@{
                        inventoryUnitId = [Guid]::NewGuid()
                        propertyId = $propertyId
                        roomId = $roomId
                        bedId = $null
                        kind = 1
                        isSellable = $false
                        isTopologyActive = $true
                    })
            })
        hasMore = $false
    }
}
$invalidRejected = $false
try {
    [void](New-BunkFyPreviewSellableRoomFixture `
            -InvokeApi $invalidProjection `
            -PropertyId $propertyId `
            -RoomName 'Invalid projection fixture' `
            -State ([ref]$partialState) `
            -ConvergenceTimeoutSeconds 1 `
            -PollIntervalMilliseconds 1)
}
catch {
    $invalidRejected = $_.Exception.Message.Contains(
        'exactly one active room unit',
        [StringComparison]::OrdinalIgnoreCase)
}
if (-not $invalidRejected -or
    $null -eq $partialState -or
    [Guid]$partialState.RoomId -ne $roomId) {
    throw 'Preview sellable-room fixture did not expose partial cleanup state before rejecting invalid topology.'
}

foreach ($requiredCall in @(
        "POST /api/properties/$($propertyId.ToString('D'))/rooms",
        "PUT /api/inventory/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))/sales-mode",
        "POST /api/inventory/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))/retirement")) {
    if (-not $calls.Contains($requiredCall)) {
        throw "Preview sellable-room fixture did not issue '$requiredCall'."
    }
}

Write-Host 'BunkFy Preview sellable-room fixture passed.'
