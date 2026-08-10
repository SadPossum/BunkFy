[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][string] $EnvironmentPath,
    [string] $ComposePath,
    [string] $OperatorComposePath,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [ValidateRange(30, 600)][int] $ConvergenceTimeoutSeconds = 180,
    [ValidateRange(500, 5000)][int] $PollIntervalMilliseconds = 1000,
    [string] $OutputPath,
    [switch] $AllowLoopbackHttp,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot 'deployed-public-edge.common.ps1')
. (Join-Path $PSScriptRoot 'preview-state.common.ps1')
. (Join-Path $PSScriptRoot 'preview-mail-capture.common.ps1')

$root = Get-BunkFyRepositoryRoot
$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackHttp
if ([string]::IsNullOrWhiteSpace($ComposePath)) {
    $ComposePath = Join-BunkFyPath 'deploy/preview/compose.yaml'
}
if ([string]::IsNullOrWhiteSpace($OperatorComposePath)) {
    $OperatorComposePath = Join-BunkFyPath 'deploy/preview/compose.mailpit-operator.yaml'
}
$ComposePath = [IO.Path]::GetFullPath($ComposePath)
$OperatorComposePath = [IO.Path]::GetFullPath($OperatorComposePath)
$EnvironmentPath = [IO.Path]::GetFullPath($EnvironmentPath)
foreach ($path in @($ComposePath, $OperatorComposePath, $EnvironmentPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required rehearsal file '$path' does not exist."
    }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Required rehearsal file '$path' must not be a reparse point."
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/preview-onboarding-$stamp.json"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $OutputPath
$outputBaseName = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
$invitationEvidencePath = Join-Path $outputDirectory "$outputBaseName.invitation.json"
$enrollmentEvidencePath = Join-Path $outputDirectory "$outputBaseName.enrollment.json"

function Assert-RehearsalOutputAvailable {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The evidence path is not a regular file: '$Path'."
    }
    if (-not $Force) {
        throw "The evidence file already exists: '$Path'. Use -Force to replace it."
    }
}

foreach ($path in @($OutputPath, $invitationEvidencePath, $enrollmentEvidencePath)) {
    Assert-RehearsalOutputAvailable -Path $path
}

$composeDefinition = Get-BunkFyPreviewComposeDefinition `
    -Root $root `
    -ComposePath $ComposePath `
    -EnvironmentPath $EnvironmentPath
$mailpitService = $composeDefinition.services.PSObject.Properties['mailpit']
if ($null -eq $mailpitService) {
    throw 'Preview Compose does not define the private Mailpit service.'
}
$composeProjectName = [string]$composeDefinition.name
if ([string]::IsNullOrWhiteSpace($composeProjectName)) {
    throw 'Preview Compose does not resolve a project name.'
}
$ports = $mailpitService.Value.PSObject.Properties['ports']
if ($null -ne $ports -and $null -ne $ports.Value -and @($ports.Value).Count -gt 0) {
    throw 'Base Preview Compose publishes a Mailpit host port.'
}

function Get-RehearsalComposeEnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $serviceProperty = $composeDefinition.services.PSObject.Properties[$ServiceName]
    if ($null -eq $serviceProperty) {
        throw "Preview Compose service '$ServiceName' is missing."
    }
    $environmentProperty = $serviceProperty.Value.PSObject.Properties['environment']
    if ($null -eq $environmentProperty -or $null -eq $environmentProperty.Value) {
        throw "Preview Compose service '$ServiceName' has no environment."
    }
    $valueProperty = $environmentProperty.Value.PSObject.Properties[$Name]
    if ($null -eq $valueProperty) {
        throw "Preview Compose service '$ServiceName' is missing environment key '$Name'."
    }
    return [string]$valueProperty.Value
}

foreach ($required in @(
        [pscustomobject]@{ Service = 'api'; Name = 'Email__Smtp__Enabled' },
        [pscustomobject]@{ Service = 'api'; Name = 'Notifications__Adapters__Email__Enabled' },
        [pscustomobject]@{ Service = 'worker'; Name = 'Email__Smtp__Enabled' },
        [pscustomobject]@{ Service = 'worker'; Name = 'Notifications__Adapters__Email__Enabled' },
        [pscustomobject]@{ Service = 'worker'; Name = 'Notifications__Delivery__Enabled' })) {
    $value = Get-RehearsalComposeEnvironmentValue `
        -ServiceName $required.Service `
        -Name $required.Name
    if ($value -cne 'true') {
        throw "Preview email capture is not enabled for $($required.Service)."
    }
}
foreach ($serviceName in @('api', 'worker')) {
    $smtpHost = Get-RehearsalComposeEnvironmentValue `
        -ServiceName $serviceName `
        -Name 'Email__Smtp__Host'
    if ($smtpHost -cne 'mailpit') {
        throw "Preview SMTP host for $serviceName is not the private Mailpit service."
    }
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
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Preview-Onboarding-Rehearsal/1')

$mailpitHandler = [Net.Http.HttpClientHandler]::new()
$mailpitHandler.AllowAutoRedirect = $false
$mailpitHandler.UseCookies = $false
$mailpitClient = [Net.Http.HttpClient]::new($mailpitHandler, $true)
$mailpitClient.Timeout = [Threading.Timeout]::InfiniteTimeSpan
$mailpitClient.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Preview-Mail-Capture/1')

$checks = [Collections.Generic.List[object]]::new()
$cleanupFailures = [Collections.Generic.List[string]]::new()
$cleanup = [ordered]@{
    nonOwnerMemberships = 'not-created'
    properties = 'not-created'
    workspace = 'not-created'
    ownerSessions = 'not-created'
    invitationApplicantSessions = 'not-created'
    enrollmentApplicantSessions = 'not-created'
    capturedMail = 'not-opened'
    globalIdentities = 'not-created'
}
$mailpitOrigin = $null
$mailpitWindowOpened = $false
$workspaceId = [Guid]::Empty
$allowedPropertyId = [Guid]::Empty
$deniedPropertyId = [Guid]::Empty
$owner = $null
$invitationApplicant = $null
$enrollmentApplicant = $null
$invitationEvidence = $null
$enrollmentEvidence = $null
$proofError = $null
$proofStage = 'not-started'
$releaseIdBefore = $null
$observedReleaseId = $null

function Invoke-RehearsalApi {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PUT')][string] $Method,
        [Parameter(Mandatory = $true)][string] $TenantId,
        [AllowNull()][AllowEmptyString()][string] $Token,
        [AllowNull()][object] $Body
    )

    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::new($Method),
        [Uri]::new($origin, $Path))
    $cancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($RequestTimeoutSeconds))
    try {
        if (-not [string]::IsNullOrWhiteSpace($Token)) {
            $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new(
                'Bearer',
                $Token)
        }
        [void]$request.Headers.TryAddWithoutValidation('X-Tenant-Id', $TenantId)
        [void]$request.Headers.Accept.ParseAdd('application/json')
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 12 -Compress
            $request.Content = [Net.Http.StringContent]::new(
                $json,
                [Text.UTF8Encoding]::new($false),
                'application/json')
        }

        $response = $client.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token).GetAwaiter().GetResult()
        try {
            $maximumBytes = 256KB
            $contentLength = $response.Content.Headers.ContentLength
            if ($null -ne $contentLength -and $contentLength -gt $maximumBytes) {
                throw "Response body exceeds $maximumBytes bytes."
            }
            $stream = $response.Content.ReadAsStreamAsync(
                $cancellation.Token).GetAwaiter().GetResult()
            try {
                $buffer = [byte[]]::new(4096)
                $bodyStream = [IO.MemoryStream]::new()
                try {
                    while (($read = $stream.ReadAsync(
                                $buffer,
                                0,
                                $buffer.Length,
                                $cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
                        if ($bodyStream.Length + $read -gt $maximumBytes) {
                            throw "Response body exceeds $maximumBytes bytes."
                        }
                        $bodyStream.Write($buffer, 0, $read)
                    }
                    $bodyBytes = $bodyStream.ToArray()
                }
                finally {
                    $bodyStream.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }

            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Body = $bodyBytes
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch [OperationCanceledException] {
        throw "Product API request to '$Path' exceeded the timeout."
    }
    finally {
        $cancellation.Dispose()
        $request.Dispose()
    }
}

function Read-RehearsalJson {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ($Response.StatusCode -ne $ExpectedStatus) {
        throw "$Operation returned HTTP $($Response.StatusCode); expected HTTP $ExpectedStatus."
    }
    if ($Response.Body.Length -eq 0) {
        return $null
    }
    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($Response.Body)
        return $json | ConvertFrom-Json -Depth 16
    }
    catch {
        throw "$Operation returned invalid JSON."
    }
}

function Assert-RehearsalStatus {
    param(
        [Parameter(Mandatory = $true)][object] $Response,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ($Response.StatusCode -ne $ExpectedStatus) {
        throw "$Operation returned HTTP $($Response.StatusCode); expected HTTP $ExpectedStatus."
    }
}

function Invoke-RehearsalCompose {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Operation,
        [switch] $OperatorWindow
    )

    $dockerArguments = @(
        'compose',
        '--env-file', $EnvironmentPath,
        '-f', $ComposePath)
    if ($OperatorWindow) {
        $dockerArguments += @('-f', $OperatorComposePath)
    }
    $dockerArguments += $Arguments

    Push-Location -LiteralPath $root
    try {
        $output = @(& docker @dockerArguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exitCode -ne 0) {
        throw "$Operation failed with exit code $exitCode."
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Wait-RehearsalMailpitReady {
    param([switch] $OperatorWindow)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        try {
            [void](Invoke-RehearsalCompose `
                    -Arguments @('exec', '-T', 'mailpit', '/mailpit', 'readyz') `
                    -Operation 'Mailpit readiness check' `
                    -OperatorWindow:$OperatorWindow)
            return
        }
        catch {
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Mailpit did not become ready before the timeout.'
}

function Open-RehearsalMailpitWindow {
    [void](Invoke-RehearsalCompose `
            -Arguments @(
                'up', '--detach', '--no-deps', '--no-build', '--force-recreate', 'mailpit') `
            -Operation 'Open the loopback Mailpit operator window' `
            -OperatorWindow)
    Wait-RehearsalMailpitReady -OperatorWindow

    $containerIds = @(Invoke-RehearsalCompose `
            -Arguments @('ps', '--quiet', 'mailpit') `
            -Operation 'Resolve the operator Mailpit container' `
            -OperatorWindow)
    $containerIds = @($containerIds | Where-Object { $_ -match '^[0-9a-f]{12,64}$' })
    if ($containerIds.Count -ne 1) {
        throw 'Unable to resolve exactly one operator Mailpit container.'
    }
    $published = @(& docker port $containerIds[0] '8025/tcp' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to resolve the loopback Mailpit operator port.'
    }
    $bindings = @($published | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($bindings.Count -ne 1 -or
        $bindings[0] -notmatch '^127\.0\.0\.1:(?<port>[0-9]{1,5})$') {
        throw 'Mailpit operator access is not bound to exactly one IPv4 loopback port.'
    }
    $port = [int]$Matches['port']
    if ($port -lt 1 -or $port -gt 65535) {
        throw 'Mailpit operator port is invalid.'
    }
    return [Uri]::new("http://127.0.0.1:$port/")
}

function Close-RehearsalMailpitWindow {
    [void](Invoke-RehearsalCompose `
            -Arguments @(
                'up', '--detach', '--no-deps', '--no-build', '--force-recreate', 'mailpit') `
            -Operation 'Close and purge the Mailpit operator window')
    Wait-RehearsalMailpitReady

    $containerIds = @(Invoke-RehearsalCompose `
            -Arguments @('ps', '--quiet', 'mailpit') `
            -Operation 'Resolve the private Mailpit container')
    $containerIds = @($containerIds | Where-Object { $_ -match '^[0-9a-f]{12,64}$' })
    if ($containerIds.Count -ne 1) {
        throw 'Unable to resolve exactly one private Mailpit container.'
    }
    $published = @(& docker port $containerIds[0] 2>&1)
    if ($LASTEXITCODE -ne 0 -or @($published | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            }).Count -ne 0) {
        throw 'Mailpit still has a published host port after operator-window cleanup.'
    }

    $operatorNetworkIds = @(& docker network ls `
            --quiet `
            --filter "label=com.docker.compose.project=$composeProjectName" `
            --filter 'label=com.docker.compose.network=mailpit-operator' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to resolve the temporary Mailpit operator network.'
    }
    $operatorNetworkIds = @($operatorNetworkIds | Where-Object {
            $_ -match '^[0-9a-f]{12,64}$'
        })
    if ($operatorNetworkIds.Count -gt 1) {
        throw 'More than one temporary Mailpit operator network exists.'
    }
    if ($operatorNetworkIds.Count -eq 1) {
        $attachedContainers = @(& docker network inspect `
                $operatorNetworkIds[0] `
                --format '{{json .Containers}}' 2>&1)
        if ($LASTEXITCODE -ne 0 -or $attachedContainers.Count -ne 1) {
            throw 'Unable to inspect the temporary Mailpit operator network.'
        }
        $attachments = $attachedContainers[0] | ConvertFrom-Json
        if (@($attachments.PSObject.Properties).Count -ne 0) {
            throw 'The temporary Mailpit operator network still has attached containers.'
        }
        [void](& docker network rm $operatorNetworkIds[0] 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to remove the temporary Mailpit operator network.'
        }
    }
}

function Invoke-MailpitJson {
    param([Parameter(Mandatory = $true)][string] $Path)

    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Get,
        [Uri]::new($mailpitOrigin, $Path))
    $cancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($RequestTimeoutSeconds))
    try {
        [void]$request.Headers.Accept.ParseAdd('application/json')
        $response = $mailpitClient.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token).GetAwaiter().GetResult()
        try {
            if ([int]$response.StatusCode -ne 200) {
                throw "Private Mailpit request returned HTTP $([int]$response.StatusCode)."
            }
            $contentLength = $response.Content.Headers.ContentLength
            if ($null -ne $contentLength -and $contentLength -gt 512KB) {
                throw 'Private Mailpit response exceeded 524288 bytes.'
            }
            $body = $response.Content.ReadAsByteArrayAsync(
                $cancellation.Token).GetAwaiter().GetResult()
            if ($body.Length -gt 512KB) {
                throw 'Private Mailpit response exceeded 524288 bytes.'
            }
            try {
                $json = [Text.UTF8Encoding]::new($false, $true).GetString($body)
                return $json | ConvertFrom-Json -Depth 16
            }
            catch {
                throw 'Private Mailpit response was not valid JSON.'
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch [OperationCanceledException] {
        throw 'Private Mailpit request exceeded the timeout.'
    }
    finally {
        $cancellation.Dispose()
        $request.Dispose()
    }
}

function Wait-RehearsalVerificationCode {
    param([Parameter(Mandatory = $true)][string] $Recipient)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $list = Invoke-MailpitJson -Path '/api/v1/messages?limit=100'
        $messages = @(Get-BunkFyMailpitMessagesForRecipient `
                -MessageList $list `
                -Recipient $Recipient)
        foreach ($message in $messages) {
            $messageId = [Uri]::EscapeDataString([string]$message.ID)
            $detail = Invoke-MailpitJson -Path "/api/v1/message/$messageId"
            try {
                $code = Get-BunkFyMailpitVerificationCode -Message $detail
                return [pscustomobject]@{
                    Code = $code
                    CapturedMessageCount = $messages.Count
                }
            }
            catch {
                # A different captured notification for the same synthetic address is ignored.
            }
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw 'A verification code did not arrive in private Mailpit before the timeout.'
}

function Get-RehearsalFingerprint {
    param([Parameter(Mandatory = $true)][string] $Value)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    try {
        return [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function New-RehearsalIdentity {
    param(
        [Parameter(Mandatory = $true)][string] $Role,
        [Parameter(Mandatory = $true)][string] $BatchId,
        [Parameter(Mandatory = $true)][ref] $State
    )

    $identitySuffix = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $email = "bunkfy-preview-$Role-$BatchId-$identitySuffix@example.test"
    $identity = [pscustomobject]@{
        Role = $Role
        Email = $email
        Fingerprint = Get-RehearsalFingerprint -Value $email.ToLowerInvariant()
        AccessToken = $null
        CapturedMessageCount = 0
        RegistrationOutcome = 'attempted'
    }
    $State.Value = $identity
    $password = 'Bf9!' + [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
    try {
        $registration = Read-RehearsalJson `
            -Response (Invoke-RehearsalApi `
                -Path '/api/auth/browser/register' `
                -Method POST `
                -TenantId 'global' `
                -Token $null `
                -Body @{
                    username = $email
                    usernameType = 'email'
                    password = $password
                }) `
            -ExpectedStatus 200 `
            -Operation "Register the $Role smoke identity"
        $token = [string]$registration.accessToken
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "Registration did not return a token for the $Role smoke identity."
        }
        $identity.AccessToken = $token
        $identity.RegistrationOutcome = 'registered'

        $methods = Read-RehearsalJson `
            -Response (Invoke-RehearsalApi `
                -Path '/api/auth/methods' `
                -Method GET `
                -TenantId 'global' `
                -Token $token `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation "Read $Role authentication methods"
        $activeEmail = @($methods.emails | Where-Object {
                [bool]$_.isActive -and
                [string]$_.email -ieq $email
            })
        if ($activeEmail.Count -ne 1 -or [bool]$activeEmail[0].isVerified) {
            throw "The $Role smoke identity does not have one active unverified email."
        }

        Assert-RehearsalStatus `
            -Response (Invoke-RehearsalApi `
                -Path '/api/auth/email-verification' `
                -Method POST `
                -TenantId 'global' `
                -Token $token `
                -Body @{ emailId = [Guid]$activeEmail[0].id }) `
            -ExpectedStatus 202 `
            -Operation "Request $Role email verification"

        $capture = Wait-RehearsalVerificationCode -Recipient $email
        $code = [string]$capture.Code
        try {
            Assert-RehearsalStatus `
                -Response (Invoke-RehearsalApi `
                    -Path '/api/auth/email-verification/confirm' `
                    -Method POST `
                    -TenantId 'global' `
                    -Token $token `
                    -Body @{ code = $code }) `
                -ExpectedStatus 204 `
                -Operation "Confirm $Role email verification"
        }
        finally {
            $code = $null
            $capture.Code = $null
        }

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
        do {
            $methods = Read-RehearsalJson `
                -Response (Invoke-RehearsalApi `
                    -Path '/api/auth/methods' `
                    -Method GET `
                    -TenantId 'global' `
                    -Token $token `
                    -Body $null) `
                -ExpectedStatus 200 `
                -Operation "Confirm $Role verified authentication method"
            $verified = @($methods.emails | Where-Object {
                    [bool]$_.isActive -and
                    [bool]$_.isVerified -and
                    [string]$_.email -ieq $email
            })
            if ($verified.Count -eq 1) {
                $identity.CapturedMessageCount = [int]$capture.CapturedMessageCount
                return $identity
            }
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
        } while ([DateTimeOffset]::UtcNow -lt $deadline)

        throw "The $Role email verification did not converge before the timeout."
    }
    finally {
        $password = $null
    }
}

function Get-RehearsalWorkspaceSummary {
    param([Parameter(Mandatory = $true)][string] $Token)

    $matches = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $response = Read-RehearsalJson `
            -Response (Invoke-RehearsalApi `
                -Path "/api/organizations?page=$page&pageSize=100" `
                -Method GET `
                -TenantId 'global' `
                -Token $Token `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List owner workspaces'
        foreach ($item in @($response.items)) {
            if ([Guid]$item.organization.organizationId -eq $workspaceId) {
                $matches.Add($item)
            }
        }
        $page++
        if ($page -gt 100) {
            throw 'Workspace lookup exceeded 100 pages.'
        }
    } while ([bool]$response.hasMore)

    if ($matches.Count -ne 1) {
        throw 'The synthetic workspace is not uniquely visible to its owner.'
    }
    return $matches[0]
}

function Wait-RehearsalOwnerStaff {
    param([Parameter(Mandatory = $true)][string] $Token)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $response = Invoke-RehearsalApi `
            -Path '/api/staff/me' `
            -Method GET `
            -TenantId $workspaceId.ToString('D') `
            -Token $Token `
            -Body $null
        if ($response.StatusCode -eq 200) {
            return Read-RehearsalJson `
                -Response $response `
                -ExpectedStatus 200 `
                -Operation 'Read owner Staff projection'
        }
        if ($response.StatusCode -notin @(403, 404)) {
            Assert-RehearsalStatus `
                -Response $response `
                -ExpectedStatus 200 `
                -Operation 'Read owner Staff projection'
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'The owner Staff projection did not converge before the timeout.'
}

function New-RehearsalProperty {
    param(
        [Parameter(Mandatory = $true)][string] $Token,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][ref] $State
    )

    $receipt = Read-RehearsalJson `
        -Response (Invoke-RehearsalApi `
            -Path '/api/properties' `
            -Method POST `
            -TenantId $workspaceId.ToString('D') `
            -Token $Token `
            -Body @{
                operationId = [Guid]::NewGuid()
                name = $Name
                code = $Code
                timeZoneId = 'UTC'
            }) `
        -ExpectedStatus 200 `
        -Operation "Create synthetic property $Code"
    $propertyId = [Guid]$receipt.propertyId
    if ($propertyId -eq [Guid]::Empty) {
        throw "Synthetic property $Code returned an empty identifier."
    }
    $State.Value = $propertyId

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $response = Invoke-RehearsalApi `
            -Path "/api/properties/$($propertyId.ToString('D'))" `
            -Method GET `
            -TenantId $workspaceId.ToString('D') `
            -Token $Token `
            -Body $null
        if ($response.StatusCode -eq 200) {
            $property = Read-RehearsalJson `
                -Response $response `
                -ExpectedStatus 200 `
                -Operation "Read synthetic property $Code"
            if ([Guid]$property.propertyId -eq $propertyId -and
                [string]$property.status -ceq 'active') {
                return $propertyId
            }
        }
        elseif ($response.StatusCode -ne 404) {
            Assert-RehearsalStatus `
                -Response $response `
                -ExpectedStatus 200 `
                -Operation "Read synthetic property $Code"
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Synthetic property $Code did not become active before the timeout."
}

function Retire-RehearsalProperties {
    param([Parameter(Mandatory = $true)][string] $Token)

    $propertyIds = @($allowedPropertyId, $deniedPropertyId) |
        Where-Object { $_ -ne [Guid]::Empty }
    $retiredCount = 0
    foreach ($propertyId in $propertyIds) {
        $property = Read-RehearsalJson `
            -Response (Invoke-RehearsalApi `
                -Path "/api/properties/$($propertyId.ToString('D'))" `
                -Method GET `
                -TenantId $workspaceId.ToString('D') `
                -Token $Token `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation "Read synthetic property '$propertyId' for cleanup"
        if ([string]$property.status -ceq 'retired') {
            $retiredCount++
            continue
        }
        if ([string]$property.status -cne 'active') {
            throw "Synthetic property '$propertyId' has unsupported cleanup status '$($property.status)'."
        }

        $receipt = Read-RehearsalJson `
            -Response (Invoke-RehearsalApi `
                -Path "/api/properties/$($propertyId.ToString('D'))/retire" `
                -Method POST `
                -TenantId $workspaceId.ToString('D') `
                -Token $Token `
                -Body @{
                    operationId = [Guid]::NewGuid()
                    confirmed = $true
                    expectedVersion = [long]$property.version
                }) `
            -ExpectedStatus 200 `
            -Operation "Retire synthetic property '$propertyId'"
        if ([Guid]$receipt.propertyId -ne $propertyId -or
            [string]$receipt.status -cne 'retired') {
            throw "Synthetic property '$propertyId' cleanup returned an invalid receipt."
        }
        $retiredCount++
    }

    return $retiredCount
}

function Read-RehearsalChildEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedKind
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Child evidence '$ExpectedKind' was not created."
    }
    try {
        $evidence = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 16
    }
    catch {
        throw "Child evidence '$ExpectedKind' is invalid JSON."
    }
    if ([string]$evidence.evidenceKind -cne $ExpectedKind -or
        [string]$evidence.result -cne 'passed' -or
        [string]$evidence.releaseId -cne $ExpectedReleaseId -or
        [Guid]$evidence.workspaceId -ne $workspaceId -or
        @($evidence.checks | Where-Object { [string]$_.status -cne 'passed' }).Count -ne 0) {
        throw "Child evidence '$ExpectedKind' did not satisfy the rehearsal contract."
    }
    return $evidence
}

function Get-RehearsalWorkspaceMembers {
    param([Parameter(Mandatory = $true)][string] $Token)

    $members = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $response = Read-RehearsalJson `
            -Response (Invoke-RehearsalApi `
                -Path "/api/organizations/$($workspaceId.ToString('D'))/members?page=$page&pageSize=100" `
                -Method GET `
                -TenantId $workspaceId.ToString('D') `
                -Token $Token `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List synthetic workspace members for cleanup'
        foreach ($member in @($response.items)) {
            $members.Add($member)
        }
        $page++
        if ($page -gt 100) {
            throw 'Workspace member cleanup exceeded 100 pages.'
        }
    } while ([bool]$response.hasMore)
    return @($members)
}

function Get-RehearsalStaffProfiles {
    param([Parameter(Mandatory = $true)][string] $Token)

    $profiles = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $response = Read-RehearsalJson `
            -Response (Invoke-RehearsalApi `
                -Path "/api/staff/members?page=$page&pageSize=100" `
                -Method GET `
                -TenantId $workspaceId.ToString('D') `
                -Token $Token `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List synthetic Staff records for cleanup'
        foreach ($item in @($response.items)) {
            $profile = Read-RehearsalJson `
                -Response (Invoke-RehearsalApi `
                    -Path "/api/staff/members/$([Guid]$item.staffMemberId)/profile" `
                    -Method GET `
                    -TenantId $workspaceId.ToString('D') `
                    -Token $Token `
                    -Body $null) `
                -ExpectedStatus 200 `
                -Operation 'Read a synthetic Staff profile for cleanup'
            if ([Guid]$profile.staffMemberId -ne [Guid]$item.staffMemberId) {
                throw 'Synthetic Staff cleanup returned a mismatched profile.'
            }
            $profiles.Add($profile)
        }
        $page++
        if ($page -gt 100) {
            throw 'Workspace Staff cleanup exceeded 100 pages.'
        }
    } while ([bool]$response.hasMore)
    return @($profiles)
}

function Remove-RehearsalNonOwnerMembers {
    param([Parameter(Mandatory = $true)][string] $Token)

    $removed = 0
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $members = @(Get-RehearsalWorkspaceMembers -Token $Token)
        $target = @($members | Where-Object {
                [string]$_.role -cne 'owner' -and
                [string]$_.status -cne 'removed'
            }) | Select-Object -First 1
        if ($null -eq $target) {
            return $removed
        }

        # BunkFy owns Staff offboarding; its lifecycle policy closes GMA membership
        # and access atomically before the Staff departure is committed.
        $matchingStaff = @(Get-RehearsalStaffProfiles -Token $Token | Where-Object {
                [string]$_.authSubjectId -ceq [string]$target.subjectId
            })
        if ($matchingStaff.Count -eq 0) {
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            continue
        }
        if ($matchingStaff.Count -ne 1) {
            throw 'A synthetic membership matched more than one Staff profile.'
        }

        $staff = $matchingStaff[0]
        $staffStatus = [int]$staff.status
        if ($staffStatus -in @(1, 2)) {
            $result = Read-RehearsalJson `
                -Response (Invoke-RehearsalApi `
                    -Path "/api/staff/members/$([Guid]$staff.staffMemberId)/depart" `
                    -Method POST `
                    -TenantId $workspaceId.ToString('D') `
                    -Token $Token `
                    -Body @{
                        operationId = [Guid]::NewGuid()
                        effectiveOn = [DateTimeOffset]::UtcNow.ToString(
                            'yyyy-MM-dd',
                            [Globalization.CultureInfo]::InvariantCulture)
                        reason = 'Preview onboarding rehearsal cleanup.'
                        expectedVersion = [long]$staff.version
                    }) `
                -ExpectedStatus 200 `
                -Operation 'Depart a synthetic non-owner Staff member'
            if ([Guid]$result.staffMemberId -ne [Guid]$staff.staffMemberId -or
                [int]$result.status -ne 3) {
                throw 'Synthetic Staff cleanup returned an invalid departure receipt.'
            }
            $removed++
        }
        elseif ($staffStatus -ne 3) {
            throw "Synthetic Staff cleanup found unsupported status '$staffStatus'."
        }

        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Synthetic Staff and membership cleanup did not converge before the timeout.'
}

function Archive-RehearsalWorkspace {
    param([Parameter(Mandatory = $true)][string] $Token)

    $workspace = Get-RehearsalWorkspaceSummary -Token $Token
    if ([string]$workspace.organization.status -ceq 'archived') {
        return
    }
    $organization = $workspace.organization
    if ([string]$organization.status -ceq 'active') {
        $organization = Read-RehearsalJson `
            -Response (Invoke-RehearsalApi `
                -Path "/api/organizations/$($workspaceId.ToString('D'))/suspend" `
                -Method POST `
                -TenantId $workspaceId.ToString('D') `
                -Token $Token `
                -Body @{
                    operationId = [Guid]::NewGuid()
                    expectedVersion = [long]$organization.version
                }) `
            -ExpectedStatus 200 `
            -Operation 'Suspend the synthetic workspace before archive'
        if ([Guid]$organization.organizationId -ne $workspaceId -or
            [string]$organization.status -cne 'suspended') {
            throw 'Synthetic workspace cleanup returned an invalid suspension result.'
        }
    }
    if ([string]$organization.status -cne 'suspended') {
        throw "Synthetic workspace has unsupported cleanup status '$($organization.status)'."
    }

    $archived = Read-RehearsalJson `
        -Response (Invoke-RehearsalApi `
            -Path "/api/organizations/$($workspaceId.ToString('D'))/archive" `
            -Method POST `
            -TenantId $workspaceId.ToString('D') `
            -Token $Token `
            -Body @{
                operationId = [Guid]::NewGuid()
                expectedVersion = [long]$organization.version
            }) `
        -ExpectedStatus 200 `
        -Operation 'Archive the synthetic workspace'
    if ([Guid]$archived.organizationId -ne $workspaceId -or
        [string]$archived.status -cne 'archived') {
        throw 'Synthetic workspace cleanup returned an invalid archive result.'
    }
}

function Revoke-RehearsalSessions {
    param([Parameter(Mandatory = $true)][object] $Identity)

    $preflight = Invoke-RehearsalApi `
        -Path '/api/auth/methods' `
        -Method GET `
        -TenantId 'global' `
        -Token ([string]$Identity.AccessToken) `
        -Body $null
    if ($preflight.StatusCode -eq 401) {
        return 'already-revoked'
    }
    Assert-RehearsalStatus `
        -Response $preflight `
        -ExpectedStatus 200 `
        -Operation "Preflight $($Identity.Role) session cleanup"
    Assert-RehearsalStatus `
        -Response (Invoke-RehearsalApi `
            -Path '/api/auth/sign-out-all' `
            -Method POST `
            -TenantId 'global' `
            -Token ([string]$Identity.AccessToken) `
            -Body $null) `
        -ExpectedStatus 204 `
        -Operation "Revoke $($Identity.Role) sessions"
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $verification = Invoke-RehearsalApi `
            -Path '/api/auth/methods' `
            -Method GET `
            -TenantId 'global' `
            -Token ([string]$Identity.AccessToken) `
            -Body $null
        if ($verification.StatusCode -eq 401) {
            return 'revoked'
        }
        Assert-RehearsalStatus `
            -Response $verification `
            -ExpectedStatus 200 `
            -Operation "Wait for $($Identity.Role) session revocation"
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "The $($Identity.Role) session revocation did not converge before the timeout."
}

function Add-RehearsalCleanupFailure {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Message
    )

    $cleanupFailures.Add($Name)
    Write-Warning $Message
}

function Get-RehearsalFailureCode {
    param([Parameter(Mandatory = $true)][Exception] $Exception)

    $match = [Text.RegularExpressions.Regex]::Match(
        $Exception.Message,
        "(?:problem|code) '([A-Za-z0-9][A-Za-z0-9._-]{0,127})'",
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return 'Rehearsal.ProofFailed'
}

$releaseIdBefore = Assert-BunkFyPublicApiReleaseIdentity `
    -Client $client `
    -Origin $origin `
    -ExpectedReleaseId $ExpectedReleaseId `
    -TimeoutSeconds $RequestTimeoutSeconds
$capabilities = Read-RehearsalJson `
    -Response (Invoke-RehearsalApi `
        -Path '/api/product-capabilities' `
        -Method GET `
        -TenantId 'global' `
        -Token $null `
        -Body $null) `
    -ExpectedStatus 200 `
    -Operation 'Read runtime product capabilities'
if (-not [bool]$capabilities.emailVerificationEnabled) {
    throw 'The deployed product does not declare email verification available.'
}
$checks.Add([ordered]@{ name = 'runtime-email-capability-enabled'; status = 'passed' })

if (-not $PSCmdlet.ShouldProcess(
        $origin.GetLeftPart([UriPartial]::Authority),
        'create three verified synthetic identities, exercise invitation and QR enrollment, then archive and revoke the rehearsal state')) {
    $mailpitClient.Dispose()
    $client.Dispose()
    return
}

try {
    $proofStage = 'mail-capture-open'
    $mailpitWindowOpened = $true
    $mailpitOrigin = Open-RehearsalMailpitWindow
    $cleanup['capturedMail'] = 'open-loopback-only'
    $checks.Add([ordered]@{ name = 'private-mail-capture-opened'; status = 'passed' })

    $proofStage = 'identity-verification'
    $batchId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $owner = New-RehearsalIdentity `
        -Role 'owner' `
        -BatchId $batchId `
        -State ([ref]$owner)
    $cleanup['ownerSessions'] = 'active'
    $invitationApplicant = New-RehearsalIdentity `
        -Role 'invite' `
        -BatchId $batchId `
        -State ([ref]$invitationApplicant)
    $cleanup['invitationApplicantSessions'] = 'active'
    $enrollmentApplicant = New-RehearsalIdentity `
        -Role 'enroll' `
        -BatchId $batchId `
        -State ([ref]$enrollmentApplicant)
    $cleanup['enrollmentApplicantSessions'] = 'active'
    $cleanup['globalIdentities'] = 'retained-signed-out-after-proof'
    $fingerprints = @(
        [string]$owner.Fingerprint,
        [string]$invitationApplicant.Fingerprint,
        [string]$enrollmentApplicant.Fingerprint)
    if (@($fingerprints | Sort-Object -Unique).Count -ne 3) {
        throw 'The rehearsal did not create three distinct synthetic identities.'
    }
    $checks.Add([ordered]@{ name = 'three-captured-email-identities-verified'; status = 'passed' })

    $proofStage = 'workspace-provisioning'
    $workspaceReceipt = Read-RehearsalJson `
        -Response (Invoke-RehearsalApi `
            -Path '/api/organizations' `
            -Method POST `
            -TenantId 'global' `
            -Token ([string]$owner.AccessToken) `
            -Body @{
                operationId = [Guid]::NewGuid()
                name = "BunkFy onboarding smoke $batchId"
                slug = "bunkfy-onboarding-$batchId"
            }) `
        -ExpectedStatus 200 `
        -Operation 'Create the synthetic workspace'
    $workspaceId = [Guid]$workspaceReceipt.organization.organizationId
    if ($workspaceId -eq [Guid]::Empty -or
        [string]$workspaceReceipt.organization.status -cne 'active' -or
        [string]$workspaceReceipt.membership.role -cne 'owner' -or
        [string]$workspaceReceipt.membership.status -cne 'active') {
        throw 'Synthetic workspace creation returned an invalid owner receipt.'
    }
    $cleanup['workspace'] = 'active'
    $cleanup['nonOwnerMemberships'] = 'pending'

    $workspaceReady = $false
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $workspace = Get-RehearsalWorkspaceSummary -Token ([string]$owner.AccessToken)
        if ([string]$workspace.organization.status -ceq 'active' -and
            [string]$workspace.membership.role -ceq 'owner' -and
            [string]$workspace.membership.status -ceq 'active') {
            $workspaceReady = $true
            break
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if (-not $workspaceReady) {
        throw 'Synthetic workspace ownership did not converge before the timeout.'
    }

    $staff = Wait-RehearsalOwnerStaff -Token ([string]$owner.AccessToken)
    $updatedStaff = Read-RehearsalJson `
        -Response (Invoke-RehearsalApi `
            -Path '/api/staff/me' `
            -Method PUT `
            -TenantId $workspaceId.ToString('D') `
            -Token ([string]$owner.AccessToken) `
            -Body @{
                operationId = [Guid]::NewGuid()
                displayName = 'Preview onboarding owner'
                legalName = $null
                workEmail = $null
                workPhone = $null
                employeeNumber = $null
                jobTitle = 'Smoke owner'
                department = 'Operations verification'
                expectedVersion = [long]$staff.version
            }) `
        -ExpectedStatus 200 `
        -Operation 'Update the synthetic owner Staff profile'
    if ([Guid]$updatedStaff.staffMemberId -ne [Guid]$staff.staffMemberId) {
        throw 'Synthetic owner Staff update returned a different profile.'
    }
    $checks.Add([ordered]@{ name = 'workspace-owner-staff-projected'; status = 'passed' })

    $proofStage = 'property-provisioning'
    $allowedPropertyId = New-RehearsalProperty `
        -Token ([string]$owner.AccessToken) `
        -Name 'Preview onboarding allowed' `
        -Code "smoke-a-$batchId" `
        -State ([ref]$allowedPropertyId)
    $deniedPropertyId = New-RehearsalProperty `
        -Token ([string]$owner.AccessToken) `
        -Name 'Preview onboarding denied' `
        -Code "smoke-b-$batchId" `
        -State ([ref]$deniedPropertyId)
    if ($allowedPropertyId -eq $deniedPropertyId) {
        throw 'Synthetic property identifiers are not distinct.'
    }
    $cleanup['properties'] = 'active-2'
    $checks.Add([ordered]@{ name = 'two-active-properties-created'; status = 'passed' })

    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
    }
    $ownerToken = ConvertTo-SecureString `
        -String ([string]$owner.AccessToken) `
        -AsPlainText `
        -Force
    $invitationToken = ConvertTo-SecureString `
        -String ([string]$invitationApplicant.AccessToken) `
        -AsPlainText `
        -Force
    $enrollmentToken = ConvertTo-SecureString `
        -String ([string]$enrollmentApplicant.AccessToken) `
        -AsPlainText `
        -Force
    try {
        $proofStage = 'invitation-proof'
        & (Join-Path $PSScriptRoot 'verify-deployed-workspace-invitation.ps1') `
            -PublicOrigin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -WorkspaceId $workspaceId `
            -AllowedPropertyId $allowedPropertyId `
            -DeniedPropertyId $deniedPropertyId `
            -ApplicantEmail ([string]$invitationApplicant.Email) `
            -ApplicantDisplayName 'Preview invitation applicant' `
            -OwnerAccessToken $ownerToken `
            -ApplicantAccessToken $invitationToken `
            -RequestTimeoutSeconds $RequestTimeoutSeconds `
            -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
            -PollIntervalMilliseconds $PollIntervalMilliseconds `
            -OutputPath $invitationEvidencePath `
            -AllowLoopbackHttp:$AllowLoopbackHttp `
            -Force `
            -Confirm:$false
        $invitationEvidence = Read-RehearsalChildEvidence `
            -Path $invitationEvidencePath `
            -ExpectedKind 'bunkfy-deployed-workspace-invitation-probe'
        $checks.Add([ordered]@{ name = 'invitation-child-proof-passed'; status = 'passed' })

        $proofStage = 'enrollment-proof'
        & (Join-Path $PSScriptRoot 'verify-deployed-workspace-enrollment.ps1') `
            -PublicOrigin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -WorkspaceId $workspaceId `
            -AllowedPropertyId $allowedPropertyId `
            -DeniedPropertyId $deniedPropertyId `
            -ApplicantEmail ([string]$enrollmentApplicant.Email) `
            -ApplicantDisplayName 'Preview enrollment applicant' `
            -OwnerAccessToken $ownerToken `
            -ApplicantAccessToken $enrollmentToken `
            -RequestTimeoutSeconds $RequestTimeoutSeconds `
            -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
            -PollIntervalMilliseconds $PollIntervalMilliseconds `
            -OutputPath $enrollmentEvidencePath `
            -AllowLoopbackHttp:$AllowLoopbackHttp `
            -Force `
            -Confirm:$false
        $enrollmentEvidence = Read-RehearsalChildEvidence `
            -Path $enrollmentEvidencePath `
            -ExpectedKind 'bunkfy-deployed-workspace-enrollment-probe'
        $checks.Add([ordered]@{ name = 'qr-enrollment-child-proof-passed'; status = 'passed' })
    }
    finally {
        $ownerToken.Dispose()
        $invitationToken.Dispose()
        $enrollmentToken.Dispose()
    }

    $proofStage = 'release-continuity'
    $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds
    if ($observedReleaseId -cne $releaseIdBefore) {
        throw 'The public API release identity changed during the onboarding rehearsal.'
    }
    $checks.Add([ordered]@{ name = 'release-identity-continuous'; status = 'passed' })
    $proofStage = 'proof-complete'
}
catch {
    $proofError = $_.Exception
}
finally {
    if ($workspaceId -ne [Guid]::Empty -and $null -ne $owner) {
        try {
            $removedCount = Remove-RehearsalNonOwnerMembers `
                -Token ([string]$owner.AccessToken)
            $cleanup['nonOwnerMemberships'] = "removed-$removedCount"
        }
        catch {
            $cleanup['nonOwnerMemberships'] = 'failed'
            Add-RehearsalCleanupFailure `
                -Name 'non-owner-memberships' `
                -Message 'Synthetic non-owner memberships could not all be removed.'
        }
        try {
            $retiredCount = Retire-RehearsalProperties `
                -Token ([string]$owner.AccessToken)
            $cleanup['properties'] = "retired-$retiredCount"
        }
        catch {
            $cleanup['properties'] = 'failed'
            Add-RehearsalCleanupFailure `
                -Name 'properties' `
                -Message 'Synthetic properties could not all be retired.'
        }
        try {
            Archive-RehearsalWorkspace -Token ([string]$owner.AccessToken)
            $cleanup['workspace'] = 'archived'
        }
        catch {
            $cleanup['workspace'] = 'failed'
            Add-RehearsalCleanupFailure `
                -Name 'workspace-archive' `
                -Message 'The synthetic workspace could not be archived.'
        }
    }

    foreach ($identityCleanup in @(
            [pscustomobject]@{
                Identity = $invitationApplicant
                Key = 'invitationApplicantSessions'
                Failure = 'invitation-applicant-sessions'
            },
            [pscustomobject]@{
                Identity = $enrollmentApplicant
                Key = 'enrollmentApplicantSessions'
                Failure = 'enrollment-applicant-sessions'
            },
            [pscustomobject]@{
                Identity = $owner
                Key = 'ownerSessions'
                Failure = 'owner-sessions'
            })) {
        if ($null -eq $identityCleanup.Identity) {
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$identityCleanup.Identity.AccessToken)) {
            $cleanup[$identityCleanup.Key] = 'failed'
            Add-RehearsalCleanupFailure `
                -Name $identityCleanup.Failure `
                -Message "Synthetic $($identityCleanup.Identity.Role) registration was attempted but returned no access token; session cleanup cannot be proven."
            continue
        }
        try {
            $cleanup[$identityCleanup.Key] = Revoke-RehearsalSessions `
                -Identity $identityCleanup.Identity
        }
        catch {
            $cleanup[$identityCleanup.Key] = 'failed'
            Add-RehearsalCleanupFailure `
                -Name $identityCleanup.Failure `
                -Message "Synthetic $($identityCleanup.Identity.Role) sessions could not be fully revoked."
        }
    }
    if (@(
            $cleanup['ownerSessions'],
            $cleanup['invitationApplicantSessions'],
            $cleanup['enrollmentApplicantSessions']) -contains 'failed') {
        $cleanup['globalIdentities'] = 'retained-session-cleanup-partial'
    }
    elseif ($null -ne $owner -or
        $null -ne $invitationApplicant -or
        $null -ne $enrollmentApplicant) {
        $cleanup['globalIdentities'] = 'retained-signed-out-no-public-delete-contract'
    }

    if ($mailpitWindowOpened) {
        try {
            Close-RehearsalMailpitWindow
            $cleanup['capturedMail'] = 'purged-and-loopback-closed'
        }
        catch {
            $cleanup['capturedMail'] = 'failed'
            Add-RehearsalCleanupFailure `
                -Name 'captured-mail' `
                -Message 'The Mailpit operator window could not be closed and verified.'
        }
    }

    if ($null -ne $owner) {
        $owner.AccessToken = $null
        $owner.Email = $null
    }
    if ($null -ne $invitationApplicant) {
        $invitationApplicant.AccessToken = $null
        $invitationApplicant.Email = $null
    }
    if ($null -ne $enrollmentApplicant) {
        $enrollmentApplicant.AccessToken = $null
        $enrollmentApplicant.Email = $null
    }
    $mailpitOrigin = $null
    $mailpitClient.Dispose()
    $client.Dispose()
}

$checks.Add([ordered]@{
        name = 'explicit-cleanup-complete'
        status = if ($cleanupFailures.Count -eq 0) { 'passed' } else { 'failed' }
    })
$identityEvidence = [Collections.Generic.List[object]]::new()
foreach ($identityRecord in @(
        [pscustomobject]@{ Role = 'owner'; Identity = $owner },
        [pscustomobject]@{ Role = 'invitation-applicant'; Identity = $invitationApplicant },
        [pscustomobject]@{ Role = 'enrollment-applicant'; Identity = $enrollmentApplicant })) {
    if ($null -eq $identityRecord.Identity) {
        continue
    }
    $fingerprintProperty = $identityRecord.Identity.PSObject.Properties['Fingerprint']
    $messageCountProperty = $identityRecord.Identity.PSObject.Properties['CapturedMessageCount']
    $identityEvidence.Add([ordered]@{
            role = $identityRecord.Role
            fingerprintSha256 = if ($null -eq $fingerprintProperty) {
                $null
            }
            else {
                [string]$fingerprintProperty.Value
            }
            capturedMessageCount = if ($null -eq $messageCountProperty) {
                0
            }
            else {
                [int]$messageCountProperty.Value
            }
        })
}
$childEvidence = [ordered]@{}
foreach ($childRecord in @(
        [pscustomobject]@{ Name = 'invitation'; Path = $invitationEvidencePath },
        [pscustomobject]@{ Name = 'enrollment'; Path = $enrollmentEvidencePath })) {
    if (-not (Test-Path -LiteralPath $childRecord.Path -PathType Leaf)) {
        continue
    }
    $childEvidence[$childRecord.Name] = [ordered]@{
        path = [IO.Path]::GetRelativePath(
            $outputDirectory,
            $childRecord.Path).Replace('\', '/')
        sha256 = (Get-FileHash `
                -LiteralPath $childRecord.Path `
                -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$evidenceReleaseId = if (-not [string]::IsNullOrWhiteSpace($observedReleaseId)) {
    $observedReleaseId
}
elseif (-not [string]::IsNullOrWhiteSpace($releaseIdBefore)) {
    $releaseIdBefore
}
else {
    $ExpectedReleaseId
}
$result = if ($null -ne $proofError) {
    'proof-failed'
}
elseif ($cleanupFailures.Count -gt 0) {
    'proof-passed-cleanup-partial'
}
else {
    'passed'
}

$evidence = [ordered]@{
    schemaVersion = 1
    evidenceKind = 'bunkfy-preview-onboarding-rehearsal'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $evidenceReleaseId
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-preview' }
    result = $result
    failure = if ($null -eq $proofError) {
        $null
    }
    else {
        [ordered]@{
            stage = $proofStage
            code = Get-RehearsalFailureCode -Exception $proofError
        }
    }
    workspaceId = if ($workspaceId -eq [Guid]::Empty) { $null } else { $workspaceId.ToString('D') }
    propertyIds = @($allowedPropertyId, $deniedPropertyId) |
        Where-Object { $_ -ne [Guid]::Empty } |
        ForEach-Object { $_.ToString('D') }
    identities = @($identityEvidence)
    childEvidence = $childEvidence
    cleanup = $cleanup
    cleanupFailures = @($cleanupFailures)
    checks = @($checks)
    limitations = @(
        'mailpit-capture-is-not-real-provider-delivery-or-inbox-placement-proof',
        'browser-registration-redirect-and-qr-rendering-not-exercised',
        'synthetic-global-identities-retained-signed-out-no-public-delete-contract',
        'archived-workspace-and-child-evidence-retained-for-audit'
    )
}

if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
}
$temporaryPath = "$OutputPath.$([Guid]::NewGuid().ToString('N')).tmp"
try {
    $json = $evidence | ConvertTo-Json -Depth 10
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

if ($null -ne $proofError) {
    throw $proofError
}

if ($cleanupFailures.Count -gt 0) {
    throw "Onboarding proof passed, but cleanup was partial. Review '$OutputPath'."
}

Write-Host "BunkFy Preview onboarding rehearsal passed $($checks.Count) checks."
Write-Host "Evidence: $OutputPath"
