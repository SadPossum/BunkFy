Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probeScript = Join-Path $PSScriptRoot 'operations\verify-deployed-operations-notifications.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'bunkfy-operations-notifications-fixture-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)

$fixture = [pscustomobject]@{
    ReleaseId = 'release-fixture-001'
    AdmissionEvidenceReference = 'admission:11111111111111111111111111111111'
    WorkspaceId = '11111111-1111-4111-8111-111111111111'
    PropertyId = '22222222-2222-4222-8222-222222222222'
    InventoryUnitId = '33333333-3333-4333-8333-333333333333'
    ActorMembershipId = '44444444-4444-4444-8444-444444444444'
    ObserverMembershipId = '55555555-5555-4555-8555-555555555555'
    ActorSubjectId = 'actor-subject-fixture-do-not-retain'
    ObserverSubjectId = 'observer-subject-fixture-do-not-retain'
    BlockGroupId = '66666666-6666-4666-8666-666666666666'
    CreatedNotificationId = '77777777-7777-4777-8777-777777777777'
    ReleasedNotificationId = '88888888-8888-4888-8888-888888888888'
    UnrelatedNotificationId = '99999999-9999-4999-8999-999999999999'
    ActorToken = 'fixture-notification-actor-token-do-not-retain'
    ObserverToken = 'fixture-notification-observer-token-do-not-retain'
    Arrival = '2027-02-11'
    Departure = '2027-02-13'
}

function Start-BunkFyOperationsNotificationsFixtureServer {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('valid', 'actor-leak')]
        [string] $Mode,
        [string] $ReleaseMarkerPath
    )

    $readyPath = Join-Path $fixtureRoot ("ready-$Mode-$([Guid]::NewGuid().ToString('N')).txt")
    $job = Start-Job -ScriptBlock {
        param($ReadyPath, $ReleaseMarkerPath, $Mode, $Fixture)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        function Write-FixtureResponse {
            param(
                [Parameter(Mandatory = $true)][IO.Stream] $Stream,
                [Parameter(Mandatory = $true)][int] $Status,
                [Parameter(Mandatory = $true)][string] $Reason,
                [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Body
            )

            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Body)
            $headers = @(
                "HTTP/1.1 $Status $Reason",
                'Connection: close',
                'Content-Type: application/json; charset=utf-8',
                "Content-Length: $($bytes.Length)",
                '',
                '')
            $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers -join "`r`n")
            $Stream.Write($headerBytes, 0, $headerBytes.Length)
            if ($bytes.Length -gt 0) {
                $Stream.Write($bytes, 0, $bytes.Length)
            }
            $Stream.Flush()
        }

        function Write-SseHeaders {
            param([Parameter(Mandatory = $true)][IO.Stream] $Stream)

            $headers = @(
                'HTTP/1.1 200 OK',
                'Connection: keep-alive',
                'Cache-Control: no-cache',
                'Content-Type: text/event-stream',
                '',
                '')
            $bytes = [Text.Encoding]::ASCII.GetBytes($headers -join "`r`n")
            $Stream.Write($bytes, 0, $bytes.Length)
            $heartbeat = [Text.UTF8Encoding]::new($false).GetBytes(
                "event: heartbeat`ndata: null`n`n")
            $Stream.Write($heartbeat, 0, $heartbeat.Length)
            $Stream.Flush()
        }

        function Write-SseNotification {
            param(
                [Parameter(Mandatory = $true)][IO.Stream] $Stream,
                [Parameter(Mandatory = $true)][object] $Notification
            )

            $json = $Notification | ConvertTo-Json -Depth 12 -Compress
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
                "event: notification`ndata: $json`n`n")
            $Stream.Write($bytes, 0, $bytes.Length)
            $Stream.Flush()
        }

        function New-Notification {
            param(
                [Parameter(Mandatory = $true)][ValidateSet('created', 'released')][string] $Kind,
                [Parameter(Mandatory = $true)][bool] $Read
            )

            $created = $Kind -eq 'created'
            return [ordered]@{
                id = if ($created) {
                    $Fixture.CreatedNotificationId
                }
                else {
                    $Fixture.ReleasedNotificationId
                }
                module = 'inventory'
                name = if ($created) {
                    'manual-inventory-block-created'
                }
                else {
                    'manual-inventory-block-released'
                }
                version = 1
                title = if ($created) { 'Inventory blocked' } else { 'Inventory block released' }
                body = if ($created) {
                    'Inventory was blocked for the fixture date range.'
                }
                else {
                    'A manual inventory block was released.'
                }
                severity = 'info'
                streamSequence = if ($created) { 41 } else { 42 }
                occurredAtUtc = if ($created) {
                    '2026-08-06T10:00:00Z'
                }
                else {
                    '2026-08-06T10:01:00Z'
                }
                createdAtUtc = if ($created) {
                    '2026-08-06T10:00:01Z'
                }
                else {
                    '2026-08-06T10:01:01Z'
                }
                readAtUtc = if ($Read) { '2026-08-06T10:02:00Z' } else { $null }
                payload = if ($created) {
                    [ordered]@{
                        propertyId = $Fixture.PropertyId
                        blockGroupId = $Fixture.BlockGroupId
                        arrival = $Fixture.Arrival
                        departure = $Fixture.Departure
                    }
                }
                else {
                    [ordered]@{
                        propertyId = $Fixture.PropertyId
                        blockGroupId = $Fixture.BlockGroupId
                    }
                }
                tags = @('delivery:web', 'domain:inventory')
                deliveryPolicy = 'respectPreferences'
            }
        }

        function New-UnrelatedNotification {
            return [ordered]@{
                id = $Fixture.UnrelatedNotificationId
                module = 'staff'
                name = 'unrelated-fixture-notification'
                version = 1
                title = 'Existing notification'
                body = $null
                severity = 'info'
                streamSequence = 40
                occurredAtUtc = '2026-08-06T09:00:00Z'
                createdAtUtc = '2026-08-06T09:00:01Z'
                readAtUtc = '2026-08-06T09:05:00Z'
                payload = @{}
                tags = @('delivery:web', 'domain:staff')
                deliveryPolicy = 'respectPreferences'
            }
        }

        function New-NotificationList {
            param([Parameter(Mandatory = $true)][string] $Token)

            $items = [Collections.Generic.List[object]]::new()
            if ($Token -ceq $Fixture.ObserverToken) {
                if ($script:released) {
                    $items.Add((New-Notification -Kind released -Read $script:releasedRead))
                }
                if ($script:created) {
                    $items.Add((New-Notification -Kind created -Read $script:createdRead))
                }
                $items.Add((New-UnrelatedNotification))
            }
            elseif ($Mode -ceq 'actor-leak' -and $script:created) {
                $items.Add((New-Notification -Kind created -Read $false))
            }

            $unreadCount = @($items | Where-Object { $null -eq $_.readAtUtc }).Count
            return [ordered]@{
                items = @($items)
                page = 1
                pageSize = 100
                totalCount = $items.Count
                unreadCount = $unreadCount
            }
        }

        function New-MembershipPage {
            param([Parameter(Mandatory = $true)][string] $Token)

            $actor = $Token -ceq $Fixture.ActorToken
            return [ordered]@{
                items = @([ordered]@{
                        organization = [ordered]@{
                            organizationId = $Fixture.WorkspaceId
                            scopeId = $Fixture.WorkspaceId
                            name = 'Fixture workspace'
                            slug = 'fixture-workspace'
                        }
                        membership = [ordered]@{
                            membershipId = if ($actor) {
                                $Fixture.ActorMembershipId
                            }
                            else {
                                $Fixture.ObserverMembershipId
                            }
                            subjectId = if ($actor) {
                                $Fixture.ActorSubjectId
                            }
                            else {
                                $Fixture.ObserverSubjectId
                            }
                            role = if ($actor) { 'owner' } else { 'member' }
                            status = 'active'
                            version = 1
                        }
                    })
                page = 1
                pageSize = 100
                hasMore = $false
            }
        }

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $sseClient = $null
        $sseStream = $null
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [IO.File]::WriteAllText($ReadyPath, [string]$port)

            $script:created = $false
            $script:released = $false
            $script:createdRead = $false
            $script:releasedRead = $false
            $actorPostMutationListCount = 0
            $workflowComplete = $false
            $done = $false
            $requestCount = 0
            $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            while (-not $done -and
                $requestCount -lt 40 -and
                [DateTimeOffset]::UtcNow -lt $inactivityDeadline) {
                if (-not $listener.Pending()) {
                    Start-Sleep -Milliseconds 25
                    continue
                }

                $client = $listener.AcceptTcpClient()
                $keepOpen = $false
                try {
                    $client.ReceiveTimeout = 5000
                    $client.SendTimeout = 5000
                    $stream = $client.GetStream()
                    $reader = [IO.StreamReader]::new(
                        $stream,
                        [Text.UTF8Encoding]::new($false),
                        $false,
                        4096,
                        $true)
                    try {
                        $requestLine = $reader.ReadLine()
                        if ([string]::IsNullOrWhiteSpace($requestLine)) {
                            throw 'Fixture received an empty request line.'
                        }
                        $requestParts = $requestLine.Split(' ')
                        if ($requestParts.Count -lt 2) {
                            throw "Fixture received malformed request '$requestLine'."
                        }
                        $method = $requestParts[0]
                        $path = $requestParts[1]
                        $headers = @{}
                        while ($true) {
                            $line = $reader.ReadLine()
                            if ([string]::IsNullOrEmpty($line)) {
                                break
                            }
                            $separator = $line.IndexOf(':')
                            if ($separator -gt 0) {
                                $headers[$line.Substring(0, $separator).Trim()] =
                                    $line.Substring($separator + 1).Trim()
                            }
                        }
                        $contentLength = if ($headers.ContainsKey('Content-Length')) {
                            [int]$headers['Content-Length']
                        }
                        else {
                            0
                        }
                        $bodyText = ''
                        if ($contentLength -gt 0) {
                            $characters = [char[]]::new($contentLength)
                            $read = 0
                            while ($read -lt $contentLength) {
                                $next = $reader.ReadBlock(
                                    $characters,
                                    $read,
                                    $contentLength - $read)
                                if ($next -le 0) {
                                    throw 'Fixture request body ended early.'
                                }
                                $read += $next
                            }
                            $bodyText = [string]::new($characters)
                        }
                    }
                    finally {
                        $reader.Dispose()
                    }

                    $authorization = [string]$headers['Authorization']
                    $tenantId = [string]$headers['X-Tenant-Id']
                    $token = if ($authorization.StartsWith('Bearer ', [StringComparison]::Ordinal)) {
                        $authorization.Substring(7)
                    }
                    else {
                        ''
                    }
                    if ($path -cne '/api/smoke' -and
                        $token -notin @($Fixture.ActorToken, $Fixture.ObserverToken)) {
                        throw 'Fixture received a missing or unexpected bearer token.'
                    }

                    $requestCount++
                    $inactivityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
                    $status = 200
                    $reason = 'OK'
                    $response = $null
                    if ($method -ceq 'GET' -and $path -ceq '/api/smoke') {
                        $response = [ordered]@{
                            application = 'BunkFy'
                            service = 'BunkFy.Host.Api'
                            status = 'ok'
                            releaseId = $Fixture.ReleaseId
                            admissionEvidenceReference = $Fixture.AdmissionEvidenceReference
                            timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
                        }
                        if ($workflowComplete) {
                            $done = $true
                        }
                    }
                    elseif ($method -ceq 'GET' -and
                        $path -ceq '/api/organizations?page=1&pageSize=100') {
                        if ($tenantId -cne 'global') {
                            throw 'Workspace membership preflight used the wrong scope.'
                        }
                        $response = New-MembershipPage -Token $token
                    }
                    elseif ($method -ceq 'GET' -and
                        $path -ceq "/api/properties/$($Fixture.PropertyId)") {
                        if ($tenantId -cne $Fixture.WorkspaceId) {
                            throw 'Property preflight used the wrong scope.'
                        }
                        $response = @{
                            propertyId = $Fixture.PropertyId
                            name = 'Fixture property'
                            status = 1
                        }
                    }
                    elseif ($method -ceq 'GET' -and
                        $path -match '^/api/inventory/properties/.+/blocks\?') {
                        if ($tenantId -cne $Fixture.WorkspaceId -or
                            $token -cne $Fixture.ObserverToken) {
                            throw 'Inventory destination read used the wrong identity or scope.'
                        }
                        $blocks = if ($script:released -and $path.Contains('includeReleased=true')) {
                            @([ordered]@{
                                    blockId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                                    blockGroupId = $Fixture.BlockGroupId
                                    propertyId = $Fixture.PropertyId
                                    inventoryUnitId = $Fixture.InventoryUnitId
                                    arrival = $Fixture.Arrival
                                    departure = $Fixture.Departure
                                    reason = 'fixture'
                                    status = 2
                                    version = 2
                                    createdAtUtc = '2026-08-06T10:00:00Z'
                                    releasedAtUtc = '2026-08-06T10:01:00Z'
                                })
                        }
                        else {
                            @()
                        }
                        $response = @{
                            blocks = $blocks
                            page = 1
                            pageSize = 100
                            hasMore = $false
                        }
                        if ($script:released -and $path.Contains('includeReleased=true')) {
                            $workflowComplete = $Mode -ceq 'valid'
                        }
                    }
                    elseif ($method -ceq 'GET' -and
                        $path -ceq "/api/inventory/properties/$($Fixture.PropertyId)/availability?arrival=$($Fixture.Arrival)&departure=$($Fixture.Departure)") {
                        if ($tenantId -cne $Fixture.WorkspaceId -or
                            $token -cne $Fixture.ActorToken) {
                            throw 'Availability preflight used the wrong identity or scope.'
                        }
                        $response = @{
                            propertyId = $Fixture.PropertyId
                            arrival = $Fixture.Arrival
                            departure = $Fixture.Departure
                            units = @(@{
                                    unit = @{
                                        inventoryUnitId = $Fixture.InventoryUnitId
                                        propertyId = $Fixture.PropertyId
                                        roomId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
                                        bedId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
                                        kind = 2
                                        label = '1'
                                        isSellable = $true
                                        isTopologyActive = $true
                                    }
                                    isAvailable = $true
                                    activeBlockIds = @()
                                    activeAllocationIds = @()
                                })
                        }
                    }
                    elseif ($method -ceq 'GET' -and
                        $path -match '^/api/notifications\?') {
                        if ($tenantId -cne $Fixture.WorkspaceId) {
                            $status = 403
                            $reason = 'Forbidden'
                            $response = @{ title = 'forbidden' }
                        }
                        else {
                            $response = New-NotificationList -Token $token
                            if ($Mode -ceq 'actor-leak' -and
                                $token -ceq $Fixture.ActorToken -and
                                $script:released) {
                                $actorPostMutationListCount++
                                if ($actorPostMutationListCount -ge 2) {
                                    $done = $true
                                }
                            }
                        }
                    }
                    elseif ($method -ceq 'GET' -and
                        $path -ceq '/api/notifications/history/stream?afterSequence=40') {
                        if ($tenantId -cne $Fixture.WorkspaceId -or
                            $token -cne $Fixture.ObserverToken -or
                            [string]$headers['Accept'] -cne 'text/event-stream') {
                            throw 'Notification stream used the wrong identity, scope, cursor, or media type.'
                        }
                        Write-SseHeaders -Stream $stream
                        $sseClient = $client
                        $sseStream = $stream
                        $keepOpen = $true
                        continue
                    }
                    elseif ($method -ceq 'POST' -and
                        $path -ceq "/api/inventory/properties/$($Fixture.PropertyId)/block-groups") {
                        if ($tenantId -cne $Fixture.WorkspaceId -or
                            $token -cne $Fixture.ActorToken -or
                            $null -eq $sseStream) {
                            throw 'Inventory block creation used the wrong identity, scope, or stream order.'
                        }
                        $body = $bodyText | ConvertFrom-Json -Depth 16
                        if ([Guid]$body.operationId -eq [Guid]::Empty -or
                            [int]$body.target.kind -ne 5 -or
                            [Guid]$body.target.inventoryUnitId -ne [Guid]$Fixture.InventoryUnitId -or
                            [string]$body.arrival -cne $Fixture.Arrival -or
                            [string]$body.departure -cne $Fixture.Departure -or
                            -not ([string]$body.reason).StartsWith(
                                'Deployment notification verification ',
                                [StringComparison]::Ordinal)) {
                            throw 'Inventory block creation body is invalid.'
                        }
                        $script:created = $true
                        $response = @{
                            blockGroupId = $Fixture.BlockGroupId
                            propertyId = $Fixture.PropertyId
                            affectedBlockCount = 1
                        }
                    }
                    elseif ($method -ceq 'POST' -and
                        $path -ceq "/api/inventory/properties/$($Fixture.PropertyId)/block-groups/$($Fixture.BlockGroupId)/release") {
                        if ($tenantId -cne $Fixture.WorkspaceId -or
                            $token -cne $Fixture.ActorToken -or
                            -not $script:created) {
                            throw 'Inventory block release used the wrong identity, scope, or order.'
                        }
                        $body = $bodyText | ConvertFrom-Json -Depth 16
                        if ([Guid]$body.operationId -eq [Guid]::Empty) {
                            throw 'Inventory block release omitted its idempotency identity.'
                        }
                        $script:released = $true
                        if (-not [string]::IsNullOrWhiteSpace($ReleaseMarkerPath)) {
                            [IO.File]::WriteAllText($ReleaseMarkerPath, 'released')
                        }
                        $response = @{
                            blockGroupId = $Fixture.BlockGroupId
                            propertyId = $Fixture.PropertyId
                            affectedBlockCount = 1
                        }
                    }
                    elseif ($method -ceq 'GET' -and
                        $path -match '^/api/notifications/([0-9a-f-]+)$') {
                        if ($tenantId -cne $Fixture.WorkspaceId -or
                            $token -cne $Fixture.ObserverToken) {
                            throw 'Notification detail used the wrong identity or scope.'
                        }
                        $notificationId = $Matches[1]
                        if ($notificationId -ceq $Fixture.CreatedNotificationId) {
                            $response = New-Notification -Kind created -Read $script:createdRead
                        }
                        elseif ($notificationId -ceq $Fixture.ReleasedNotificationId) {
                            $response = New-Notification -Kind released -Read $script:releasedRead
                        }
                        else {
                            throw "Fixture received an unknown notification id '$notificationId'."
                        }
                    }
                    elseif ($method -ceq 'POST' -and
                        $path -match '^/api/notifications/([0-9a-f-]+)/read$') {
                        if ($tenantId -cne $Fixture.WorkspaceId -or
                            $token -cne $Fixture.ObserverToken) {
                            throw 'Notification read acknowledgement used the wrong identity or scope.'
                        }
                        $notificationId = $Matches[1]
                        if ($notificationId -ceq $Fixture.CreatedNotificationId) {
                            $script:createdRead = $true
                        }
                        elseif ($notificationId -ceq $Fixture.ReleasedNotificationId) {
                            $script:releasedRead = $true
                        }
                        else {
                            throw "Fixture received an unknown notification read id '$notificationId'."
                        }
                        $status = 204
                        $reason = 'No Content'
                        $response = $null
                    }
                    else {
                        throw "Fixture received unexpected request '$method $path'."
                    }

                    $responseText = if ($null -eq $response) {
                        ''
                    }
                    else {
                        $response | ConvertTo-Json -Depth 16 -Compress
                    }
                    Write-FixtureResponse `
                        -Stream $stream `
                        -Status $status `
                        -Reason $reason `
                        -Body $responseText

                    if ($method -ceq 'POST' -and
                        $path -ceq "/api/inventory/properties/$($Fixture.PropertyId)/block-groups") {
                        Write-SseNotification `
                            -Stream $sseStream `
                            -Notification (New-Notification -Kind created -Read $false)
                    }
                    elseif ($method -ceq 'POST' -and
                        $path -ceq "/api/inventory/properties/$($Fixture.PropertyId)/block-groups/$($Fixture.BlockGroupId)/release") {
                        Write-SseNotification `
                            -Stream $sseStream `
                            -Notification (New-Notification -Kind released -Read $false)
                    }
                }
                finally {
                    if (-not $keepOpen) {
                        $client.Dispose()
                    }
                }
            }

            if (-not $done) {
                throw "Fixture stopped before the expected terminal request after $requestCount requests."
            }
        }
        finally {
            if ($null -ne $sseClient) {
                $sseClient.Dispose()
            }
            $listener.Stop()
        }
    } -ArgumentList $readyPath, $ReleaseMarkerPath, $Mode, $fixture

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath) -and
        [DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
    }
    if (-not (Test-Path -LiteralPath $readyPath)) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw "The $Mode fixture server did not become ready."
    }
    $port = [int](Get-Content -LiteralPath $readyPath -Raw)
    return [pscustomobject]@{
        Job = $job
        Origin = [Uri]"http://127.0.0.1:$port"
    }
}

function Complete-BunkFyFixtureServer {
    param([Parameter(Mandatory = $true)][object] $Server)

    try {
        $completed = Wait-Job -Job $Server.Job -Timeout 15
        if ($null -eq $completed) {
            throw 'The fixture server did not terminate after the probe.'
        }
        $output = @(Receive-Job -Job $Server.Job -ErrorAction Stop)
        if ($Server.Job.State -ne 'Completed') {
            throw "The fixture server ended in state '$($Server.Job.State)': $($output -join [Environment]::NewLine)"
        }
    }
    finally {
        Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    }
}

function Stop-BunkFyFixtureServer {
    param([AllowNull()][object] $Server)

    if ($null -eq $Server) {
        return
    }
    Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
}

function Invoke-BunkFyFixtureProbe {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('valid', 'actor-leak')][string] $Mode,
        [Parameter(Mandatory = $true)][string] $OutputPath,
        [string] $ExpectedReleaseId = $fixture.ReleaseId,
        [string] $ReleaseMarkerPath
    )

    $server = $null
    try {
        $server = Start-BunkFyOperationsNotificationsFixtureServer `
            -Mode $Mode `
            -ReleaseMarkerPath $ReleaseMarkerPath
        $actorToken = ConvertTo-SecureString $fixture.ActorToken -AsPlainText -Force
        $observerToken = ConvertTo-SecureString $fixture.ObserverToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin $server.Origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -InventoryUnitId $fixture.InventoryUnitId `
            -Arrival $fixture.Arrival `
            -Departure $fixture.Departure `
            -ActorAccessToken $actorToken `
            -ObserverAccessToken $observerToken `
            -RequestTimeoutSeconds 5 `
            -ConvergenceTimeoutSeconds 10 `
            -PollIntervalMilliseconds 500 `
            -ActorExclusionObservationSeconds 1 `
            -OutputPath $OutputPath `
            -AllowLoopbackHttp `
            -Confirm:$false
        Complete-BunkFyFixtureServer -Server $server
        $server = $null
    }
    finally {
        Stop-BunkFyFixtureServer -Server $server
    }
}

function Assert-BunkFyExactPropertyNames {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    if ($actual.Count -ne $expectedSorted.Count -or
        (Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actual)) {
        throw "$Context has an invalid property set."
    }
}

try {
    $validOutput = Join-Path $fixtureRoot 'valid-evidence.json'
    Invoke-BunkFyFixtureProbe -Mode valid -OutputPath $validOutput
    $evidence = Get-Content -LiteralPath $validOutput -Raw | ConvertFrom-Json -Depth 12
    if ($evidence.schemaVersion -ne 3 -or
        $evidence.evidenceKind -cne 'bunkfy-deployed-operations-notifications-probe' -or
        $evidence.result -cne 'passed' -or
        $evidence.releaseId -cne $fixture.ReleaseId -or
        $evidence.admissionEvidenceReference -cne $fixture.AdmissionEvidenceReference -or
        $evidence.transport -cne 'loopback-http-preview' -or
        @($evidence.checks).Count -ne 10 -or
        [string]$evidence.workflow.sourceModule -cne 'inventory' -or
        [string]$evidence.workflow.createdNotificationName -cne
            'manual-inventory-block-created' -or
        [string]$evidence.workflow.releasedNotificationName -cne
            'manual-inventory-block-released' -or
        [int]$evidence.workflow.notificationVersion -ne 1 -or
        [string]$evidence.workflow.deliveryTag -cne 'delivery:web' -or
        [string]$evidence.workflow.domainTag -cne 'domain:inventory' -or
        [int]$evidence.delivery.liveNotificationCount -ne 2 -or
        [int]$evidence.delivery.initiallyUnreadCount -ne 2 -or
        [int]$evidence.delivery.durablyReadCount -ne 2 -or
        [int]$evidence.delivery.observerHistoryCount -ne 2 -or
        [int]$evidence.delivery.actorDeliveryCount -ne 0 -or
        $evidence.delivery.ordered -isnot [bool] -or
        -not [bool]$evidence.delivery.ordered -or
        [string]$evidence.cleanup.inventoryBlock -cne 'released' -or
        [string]$evidence.cleanup.notificationHistory -cne 'retained-read') {
        throw 'The valid notification fixture produced invalid evidence.'
    }
    Assert-BunkFyExactPropertyNames `
        -Value $evidence `
        -Expected @(
            'schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin',
            'releaseId', 'admissionEvidenceReference', 'transport', 'result',
            'workflow', 'delivery',
            'cleanup', 'checks', 'limitations') `
        -Context 'Notification evidence'
    Assert-BunkFyExactPropertyNames `
        -Value $evidence.workflow `
        -Expected @(
            'sourceModule', 'createdNotificationName',
            'releasedNotificationName', 'notificationVersion', 'deliveryTag',
            'domainTag') `
        -Context 'Notification workflow evidence'
    Assert-BunkFyExactPropertyNames `
        -Value $evidence.delivery `
        -Expected @(
            'liveNotificationCount', 'initiallyUnreadCount',
            'durablyReadCount', 'observerHistoryCount', 'actorDeliveryCount',
            'ordered') `
        -Context 'Notification delivery evidence'
    Assert-BunkFyExactPropertyNames `
        -Value $evidence.cleanup `
        -Expected @('inventoryBlock', 'notificationHistory') `
        -Context 'Notification cleanup evidence'
    $evidenceText = Get-Content -LiteralPath $validOutput -Raw
    foreach ($secret in @(
            $fixture.WorkspaceId,
            $fixture.PropertyId,
            $fixture.InventoryUnitId,
            $fixture.ActorMembershipId,
            $fixture.ObserverMembershipId,
            $fixture.BlockGroupId,
            $fixture.CreatedNotificationId,
            $fixture.ReleasedNotificationId,
            $fixture.UnrelatedNotificationId,
            $fixture.ActorToken,
            $fixture.ObserverToken,
            $fixture.ActorSubjectId,
            $fixture.ObserverSubjectId,
            $fixture.Arrival,
            $fixture.Departure,
            'Deployment notification verification ',
            'Inventory was blocked for the fixture date range.',
            'A manual inventory block was released.')) {
        if ($evidenceText.Contains($secret, [StringComparison]::Ordinal)) {
            throw 'Notification evidence retained scoped, personal, secret, or response detail.'
        }
    }
    if (-not $IsWindows) {
        $mode = (& stat -c '%a' -- $validOutput).Trim()
        if ($LASTEXITCODE -ne 0 -or $mode -cne '600') {
            throw "Notification evidence mode is '$mode' instead of '600'."
        }
    }

    $overwriteRejected = $false
    try {
        $actorToken = ConvertTo-SecureString $fixture.ActorToken -AsPlainText -Force
        $observerToken = ConvertTo-SecureString $fixture.ObserverToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://127.0.0.1:65530') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -InventoryUnitId $fixture.InventoryUnitId `
            -Arrival $fixture.Arrival `
            -Departure $fixture.Departure `
            -ActorAccessToken $actorToken `
            -ObserverAccessToken $observerToken `
            -OutputPath $validOutput `
            -AllowLoopbackHttp `
            -Confirm:$false
    }
    catch {
        $overwriteRejected = $_.Exception.Message.Contains(
            'already exists',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $overwriteRejected) {
        throw 'The notification probe overwrote or contacted the network for existing evidence.'
    }

    $releaseMismatchOutput = Join-Path $fixtureRoot 'release-mismatch-evidence.json'
    $releaseMismatchRejected = $false
    try {
        Invoke-BunkFyFixtureProbe `
            -Mode valid `
            -OutputPath $releaseMismatchOutput `
            -ExpectedReleaseId 'release-fixture-other'
    }
    catch {
        $releaseMismatchRejected = $_.Exception.Message.Contains(
            'does not match',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $releaseMismatchRejected -or (Test-Path -LiteralPath $releaseMismatchOutput)) {
        throw 'The notification probe accepted a different deployed release or wrote passing evidence.'
    }

    $invalidOutput = Join-Path $fixtureRoot 'invalid-evidence.json'
    $invalidReleaseMarker = Join-Path $fixtureRoot 'invalid-block-released.txt'
    $invalidRejected = $false
    try {
        Invoke-BunkFyFixtureProbe `
            -Mode actor-leak `
            -OutputPath $invalidOutput `
            -ReleaseMarkerPath $invalidReleaseMarker
    }
    catch {
        $invalidRejected = $_.Exception.Message.Contains(
            'initiating actor received a notification',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $invalidRejected -or
        (Test-Path -LiteralPath $invalidOutput) -or
        -not (Test-Path -LiteralPath $invalidReleaseMarker -PathType Leaf) -or
        (Get-Content -LiteralPath $invalidReleaseMarker -Raw) -cne 'released') {
        throw 'The notification probe accepted an initiating-actor delivery or wrote passing evidence.'
    }

    $sameTokenRejected = $false
    try {
        $sameToken = ConvertTo-SecureString $fixture.ActorToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://127.0.0.1:65530') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -InventoryUnitId $fixture.InventoryUnitId `
            -Arrival $fixture.Arrival `
            -Departure $fixture.Departure `
            -ActorAccessToken $sameToken `
            -ObserverAccessToken $sameToken `
            -OutputPath (Join-Path $fixtureRoot 'same-token.json') `
            -AllowLoopbackHttp `
            -Confirm:$false
    }
    catch {
        $sameTokenRejected = $_.Exception.Message.Contains(
            'distinct accounts',
            [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $sameTokenRejected) {
        throw 'The notification probe accepted identical actor and observer tokens.'
    }

    $insecureRemoteRejected = $false
    try {
        $actorToken = ConvertTo-SecureString $fixture.ActorToken -AsPlainText -Force
        $observerToken = ConvertTo-SecureString $fixture.ObserverToken -AsPlainText -Force
        & $probeScript `
            -PublicOrigin ([Uri]'http://preview.example.test') `
            -ExpectedReleaseId $fixture.ReleaseId `
            -WorkspaceId $fixture.WorkspaceId `
            -PropertyId $fixture.PropertyId `
            -InventoryUnitId $fixture.InventoryUnitId `
            -Arrival $fixture.Arrival `
            -Departure $fixture.Departure `
            -ActorAccessToken $actorToken `
            -ObserverAccessToken $observerToken `
            -OutputPath (Join-Path $fixtureRoot 'insecure-remote.json') `
            -AllowLoopbackHttp `
            -Confirm:$false
    }
    catch {
        $insecureRemoteRejected = $_.Exception.Message.Contains(
            'HTTPS',
            [StringComparison]::Ordinal)
    }
    if (-not $insecureRemoteRejected) {
        throw 'The notification probe accepted insecure non-loopback HTTP.'
    }

    Write-Host 'BunkFy deployed Operations Notifications fixture passed.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
