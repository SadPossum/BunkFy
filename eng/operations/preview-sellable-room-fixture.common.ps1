Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-BunkFyPreviewFixtureEnumValue {
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][int] $NumericValue,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $text = [string]$Value
    return $text -ceq [string]$NumericValue -or
        $text.Equals($Name, [StringComparison]::OrdinalIgnoreCase)
}

function Get-BunkFyPreviewSellableRoomFixture {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $InvokeApi,
        [Parameter(Mandatory = $true)][Guid] $PropertyId,
        [Parameter(Mandatory = $true)][Guid] $RoomId
    )

    $page = 1
    do {
        $response = & $InvokeApi `
            -Path "/api/inventory/properties/$($PropertyId.ToString('D'))/rooms?page=$page&pageSize=100" `
            -Method 'GET' `
            -Body $null `
            -Operation 'Read preview sellable-room fixture Inventory topology' `
            -AllowNotFound
        if ($null -eq $response) {
            return $null
        }
        $matches = @($response.rooms | Where-Object { [Guid]$_.roomId -eq $RoomId })
        if ($matches.Count -gt 1) {
            throw 'The preview sellable-room fixture was projected more than once.'
        }
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
        $page++
        if ($page -gt 100) {
            throw 'Preview sellable-room fixture Inventory lookup exceeded 100 pages.'
        }
    } while ([bool]$response.hasMore)

    return $null
}

function Wait-BunkFyPreviewSellableRoomFixture {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $InvokeApi,
        [Parameter(Mandatory = $true)][Guid] $PropertyId,
        [Parameter(Mandatory = $true)][Guid] $RoomId,
        [Parameter(Mandatory = $true)][ValidateSet('unconfigured', 'sellable')][string] $State,
        [ValidateRange(1, 600)][int] $ConvergenceTimeoutSeconds = 180,
        [ValidateRange(1, 5000)][int] $PollIntervalMilliseconds = 1000
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $room = Get-BunkFyPreviewSellableRoomFixture `
            -InvokeApi $InvokeApi `
            -PropertyId $PropertyId `
            -RoomId $RoomId
        if ($null -ne $room) {
            $units = @($room.units)
            $validRoomUnit = $units.Count -eq 1 -and
                [Guid]$units[0].inventoryUnitId -ne [Guid]::Empty -and
                [Guid]$units[0].propertyId -eq $PropertyId -and
                [Guid]$units[0].roomId -eq $RoomId -and
                $null -eq $units[0].bedId -and
                (Test-BunkFyPreviewFixtureEnumValue `
                    -Value $units[0].kind `
                    -NumericValue 1 `
                    -Name 'room') -and
                [bool]$units[0].isTopologyActive
            if (-not $validRoomUnit) {
                throw 'The preview sellable-room fixture did not project exactly one active room unit.'
            }

            if ($State -ceq 'unconfigured' -and
                (Test-BunkFyPreviewFixtureEnumValue `
                    -Value $room.salesMode `
                    -NumericValue 1 `
                    -Name 'unconfigured') -and
                -not [bool]$units[0].isSellable) {
                return $room
            }
            if ($State -ceq 'sellable' -and
                (Test-BunkFyPreviewFixtureEnumValue `
                    -Value $room.salesMode `
                    -NumericValue 2 `
                    -Name 'roomLevel') -and
                [bool]$units[0].isSellable) {
                return $room
            }
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "The preview sellable-room fixture did not reach '$State' Inventory state before the timeout."
}

function New-BunkFyPreviewSellableRoomFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock] $InvokeApi,
        [Parameter(Mandatory = $true)][Guid] $PropertyId,
        [Parameter(Mandatory = $true)][ValidateLength(1, 128)][string] $RoomName,
        [Parameter(Mandatory = $true)][ref] $State,
        [ValidateRange(1, 600)][int] $ConvergenceTimeoutSeconds = 180,
        [ValidateRange(1, 5000)][int] $PollIntervalMilliseconds = 1000
    )

    if ($PropertyId -eq [Guid]::Empty) {
        throw 'A non-empty property id is required for the preview sellable-room fixture.'
    }
    if ($null -ne $State.Value) {
        throw 'Preview sellable-room fixture state must be empty before provisioning.'
    }

    $property = & $InvokeApi `
        -Path "/api/properties/$($PropertyId.ToString('D'))" `
        -Method 'GET' `
        -Body $null `
        -Operation 'Read preview sellable-room fixture property'
    if ([Guid]$property.propertyId -ne $PropertyId -or
        -not (Test-BunkFyPreviewFixtureEnumValue `
            -Value $property.status `
            -NumericValue 1 `
            -Name 'active') -or
        [long]$property.version -lt 1) {
        throw 'The preview sellable-room fixture property is not active and versioned.'
    }

    $created = & $InvokeApi `
        -Path "/api/properties/$($PropertyId.ToString('D'))/rooms" `
        -Method 'POST' `
        -Body @{
            operationId = [Guid]::NewGuid()
            name = $RoomName
            expectedPropertyVersion = [long]$property.version
            buildingLabel = 'Preview verification'
            floorLabel = $null
        } `
        -Operation 'Create preview sellable-room fixture'
    if ([Guid]$created.propertyId -ne $PropertyId -or
        [Guid]$created.roomId -eq [Guid]::Empty -or
        [long]$created.version -lt 1) {
        throw 'The preview sellable-room fixture returned an invalid receipt.'
    }

    $fixture = [pscustomobject]@{
        PropertyId = $PropertyId
        RoomId = [Guid]$created.roomId
        InventoryUnitId = [Guid]::Empty
        TopologyChangeId = [Guid]::Empty
        Status = 'room-created'
    }
    $State.Value = $fixture

    $unconfigured = Wait-BunkFyPreviewSellableRoomFixture `
        -InvokeApi $InvokeApi `
        -PropertyId $PropertyId `
        -RoomId $fixture.RoomId `
        -State 'unconfigured' `
        -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
        -PollIntervalMilliseconds $PollIntervalMilliseconds
    $unit = @($unconfigured.units)[0]
    $fixture.InventoryUnitId = [Guid]$unit.inventoryUnitId
    $fixture.Status = 'inventory-projected'

    $configured = & $InvokeApi `
        -Path "/api/inventory/properties/$($PropertyId.ToString('D'))/rooms/$($fixture.RoomId.ToString('D'))/sales-mode" `
        -Method 'PUT' `
        -Body @{
            operationId = [Guid]::NewGuid()
            salesMode = 2
            expectedVersion = [long]$unconfigured.version
        } `
        -Operation 'Configure preview sellable-room fixture sales mode'
    if ([Guid]$configured.propertyId -ne $PropertyId -or
        [Guid]$configured.roomId -ne $fixture.RoomId -or
        -not (Test-BunkFyPreviewFixtureEnumValue `
            -Value $configured.salesMode `
            -NumericValue 2 `
            -Name 'roomLevel') -or
        [long]$configured.version -le [long]$unconfigured.version) {
        throw 'The preview sellable-room fixture sales-mode receipt is invalid.'
    }

    $sellable = Wait-BunkFyPreviewSellableRoomFixture `
        -InvokeApi $InvokeApi `
        -PropertyId $PropertyId `
        -RoomId $fixture.RoomId `
        -State 'sellable' `
        -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
        -PollIntervalMilliseconds $PollIntervalMilliseconds
    $sellableUnit = @($sellable.units)[0]
    if ([Guid]$sellableUnit.inventoryUnitId -ne $fixture.InventoryUnitId) {
        throw 'The preview sellable-room fixture changed inventory-unit identity while configuring sales.'
    }

    $fixture.Status = 'ready'
    return $fixture
}

function Remove-BunkFyPreviewSellableRoomFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock] $InvokeApi,
        [Parameter(Mandatory = $true)][object] $Fixture,
        [ValidateRange(1, 600)][int] $ConvergenceTimeoutSeconds = 180,
        [ValidateRange(1, 5000)][int] $PollIntervalMilliseconds = 1000
    )

    $propertyId = [Guid]$Fixture.PropertyId
    $roomId = [Guid]$Fixture.RoomId
    if ($propertyId -eq [Guid]::Empty -or $roomId -eq [Guid]::Empty) {
        throw 'The preview sellable-room fixture cannot retire an unknown room coordinate.'
    }
    if ([string]$Fixture.Status -ceq 'retired') {
        return $Fixture
    }

    if ([Guid]$Fixture.TopologyChangeId -eq [Guid]::Empty) {
        if ([string]$Fixture.Status -ceq 'room-created') {
            [void](Wait-BunkFyPreviewSellableRoomFixture `
                    -InvokeApi $InvokeApi `
                    -PropertyId $propertyId `
                    -RoomId $roomId `
                    -State 'unconfigured' `
                    -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
                    -PollIntervalMilliseconds $PollIntervalMilliseconds)
        }
        $retirement = & $InvokeApi `
            -Path "/api/inventory/properties/$($propertyId.ToString('D'))/rooms/$($roomId.ToString('D'))/retirement" `
            -Method 'POST' `
            -Body @{
                operationId = [Guid]::NewGuid()
                confirmed = $true
                reason = 'Preview sellable-room fixture cleanup'
            } `
            -Operation 'Request preview sellable-room fixture retirement'
        if ([Guid]$retirement.propertyId -ne $propertyId -or
            [Guid]$retirement.roomId -ne $roomId -or
            [Guid]$retirement.topologyChangeId -eq [Guid]::Empty) {
            throw 'The preview sellable-room fixture retirement receipt is invalid.'
        }
        $Fixture.TopologyChangeId = [Guid]$retirement.topologyChangeId
        $Fixture.Status = 'retirement-requested'
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $retirement = & $InvokeApi `
            -Path "/api/inventory/properties/$($propertyId.ToString('D'))/room-retirements/$(([Guid]$Fixture.TopologyChangeId).ToString('D'))" `
            -Method 'GET' `
            -Body $null `
            -Operation 'Read preview sellable-room fixture retirement'
        if ([Guid]$retirement.propertyId -ne $propertyId -or
            [Guid]$retirement.roomId -ne $roomId -or
            [Guid]$retirement.topologyChangeId -ne [Guid]$Fixture.TopologyChangeId) {
            throw 'The preview sellable-room fixture retirement query changed identity.'
        }
        if (Test-BunkFyPreviewFixtureEnumValue `
            -Value $retirement.status `
            -NumericValue 5 `
            -Name 'rejected') {
            throw 'The preview sellable-room fixture retirement was rejected.'
        }
        if (Test-BunkFyPreviewFixtureEnumValue `
            -Value $retirement.status `
            -NumericValue 4 `
            -Name 'completed') {
            $Fixture.Status = 'retired'
            return $Fixture
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw 'The preview sellable-room fixture retirement did not complete before the timeout.'
}
