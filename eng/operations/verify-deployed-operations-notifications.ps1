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
    [Security.SecureString] $ActorAccessToken,
    [Security.SecureString] $ObserverAccessToken,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [ValidateRange(10, 300)][int] $ConvergenceTimeoutSeconds = 90,
    [ValidateRange(500, 5000)][int] $PollIntervalMilliseconds = 1000,
    [ValidateRange(1, 30)][int] $ActorExclusionObservationSeconds = 5,
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
$arrivalDate = $Arrival.Date
$departureDate = $Departure.Date
if ($arrivalDate -ge $departureDate) {
    throw 'Arrival must be before Departure.'
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
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/operations-notifications-$stamp.json"
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

$actorToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $ActorAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_NOTIFICATION_ACTOR_TOKEN' `
    -Prompt 'Notification mutation actor access token'
$observerToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $ObserverAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_NOTIFICATION_OBSERVER_TOKEN' `
    -Prompt 'Notification observer access token'
if ([string]::IsNullOrWhiteSpace($actorToken) -or
    [string]::IsNullOrWhiteSpace($observerToken)) {
    throw 'Both notification smoke access tokens are required.'
}
if ($actorToken.Equals($observerToken, [StringComparison]::Ordinal)) {
    throw 'Actor and observer access tokens must represent distinct accounts.'
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
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Deployed-Operations-Notifications-Probe/1')

$checks = [Collections.Generic.List[object]]::new()
$blockGroupId = [Guid]::Empty
$blockReleased = $false
$createdNotification = $null
$releasedNotification = $null
$historyStream = $null
$reason = "Deployment notification verification $([Guid]::NewGuid().ToString('N'))"
$createOperationId = [Guid]::NewGuid()
$releaseOperationId = [Guid]::NewGuid()

function Invoke-SmokeApi {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PUT')][string] $Method,
        [Parameter(Mandatory = $true)][string] $TenantId,
        [Parameter(Mandatory = $true)][string] $Token,
        [AllowNull()][object] $Body
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

function Get-SmokeWorkspaceMembership {
    param(
        [Parameter(Mandatory = $true)][string] $Token,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $matches = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $response = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/organizations?page=$page&pageSize=100" `
                -Method GET `
                -TenantId 'global' `
                -Token $Token `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation "List $Label workspaces"
        foreach ($item in @($response.items)) {
            if ([Guid]$item.organization.organizationId -eq $WorkspaceId) {
                $matches.Add($item.membership)
            }
        }
        $page++
        if ($page -gt 100) {
            throw "The $Label workspace preflight exceeded 100 pages."
        }
    } while ([bool]$response.hasMore)

    if ($matches.Count -ne 1 -or
        [string]$matches[0].status -cne 'active' -or
        [string]::IsNullOrWhiteSpace([string]$matches[0].subjectId)) {
        throw "The $Label must have one active membership in the target workspace."
    }

    return $matches[0]
}

function Get-SmokeNotificationPage {
    param(
        [Parameter(Mandatory = $true)][string] $Token,
        [bool] $UnreadOnly = $false
    )

    $unread = if ($UnreadOnly) { 'true' } else { 'false' }
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/notifications?page=1&pageSize=100&unreadOnly=$unread" `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $Token `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'List notification history'
}

function Get-SmokeNotificationMatches {
    param(
        [Parameter(Mandatory = $true)][string] $Token,
        [Parameter(Mandatory = $true)][Guid] $ExpectedBlockGroupId,
        [Parameter(Mandatory = $true)][string] $ExpectedName
    )

    $page = Get-SmokeNotificationPage -Token $Token
    return @($page.items | Where-Object {
            [string]$_.name -ceq $ExpectedName -and
            $null -ne $_.payload -and
            $null -ne $_.payload.PSObject.Properties['blockGroupId'] -and
            [Guid]$_.payload.blockGroupId -eq $ExpectedBlockGroupId
        })
}

function Wait-SmokeNotification {
    param(
        [Parameter(Mandatory = $true)][Guid] $ExpectedBlockGroupId,
        [Parameter(Mandatory = $true)][string] $ExpectedName
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $matches = @(Get-SmokeNotificationMatches `
                -Token $observerToken `
                -ExpectedBlockGroupId $ExpectedBlockGroupId `
                -ExpectedName $ExpectedName)
        if ($matches.Count -gt 1) {
            throw "Notification '$ExpectedName' was projected more than once."
        }
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "Notification '$ExpectedName' did not converge before the timeout."
}

function Assert-SmokeNotificationShape {
    param(
        [Parameter(Mandatory = $true)][object] $Notification,
        [Parameter(Mandatory = $true)][Guid] $ExpectedBlockGroupId,
        [Parameter(Mandatory = $true)][string] $ExpectedName,
        [Parameter(Mandatory = $true)][string] $ExpectedTitle,
        [Parameter(Mandatory = $true)][long] $AfterSequence,
        [switch] $IncludesDates
    )

    if ([Guid]$Notification.id -eq [Guid]::Empty -or
        [string]$Notification.module -cne 'inventory' -or
        [string]$Notification.name -cne $ExpectedName -or
        [int]$Notification.version -ne 1 -or
        [string]$Notification.title -cne $ExpectedTitle -or
        [long]$Notification.streamSequence -le $AfterSequence -or
        [Guid]$Notification.payload.propertyId -ne $PropertyId -or
        [Guid]$Notification.payload.blockGroupId -ne $ExpectedBlockGroupId) {
        throw "Notification '$ExpectedName' has an invalid identity or navigation payload."
    }
    $tags = @($Notification.tags | ForEach-Object { [string]$_ })
    if ($tags -cnotcontains 'delivery:web' -or $tags -cnotcontains 'domain:inventory') {
        throw "Notification '$ExpectedName' does not carry the web and inventory tags."
    }
    if ($IncludesDates -and
        ([string]$Notification.payload.arrival -cne $arrivalText -or
            [string]$Notification.payload.departure -cne $departureText)) {
        throw "Notification '$ExpectedName' does not preserve the blocked date range."
    }
}

function Open-SmokeNotificationHistoryStream {
    param([Parameter(Mandatory = $true)][long] $AfterSequence)

    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Get,
        [Uri]::new(
            $origin,
            "/api/notifications/history/stream?afterSequence=$AfterSequence"))
    $cancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($ConvergenceTimeoutSeconds * 2))
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new(
            'Bearer',
            $observerToken)
        [void]$request.Headers.TryAddWithoutValidation(
            'X-Tenant-Id',
            $WorkspaceId.ToString('D'))
        [void]$request.Headers.Accept.ParseAdd('text/event-stream')
        $response = $client.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 200 -or
            [string]$response.Content.Headers.ContentType.MediaType -cne 'text/event-stream') {
            $status = [int]$response.StatusCode
            $response.Dispose()
            throw "Notification history stream returned HTTP $status or an invalid media type."
        }
        $stream = $response.Content.ReadAsStreamAsync(
            $cancellation.Token).GetAwaiter().GetResult()
        $reader = [IO.StreamReader]::new(
            $stream,
            [Text.UTF8Encoding]::new($false, $true),
            $false,
            4096,
            $false)
        return [pscustomobject]@{
            Request = $request
            Response = $response
            Reader = $reader
            Cancellation = $cancellation
        }
    }
    catch {
        $cancellation.Dispose()
        $request.Dispose()
        throw
    }
}

function Read-SmokeStreamNotification {
    param(
        [Parameter(Mandatory = $true)][object] $Context,
        [Parameter(Mandatory = $true)][Guid] $ExpectedBlockGroupId,
        [Parameter(Mandatory = $true)][string] $ExpectedName
    )

    try {
        while (-not $Context.Cancellation.IsCancellationRequested) {
            $line = $Context.Reader.ReadLineAsync(
                $Context.Cancellation.Token).GetAwaiter().GetResult()
            if ($null -eq $line) {
                break
            }
            if (-not $line.StartsWith('data:', [StringComparison]::Ordinal)) {
                continue
            }
            $data = $line.Substring(5).TrimStart()
            if ([string]::IsNullOrWhiteSpace($data) -or $data -ceq 'null') {
                continue
            }
            try {
                $notification = $data | ConvertFrom-Json -Depth 16
            }
            catch {
                throw 'The notification history stream returned an invalid JSON data frame.'
            }
            if ([string]$notification.name -ceq $ExpectedName -and
                $null -ne $notification.payload -and
                $null -ne $notification.payload.PSObject.Properties['blockGroupId'] -and
                [Guid]$notification.payload.blockGroupId -eq $ExpectedBlockGroupId) {
                return $notification
            }
        }
    }
    catch [OperationCanceledException] {
        throw "Notification '$ExpectedName' was not observed on the live stream before the timeout."
    }

    throw "Notification '$ExpectedName' was not observed on the live stream before it ended."
}

function Close-SmokeNotificationHistoryStream {
    param([AllowNull()][object] $Context)

    if ($null -eq $Context) {
        return
    }
    $Context.Cancellation.Cancel()
    $Context.Reader.Dispose()
    $Context.Response.Dispose()
    $Context.Cancellation.Dispose()
    $Context.Request.Dispose()
}

function Get-SmokeNotificationDetail {
    param([Parameter(Mandatory = $true)][Guid] $NotificationId)

    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/notifications/$($NotificationId.ToString('D'))" `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $observerToken `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation "Read notification '$NotificationId'"
}

function Mark-SmokeNotificationRead {
    param([Parameter(Mandatory = $true)][Guid] $NotificationId)

    Assert-BunkFyAuthenticatedStatus `
        -Response (Invoke-SmokeApi `
            -Path "/api/notifications/$($NotificationId.ToString('D'))/read" `
            -Method POST `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $observerToken `
            -Body $null) `
        -ExpectedStatus 204 `
        -Operation "Mark notification '$NotificationId' read"

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $detail = Get-SmokeNotificationDetail -NotificationId $NotificationId
        if ($null -ne $detail.readAtUtc) {
            return $detail
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "Notification '$NotificationId' did not retain its read state."
}

function Release-SmokeBlockBestEffort {
    if ($blockGroupId -eq [Guid]::Empty -or $blockReleased) {
        return
    }
    try {
        $response = Invoke-SmokeApi `
            -Path "/api/inventory/properties/$($PropertyId.ToString('D'))/block-groups/$($blockGroupId.ToString('D'))/release" `
            -Method POST `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $actorToken `
            -Body @{ operationId = $releaseOperationId }
        if ($response.StatusCode -eq 200) {
            $blockReleased = $true
            return
        }
    }
    catch {
        # Preserve the original failure; the warning below carries the cleanup result.
    }
    Write-Warning "The smoke inventory block group '$blockGroupId' could not be released automatically."
}

try {
    $releaseIdBefore = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds
    $actorMembership = Get-SmokeWorkspaceMembership -Token $actorToken -Label 'actor'
    $observerMembership = Get-SmokeWorkspaceMembership -Token $observerToken -Label 'observer'
    if ([string]$actorMembership.subjectId -ceq [string]$observerMembership.subjectId) {
        throw 'Actor and observer tokens resolve to the same workspace subject.'
    }

    foreach ($identity in @(
            [pscustomobject]@{ Label = 'actor'; Token = $actorToken },
            [pscustomobject]@{ Label = 'observer'; Token = $observerToken })) {
        $property = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($PropertyId.ToString('D'))" `
                -Method GET `
                -TenantId $WorkspaceId.ToString('D') `
                -Token $identity.Token `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation "$($identity.Label) property preflight"
        if ([Guid]$property.propertyId -ne $PropertyId) {
            throw "$($identity.Label) property preflight returned a different property."
        }
    }

    [void](Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/inventory/properties/$($PropertyId.ToString('D'))/blocks?inventoryUnitId=$($InventoryUnitId.ToString('D'))&includeReleased=false&page=1&pageSize=100" `
                -Method GET `
                -TenantId $WorkspaceId.ToString('D') `
                -Token $observerToken `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Observer inventory destination preflight')

    $availability = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/inventory/properties/$($PropertyId.ToString('D'))/availability?arrival=$arrivalText&departure=$departureText" `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $actorToken `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Inventory availability preflight'
    $availableUnit = @($availability.units | Where-Object {
            [Guid]$_.unit.inventoryUnitId -eq $InventoryUnitId -and [bool]$_.isAvailable
        })
    if ($availableUnit.Count -ne 1) {
        throw 'The requested inventory unit is not uniquely available for the smoke date range.'
    }

    $observerBaseline = Get-SmokeNotificationPage -Token $observerToken
    $actorBaseline = Get-SmokeNotificationPage -Token $actorToken
    $baselineSequences = @($observerBaseline.items | ForEach-Object { [long]$_.streamSequence })
    $observerCursor = if ($baselineSequences.Count -eq 0) {
        [long]0
    }
    else {
        [long](($baselineSequences | Measure-Object -Maximum).Maximum)
    }

    $wrongWorkspaceId = [Guid]::NewGuid()
    while ($wrongWorkspaceId -eq $WorkspaceId) {
        $wrongWorkspaceId = [Guid]::NewGuid()
    }
    Assert-BunkFyAuthenticatedStatus `
        -Response (Invoke-SmokeApi `
            -Path '/api/notifications?page=1&pageSize=1' `
            -Method GET `
            -TenantId $wrongWorkspaceId.ToString('D') `
            -Token $observerToken `
            -Body $null) `
        -ExpectedStatus 403 `
        -Operation 'Reject cross-workspace notification history'

    if (-not $PSCmdlet.ShouldProcess(
            "property '$PropertyId' in workspace '$WorkspaceId'",
            "create and release an inventory block from $arrivalText through $departureText and retain its notification history")) {
        return
    }

    $checks.Add([ordered]@{ name = 'distinct-scoped-identities-preflight'; status = 'passed' })
    $checks.Add([ordered]@{ name = 'cross-workspace-history-denied'; status = 'passed' })
    $historyStream = Open-SmokeNotificationHistoryStream -AfterSequence $observerCursor

    $creation = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/inventory/properties/$($PropertyId.ToString('D'))/block-groups" `
            -Method POST `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $actorToken `
            -Body @{
                operationId = $createOperationId
                target = @{
                    kind = 5
                    buildingLabel = $null
                    floorLabel = $null
                    roomId = $null
                    inventoryUnitId = $InventoryUnitId
                }
                arrival = $arrivalText
                departure = $departureText
                reason = $reason
            }) `
        -ExpectedStatus 200 `
        -Operation 'Create smoke inventory block'
    $blockGroupId = [Guid]$creation.blockGroupId
    if ($blockGroupId -eq [Guid]::Empty -or
        [Guid]$creation.propertyId -ne $PropertyId -or
        [int]$creation.affectedBlockCount -ne 1) {
        throw 'The smoke inventory block returned an invalid receipt.'
    }

    $streamCreated = Read-SmokeStreamNotification `
        -Context $historyStream `
        -ExpectedBlockGroupId $blockGroupId `
        -ExpectedName 'manual-inventory-block-created'
    Assert-SmokeNotificationShape `
        -Notification $streamCreated `
        -ExpectedBlockGroupId $blockGroupId `
        -ExpectedName 'manual-inventory-block-created' `
        -ExpectedTitle 'Inventory blocked' `
        -AfterSequence $observerCursor `
        -IncludesDates
    $checks.Add([ordered]@{ name = 'created-notification-live-streamed'; status = 'passed' })

    $createdNotification = Wait-SmokeNotification `
        -ExpectedBlockGroupId $blockGroupId `
        -ExpectedName 'manual-inventory-block-created'
    Assert-SmokeNotificationShape `
        -Notification $createdNotification `
        -ExpectedBlockGroupId $blockGroupId `
        -ExpectedName 'manual-inventory-block-created' `
        -ExpectedTitle 'Inventory blocked' `
        -AfterSequence $observerCursor `
        -IncludesDates
    if ($null -ne $createdNotification.readAtUtc) {
        throw 'The created notification was already read before observer acknowledgement.'
    }
    $createdDetail = Get-SmokeNotificationDetail -NotificationId ([Guid]$createdNotification.id)
    Assert-SmokeNotificationShape `
        -Notification $createdDetail `
        -ExpectedBlockGroupId $blockGroupId `
        -ExpectedName 'manual-inventory-block-created' `
        -ExpectedTitle 'Inventory blocked' `
        -AfterSequence $observerCursor `
        -IncludesDates
    [void](Mark-SmokeNotificationRead -NotificationId ([Guid]$createdNotification.id))
    $checks.Add([ordered]@{ name = 'created-notification-detail-and-read-state'; status = 'passed' })

    $release = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/inventory/properties/$($PropertyId.ToString('D'))/block-groups/$($blockGroupId.ToString('D'))/release" `
            -Method POST `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $actorToken `
            -Body @{ operationId = $releaseOperationId }) `
        -ExpectedStatus 200 `
        -Operation 'Release smoke inventory block'
    if ([Guid]$release.blockGroupId -ne $blockGroupId -or
        [Guid]$release.propertyId -ne $PropertyId -or
        [int]$release.affectedBlockCount -ne 1) {
        throw 'The smoke inventory block release returned an invalid receipt.'
    }
    $blockReleased = $true

    $streamReleased = Read-SmokeStreamNotification `
        -Context $historyStream `
        -ExpectedBlockGroupId $blockGroupId `
        -ExpectedName 'manual-inventory-block-released'
    Assert-SmokeNotificationShape `
        -Notification $streamReleased `
        -ExpectedBlockGroupId $blockGroupId `
        -ExpectedName 'manual-inventory-block-released' `
        -ExpectedTitle 'Inventory block released' `
        -AfterSequence ([long]$createdNotification.streamSequence)
    $checks.Add([ordered]@{ name = 'released-notification-live-streamed'; status = 'passed' })

    $releasedNotification = Wait-SmokeNotification `
        -ExpectedBlockGroupId $blockGroupId `
        -ExpectedName 'manual-inventory-block-released'
    Assert-SmokeNotificationShape `
        -Notification $releasedNotification `
        -ExpectedBlockGroupId $blockGroupId `
        -ExpectedName 'manual-inventory-block-released' `
        -ExpectedTitle 'Inventory block released' `
        -AfterSequence ([long]$createdNotification.streamSequence)
    if ($null -ne $releasedNotification.readAtUtc) {
        throw 'The released notification was already read before observer acknowledgement.'
    }
    $releasedDetail = Get-SmokeNotificationDetail -NotificationId ([Guid]$releasedNotification.id)
    Assert-SmokeNotificationShape `
        -Notification $releasedDetail `
        -ExpectedBlockGroupId $blockGroupId `
        -ExpectedName 'manual-inventory-block-released' `
        -ExpectedTitle 'Inventory block released' `
        -AfterSequence ([long]$createdNotification.streamSequence)
    [void](Mark-SmokeNotificationRead -NotificationId ([Guid]$releasedNotification.id))
    $checks.Add([ordered]@{ name = 'released-notification-detail-and-read-state'; status = 'passed' })

    Start-Sleep -Seconds $ActorExclusionObservationSeconds
    $actorCreated = @(Get-SmokeNotificationMatches `
            -Token $actorToken `
            -ExpectedBlockGroupId $blockGroupId `
            -ExpectedName 'manual-inventory-block-created')
    $actorReleased = @(Get-SmokeNotificationMatches `
            -Token $actorToken `
            -ExpectedBlockGroupId $blockGroupId `
            -ExpectedName 'manual-inventory-block-released')
    if ($actorCreated.Count -ne 0 -or $actorReleased.Count -ne 0) {
        throw 'The initiating actor received a notification for its own inventory mutation.'
    }
    $checks.Add([ordered]@{ name = 'initiating-actor-excluded'; status = 'passed' })

    $observerCreated = @(Get-SmokeNotificationMatches `
            -Token $observerToken `
            -ExpectedBlockGroupId $blockGroupId `
            -ExpectedName 'manual-inventory-block-created')
    $observerReleased = @(Get-SmokeNotificationMatches `
            -Token $observerToken `
            -ExpectedBlockGroupId $blockGroupId `
            -ExpectedName 'manual-inventory-block-released')
    if ($observerCreated.Count -ne 1 -or
        $observerReleased.Count -ne 1 -or
        $null -eq $observerCreated[0].readAtUtc -or
        $null -eq $observerReleased[0].readAtUtc) {
        throw 'Observer notification history is not exactly-once and read after acknowledgement.'
    }
    $checks.Add([ordered]@{ name = 'observer-history-exactly-once'; status = 'passed' })

    $releasedBlocks = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/inventory/properties/$($PropertyId.ToString('D'))/blocks?inventoryUnitId=$($InventoryUnitId.ToString('D'))&includeReleased=true&page=1&pageSize=100" `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $observerToken `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Confirm smoke inventory block release'
    $matchingBlocks = @($releasedBlocks.blocks | Where-Object {
            [Guid]$_.blockGroupId -eq $blockGroupId
        })
    if ($matchingBlocks.Count -ne 1 -or [int]$matchingBlocks[0].status -ne 2) {
        throw 'The smoke inventory block was not retained in released state.'
    }
    $checks.Add([ordered]@{ name = 'inventory-block-cleanup-confirmed'; status = 'passed' })
    $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds
    if ($observedReleaseId -cne $releaseIdBefore) {
        throw 'The public API release identity changed during notification verification.'
    }
    $checks.Add([ordered]@{ name = 'release-identity-continuous'; status = 'passed' })
}
catch {
    Release-SmokeBlockBestEffort
    throw
}
finally {
    Close-SmokeNotificationHistoryStream -Context $historyStream
    $client.Dispose()
    $actorToken = $null
    $observerToken = $null
    $reason = $null
}

$evidence = [ordered]@{
    schemaVersion = 1
    evidenceKind = 'bunkfy-deployed-operations-notifications-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-fixture' }
    result = 'passed'
    workspaceId = $WorkspaceId.ToString('D')
    propertyId = $PropertyId.ToString('D')
    inventoryUnitId = $InventoryUnitId.ToString('D')
    arrival = $arrivalText
    departure = $departureText
    blockGroupId = $blockGroupId.ToString('D')
    createdNotification = [ordered]@{
        id = ([Guid]$createdNotification.id).ToString('D')
        streamSequence = [long]$createdNotification.streamSequence
    }
    releasedNotification = [ordered]@{
        id = ([Guid]$releasedNotification.id).ToString('D')
        streamSequence = [long]$releasedNotification.streamSequence
    }
    checks = @($checks)
    limitations = @(
        'browser-attention-rendering-not-exercised',
        'external-delivery-adapters-not-exercised',
        'released-block-and-notification-history-retained'
    )
}

$parent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $parent -Force)
}
$temporaryPath = "$OutputPath.$([Guid]::NewGuid().ToString('N')).tmp"
try {
    $json = $evidence | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText(
        $temporaryPath,
        ($json.Replace("`r`n", "`n") + "`n"),
        [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $OutputPath -Force:$Force
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

Write-Host "BunkFy deployed Operations Notifications passed $($checks.Count) checks."
Write-Host "Evidence: $OutputPath"
