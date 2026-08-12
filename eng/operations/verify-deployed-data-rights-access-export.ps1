[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][Guid] $WorkspaceId,
    [Parameter(Mandatory = $true)][Guid] $PropertyId,
    [Security.SecureString] $AssuredOperatorAccessToken,
    [Security.SecureString] $UnassuredOperatorAccessToken,
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

$script:MaximumExportBodyBytes = 1MB
$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackHttp
foreach ($identifier in @(
        [pscustomobject]@{ Name = 'WorkspaceId'; Value = $WorkspaceId },
        [pscustomobject]@{ Name = 'PropertyId'; Value = $PropertyId })) {
    if ($identifier.Value -eq [Guid]::Empty) {
        throw "$($identifier.Name) must not be an empty GUID."
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/data-rights-access-export-$stamp.json"
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

$assuredToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $AssuredOperatorAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_DATA_RIGHTS_ASSURED_TOKEN' `
    -Prompt 'Data Rights assured operator access token'
$unassuredToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $UnassuredOperatorAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_DATA_RIGHTS_UNASSURED_TOKEN' `
    -Prompt 'Data Rights unassured operator access token'
$deniedToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $DeniedAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_DATA_RIGHTS_DENIED_TOKEN' `
    -Prompt 'Data Rights nonmember access token'
if ([string]::IsNullOrWhiteSpace($assuredToken) -or
    [string]::IsNullOrWhiteSpace($unassuredToken) -or
    [string]::IsNullOrWhiteSpace($deniedToken)) {
    throw 'All three Data Rights verification access tokens are required.'
}
if (@(@($assuredToken, $unassuredToken, $deniedToken) |
        Sort-Object -Unique).Count -ne 3) {
    throw 'The assured, unassured, and nonmember access tokens must be distinct.'
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
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Deployed-Data-Rights-Access-Export-Probe/1')

$checks = [Collections.Generic.List[object]]::new()
$casePath = "/api/data-rights/properties/$($PropertyId.ToString('D'))/cases"
$guestPath = "/api/guests/properties/$($PropertyId.ToString('D'))"
$guestOperationId = [Guid]::NewGuid()
$guestArchiveOperationId = [Guid]::NewGuid()
$exportIdempotencyKey = [Guid]::NewGuid()
$guestId = [Guid]::Empty
$caseId = [Guid]::Empty
$artifactId = [Guid]::Empty
$guestVersion = 0L
$caseDecisionRevision = 0L
$guestCreated = $false
$guestArchived = $false
$observedReleaseId = $null
$artifactRequestedAtUtc = [DateTimeOffset]::MinValue
$artifactExpiresAtUtc = [DateTimeOffset]::MinValue
$artifactExpiryHours = 0.0
$exportShape = $null
$downloadByteCount = 0

function Invoke-SmokeJsonRequest {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string] $Method,
        [Parameter(Mandatory = $true)][string] $Token,
        [AllowNull()][object] $Body,
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
            -Response (Invoke-SmokeJsonRequest `
                -Path "/api/organizations?page=$page&pageSize=100" `
                -Method GET `
                -Token $assuredToken `
                -Body $null `
                -TenantId 'global') `
            -ExpectedStatus 200 `
            -Operation 'List assured operator workspaces'
        foreach ($entry in @($response.items)) {
            if ([Guid]$entry.organization.organizationId -eq $WorkspaceId) {
                [void]$matches.Add($entry.membership)
            }
        }
        $page++
        if ($page -gt 100) {
            throw 'The assured operator workspace preflight exceeded 100 pages.'
        }
    } while ([bool]$response.hasMore)

    if ($matches.Count -ne 1 -or
        [string]$matches[0].status -cne 'active' -or
        [string]::IsNullOrWhiteSpace([string]$matches[0].subjectId)) {
        throw 'The assured operator must have one active membership in the target workspace.'
    }
}

function Invoke-SmokeGuestCreate {
    return Invoke-BunkFyAuthenticatedJsonRequestWithConvergence `
        -Client $client `
        -Origin $origin `
        -Path $guestPath `
        -Method POST `
        -TenantId $WorkspaceId.ToString('D') `
        -AccessToken $assuredToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body ([ordered]@{
            operationId = $guestOperationId.ToString('D')
            displayName = 'BunkFy data rights verification'
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

function Invoke-SmokeGuestArchive {
    return Invoke-BunkFyAuthenticatedJsonRequestWithConvergence `
        -Client $client `
        -Origin $origin `
        -Path "$guestPath/$($guestId.ToString('D'))/archive" `
        -Method POST `
        -TenantId $WorkspaceId.ToString('D') `
        -AccessToken $assuredToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body ([ordered]@{
            operationId = $guestArchiveOperationId.ToString('D')
            expectedVersion = $guestVersion
            confirmed = $true
        }) `
        -ExpectedStatus 200 `
        -Operation 'Archive synthetic Guest' `
        -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
        -PollIntervalMilliseconds $PollIntervalMilliseconds `
        -RetryableProblemCodes @('Guests.CountryPolicyDenied.MissingBinding')
}

function Invoke-SmokeCaseMutation {
    param(
        [Parameter(Mandatory = $true)][string] $Suffix,
        [Parameter(Mandatory = $true)][object] $Body,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    return Read-SmokeJson `
        -Response (Invoke-SmokeJsonRequest `
            -Path "$casePath/$($caseId.ToString('D'))/$Suffix" `
            -Method POST `
            -Token $assuredToken `
            -Body $Body) `
        -ExpectedStatus 200 `
        -Operation $Operation
}

function Wait-SmokeExportArtifact {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $artifact = Read-SmokeJson `
            -Response (Invoke-SmokeJsonRequest `
                -Path "$casePath/$($caseId.ToString('D'))/export" `
                -Method GET `
                -Token $assuredToken `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read Data Rights export artifact'
        if ([Guid]$artifact.id -ne $artifactId -or
            [Guid]$artifact.caseId -ne $caseId -or
            [Guid]$artifact.propertyId -ne $PropertyId -or
            [long]$artifact.decisionRevision -ne $caseDecisionRevision -or
            [int]$artifact.selectedSubjectCount -ne 1) {
            throw 'The Data Rights export artifact changed its approved coordinates.'
        }

        $status = [int]$artifact.status
        if ($status -eq 3) {
            return $artifact
        }
        if ($status -notin @(1, 2)) {
            throw "The Data Rights export entered unexpected status '$status'."
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "The Data Rights export did not become available within $ConvergenceTimeoutSeconds seconds."
}

function Wait-SmokeCaseCompleted {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $case = Read-SmokeJson `
            -Response (Invoke-SmokeJsonRequest `
                -Path "$casePath/$($caseId.ToString('D'))" `
                -Method GET `
                -Token $assuredToken `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read Data Rights case completion'
        if ([Guid]$case.id -ne $caseId -or
            [Guid]$case.propertyId -ne $PropertyId -or
            [int]$case.requestedOperations -ne 1 -or
            [int]$case.decision -ne 1 -or
            [int]$case.decisionReason -ne 1 -or
            [long]$case.decisionRevision -ne $caseDecisionRevision -or
            [int]$case.selectedSubjectCount -ne 1) {
            throw 'The completed Data Rights case changed its approved scope.'
        }
        if ([int]$case.status -eq 9) {
            return $case
        }
        if ([int]$case.status -notin @(5, 7)) {
            throw "The Data Rights case entered unexpected status '$([int]$case.status)'."
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "The Data Rights case did not complete within $ConvergenceTimeoutSeconds seconds."
}

function Get-SmokeResponseHeader {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpResponseMessage] $Response,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $values = $null
    if ($Response.Headers.TryGetValues($Name, [ref]$values) -or
        $Response.Content.Headers.TryGetValues($Name, [ref]$values)) {
        return @($values) -join ', '
    }
    return $null
}

function Invoke-SmokeExportDownload {
    param([Parameter(Mandatory = $true)][string] $Token)

    $path = "$casePath/$($caseId.ToString('D'))/export/$($artifactId.ToString('D'))/download"
    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Get,
        [Uri]::new($origin, $path))
    $cancellation = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($RequestTimeoutSeconds))
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new(
            'Bearer',
            $Token)
        [void]$request.Headers.TryAddWithoutValidation(
            'X-Tenant-Id',
            $WorkspaceId.ToString('D'))
        [void]$request.Headers.Accept.ParseAdd('application/json')
        $response = $client.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancellation.Token).GetAwaiter().GetResult()
        try {
            $contentLength = $response.Content.Headers.ContentLength
            if ($null -ne $contentLength -and
                $contentLength -gt $script:MaximumExportBodyBytes) {
                throw "Data Rights export response exceeds $script:MaximumExportBodyBytes bytes."
            }

            $stream = $response.Content.ReadAsStreamAsync(
                $cancellation.Token).GetAwaiter().GetResult()
            try {
                $buffer = [byte[]]::new(8192)
                $body = [IO.MemoryStream]::new()
                try {
                    while (($read = $stream.ReadAsync(
                                $buffer,
                                0,
                                $buffer.Length,
                                $cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
                        if ($body.Length + $read -gt $script:MaximumExportBodyBytes) {
                            throw "Data Rights export response exceeds $script:MaximumExportBodyBytes bytes."
                        }
                        $body.Write($buffer, 0, $read)
                    }
                    $bodyBytes = $body.ToArray()
                }
                finally {
                    [Array]::Clear($buffer, 0, $buffer.Length)
                    $body.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }

            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Body = $bodyBytes
                ContentType = Get-SmokeResponseHeader -Response $response -Name 'Content-Type'
                ContentDisposition = Get-SmokeResponseHeader -Response $response -Name 'Content-Disposition'
                CacheControl = Get-SmokeResponseHeader -Response $response -Name 'Cache-Control'
                Pragma = Get-SmokeResponseHeader -Response $response -Name 'Pragma'
                Expires = Get-SmokeResponseHeader -Response $response -Name 'Expires'
                XContentTypeOptions = Get-SmokeResponseHeader -Response $response -Name 'X-Content-Type-Options'
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch [OperationCanceledException] {
        throw "Data Rights export download exceeded the $RequestTimeoutSeconds-second timeout."
    }
    finally {
        $cancellation.Dispose()
        $request.Dispose()
    }
}

function Assert-SmokeJsonPropertySet {
    param(
        [Parameter(Mandatory = $true)][Text.Json.JsonElement] $Element,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $actual = @($Element.EnumerateObject() | ForEach-Object { $_.Name } | Sort-Object)
    $orderedExpected = @($Expected | Sort-Object)
    if (($actual -join '|') -cne ($orderedExpected -join '|')) {
        throw "$Context has an unexpected JSON property set."
    }
}

function Test-SmokeExportShape {
    param([Parameter(Mandatory = $true)][byte[]] $Body)

    if ($Body.Length -le 0) {
        throw 'The protected Data Rights export download was empty.'
    }
    $stream = [IO.MemoryStream]::new($Body, $false)
    try {
        $document = [Text.Json.JsonDocument]::Parse($stream)
        try {
            $root = $document.RootElement
            Assert-SmokeJsonPropertySet `
                -Element $root `
                -Expected @(
                    'format',
                    'formatVersion',
                    'caseType',
                    'scopeType',
                    'decisionRevision',
                    'generatedAtUtc',
                    'expiresAtUtc',
                    'subjects',
                    'summary') `
                -Context 'Data Rights export root'
            if ($root.GetProperty('format').GetString() -cne 'bunkfy.data-rights.export' -or
                $root.GetProperty('formatVersion').GetInt32() -ne 1 -or
                $root.GetProperty('caseType').GetString() -cne 'guestRights' -or
                $root.GetProperty('scopeType').GetString() -cne 'property' -or
                $root.GetProperty('decisionRevision').GetInt64() -ne $caseDecisionRevision) {
                throw 'The protected Data Rights export root contract is invalid.'
            }

            $subjects = @($root.GetProperty('subjects').EnumerateArray())
            if ($subjects.Count -ne 1) {
                throw 'The protected Data Rights export must contain one selected subject.'
            }
            $subject = $subjects[0]
            Assert-SmokeJsonPropertySet `
                -Element $subject `
                -Expected @('coordinate', 'ownerDescriptor', 'records', 'recordCount') `
                -Context 'Data Rights export subject'
            $coordinate = $subject.GetProperty('coordinate')
            Assert-SmokeJsonPropertySet `
                -Element $coordinate `
                -Expected @('owner', 'recordType', 'recordId', 'recordVersion') `
                -Context 'Data Rights export subject coordinate'
            if ($coordinate.GetProperty('owner').GetString() -cne 'guests' -or
                $coordinate.GetProperty('recordType').GetString() -cne 'guest-profile' -or
                $coordinate.GetProperty('recordId').GetGuid() -ne $guestId -or
                $coordinate.GetProperty('recordVersion').GetInt64() -ne $guestVersion) {
                throw 'The protected Data Rights export contains a different subject coordinate.'
            }

            $records = @($subject.GetProperty('records').EnumerateArray())
            $recordCount = $subject.GetProperty('recordCount').GetInt32()
            if ($recordCount -le 0 -or $records.Count -ne $recordCount) {
                throw 'The protected Data Rights export subject record count is invalid.'
            }
            $summary = $root.GetProperty('summary')
            Assert-SmokeJsonPropertySet `
                -Element $summary `
                -Expected @('subjectCount', 'recordCount') `
                -Context 'Data Rights export summary'
            if ($summary.GetProperty('subjectCount').GetInt32() -ne 1 -or
                $summary.GetProperty('recordCount').GetInt32() -ne $recordCount) {
                throw 'The protected Data Rights export summary is inconsistent.'
            }

            return [pscustomobject]@{
                FormatVersion = 1
                SubjectCount = 1
                RecordCount = $recordCount
                GeneratedAtUtc = $root.GetProperty('generatedAtUtc').GetDateTimeOffset()
                ExpiresAtUtc = $root.GetProperty('expiresAtUtc').GetDateTimeOffset()
            }
        }
        finally {
            $document.Dispose()
        }
    }
    catch [Text.Json.JsonException] {
        throw 'The protected Data Rights export returned invalid JSON.'
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-SmokeDownloadHeaders {
    param([Parameter(Mandatory = $true)][object] $Download)

    $failures = [Collections.Generic.List[string]]::new()
    if ([string]$Download.ContentType -cnotmatch '^application/json(?:;|$)') {
        $failures.Add('content-type')
    }
    if ([string]$Download.ContentDisposition -cnotmatch '^attachment;' -or
        [string]$Download.ContentDisposition -cnotmatch '(?i)\.json') {
        $failures.Add('content-disposition')
    }
    if ([string]$Download.CacheControl -cnotmatch '(?i)(^|,)\s*no-store\s*(,|$)' -or
        [string]$Download.CacheControl -cnotmatch '(?i)(^|,)\s*no-cache\s*(,|$)') {
        $failures.Add('cache-control')
    }
    if ([string]$Download.Pragma -cnotmatch '(?i)(^|,)\s*no-cache\s*(,|$)') {
        $failures.Add('pragma')
    }
    if ([string]$Download.Expires -cne '0') {
        $failures.Add('expires')
    }
    if ([string]$Download.XContentTypeOptions -cnotmatch
        '(?i)^\s*nosniff(?:\s*,\s*nosniff)*\s*$') {
        $failures.Add('x-content-type-options')
    }
    if ($failures.Count -gt 0) {
        throw "The protected Data Rights export response headers are incomplete or unsafe: $($failures -join ', ')."
    }
}

$workflowError = $null
$cleanupError = $null
try {
    try {
        $releaseIdBefore = Assert-BunkFyPublicApiReleaseIdentity `
            -Client $client `
            -Origin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -TimeoutSeconds $RequestTimeoutSeconds

        Get-SmokeWorkspaceMembership
        $property = Read-SmokeJson `
            -Response (Invoke-SmokeJsonRequest `
                -Path "/api/properties/$($PropertyId.ToString('D'))" `
                -Method GET `
                -Token $assuredToken `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read Data Rights smoke property'
        if ([Guid]$property.propertyId -ne $PropertyId) {
            throw 'The Data Rights property preflight returned a different property.'
        }
        $checks.Add([ordered]@{ name = 'scoped-assured-operator-and-property-preflight'; status = 'passed' })

        $deniedCases = Invoke-SmokeJsonRequest `
            -Path "${casePath}?page=1&pageSize=1" `
            -Method GET `
            -Token $deniedToken `
            -Body $null
        Assert-BunkFyAuthenticatedStatus `
            -Response $deniedCases `
            -ExpectedStatus 403 `
            -Operation 'Nonmember Data Rights case read'
        Clear-SmokeResponseBody -Response $deniedCases
        $checks.Add([ordered]@{ name = 'nonmember-case-access-denied'; status = 'passed' })

        if (-not $PSCmdlet.ShouldProcess(
                "property $($PropertyId.ToString('D'))",
                'Create a synthetic Guest and complete a protected Data Rights access export')) {
            return
        }

        $guest = Invoke-SmokeGuestCreate
        $guestId = [Guid]$guest.guestId
        $guestVersion = [long]$guest.version
        $guestCreated = $true
        if ($guestId -eq [Guid]::Empty -or
            [int]$guest.status -ne 1 -or
            $guestVersion -ne 1) {
            throw 'Synthetic Guest creation returned an unexpected receipt.'
        }
        $checks.Add([ordered]@{ name = 'synthetic-guest-created'; status = 'passed' })

        $case = Read-SmokeJson `
            -Response (Invoke-SmokeJsonRequest `
                -Path $casePath `
                -Method POST `
                -Token $assuredToken `
                -Body ([ordered]@{
                    requestedOperations = 1
                    restrictionDirective = 0
                    requesterRelationship = 3
                })) `
            -ExpectedStatus 200 `
            -Operation 'Create controller-initiated Data Rights case'
        $caseId = [Guid]$case.id
        if ($caseId -eq [Guid]::Empty -or
            [Guid]$case.propertyId -ne $PropertyId -or
            [int]$case.type -ne 1 -or
            [int]$case.requestedOperations -ne 1 -or
            [int]$case.requesterRelationship -ne 3 -or
            [int]$case.verificationStatus -ne 4 -or
            [int]$case.routingStatus -ne 3 -or
            [int]$case.status -ne 1 -or
            [int]$case.selectedSubjectCount -ne 0) {
            throw 'Controller-initiated Data Rights case creation returned an unexpected state.'
        }

        $case = Invoke-SmokeCaseMutation `
            -Suffix 'discovery' `
            -Body ([ordered]@{ expectedVersion = [long]$case.version }) `
            -Operation 'Begin Data Rights subject discovery'
        if ([int]$case.status -ne 2) {
            throw 'The Data Rights case did not enter Discovery.'
        }
        $checks.Add([ordered]@{ name = 'controller-initiated-case-entered-discovery'; status = 'passed' })

        $discovery = Read-SmokeJson `
            -Response (Invoke-SmokeJsonRequest `
                -Path "$casePath/$($caseId.ToString('D'))/subjects/discover" `
                -Method POST `
                -Token $assuredToken `
                -Body ([ordered]@{
                    recordId = $guestId.ToString('D')
                    email = $null
                    phone = $null
                    name = $null
                    dateOfBirth = $null
                    accountSubjectId = $null
                    ownerKey = 'guests'
                })) `
            -ExpectedStatus 200 `
            -Operation 'Discover exact synthetic Guest subject'
        $candidates = @($discovery.candidates)
        if ($candidates.Count -ne 1 -or
            [bool]$discovery.limitReached -or
            [string]$candidates[0].coordinate.ownerKey -cne 'guests' -or
            [string]$candidates[0].coordinate.recordType -cne 'guest-profile' -or
            [Guid]$candidates[0].coordinate.recordId -ne $guestId -or
            [long]$candidates[0].coordinate.recordVersion -ne $guestVersion) {
            throw 'Exact Guest subject discovery returned an ambiguous or different coordinate.'
        }

        $case = Invoke-SmokeCaseMutation `
            -Suffix 'subjects/select' `
            -Body ([ordered]@{
                coordinate = [ordered]@{
                    ownerKey = 'guests'
                    recordType = 'guest-profile'
                    recordId = $guestId.ToString('D')
                    recordVersion = $guestVersion
                }
                expectedVersion = [long]$case.version
            }) `
            -Operation 'Select exact synthetic Guest subject'
        if ([int]$case.status -ne 2 -or [int]$case.selectedSubjectCount -ne 1) {
            throw 'The Data Rights case did not retain exactly one selected Guest.'
        }
        $checks.Add([ordered]@{ name = 'exact-guest-subject-discovered-and-selected'; status = 'passed' })

        $case = Invoke-SmokeCaseMutation `
            -Suffix 'review' `
            -Body ([ordered]@{ expectedVersion = [long]$case.version }) `
            -Operation 'Require Data Rights review'
        if ([int]$case.status -ne 3 -or [int]$case.selectedSubjectCount -ne 1) {
            throw 'Data Rights review changed the selected Guest scope.'
        }
        $case = Invoke-SmokeCaseMutation `
            -Suffix 'decision' `
            -Body ([ordered]@{ expectedVersion = [long]$case.version }) `
            -Operation 'Begin Data Rights decision'
        if ([int]$case.status -ne 4) {
            throw 'The Data Rights case did not enter DecisionPending.'
        }
        $case = Invoke-SmokeCaseMutation `
            -Suffix 'decision/outcome' `
            -Body ([ordered]@{
                decision = 1
                reason = 1
                expectedVersion = [long]$case.version
            }) `
            -Operation 'Approve Data Rights access export'
        $caseDecisionRevision = [long]$case.decisionRevision
        if ([int]$case.status -ne 5 -or
            [int]$case.decision -ne 1 -or
            [int]$case.decisionReason -ne 1 -or
            $caseDecisionRevision -le 0 -or
            [int]$case.selectedSubjectCount -ne 1) {
            throw 'The Data Rights access export decision was not approved with immutable scope.'
        }
        $checks.Add([ordered]@{ name = 'review-and-decision-approved'; status = 'passed' })

        $exportRequestBody = [ordered]@{
            idempotencyKey = $exportIdempotencyKey.ToString('D')
            expectedVersion = [long]$case.version
        }
        $artifact = Read-SmokeJson `
            -Response (Invoke-SmokeJsonRequest `
                -Path "$casePath/$($caseId.ToString('D'))/export" `
                -Method POST `
                -Token $assuredToken `
                -Body $exportRequestBody) `
            -ExpectedStatus 200 `
            -Operation 'Request protected Data Rights export'
        $artifactId = [Guid]$artifact.id
        $artifactRequestedAtUtc = [DateTimeOffset]$artifact.requestedAtUtc
        $artifactExpiresAtUtc = [DateTimeOffset]$artifact.expiresAtUtc
        if ($artifactId -eq [Guid]::Empty -or
            [Guid]$artifact.caseId -ne $caseId -or
            [Guid]$artifact.propertyId -ne $PropertyId -or
            [long]$artifact.decisionRevision -ne $caseDecisionRevision -or
            [int]$artifact.selectedSubjectCount -ne 1 -or
            [int]$artifact.status -notin @(1, 2, 3)) {
            throw 'Protected Data Rights export request returned unexpected coordinates.'
        }
        $checks.Add([ordered]@{ name = 'export-generation-requested'; status = 'passed' })

        $replayedArtifact = Read-SmokeJson `
            -Response (Invoke-SmokeJsonRequest `
                -Path "$casePath/$($caseId.ToString('D'))/export" `
                -Method POST `
                -Token $assuredToken `
                -Body $exportRequestBody) `
            -ExpectedStatus 200 `
            -Operation 'Replay protected Data Rights export request'
        if ([Guid]$replayedArtifact.id -ne $artifactId -or
            [Guid]$replayedArtifact.caseId -ne $caseId -or
            [long]$replayedArtifact.decisionRevision -ne $caseDecisionRevision -or
            -not (Test-SmokeTimestampReplayEquivalent `
                -Left ([DateTimeOffset]$replayedArtifact.requestedAtUtc) `
                -Right $artifactRequestedAtUtc) -or
            -not (Test-SmokeTimestampReplayEquivalent `
                -Left ([DateTimeOffset]$replayedArtifact.expiresAtUtc) `
                -Right $artifactExpiresAtUtc)) {
            throw 'The exact Data Rights export replay did not return the same artifact.'
        }
        $checks.Add([ordered]@{ name = 'export-request-replay-stable'; status = 'passed' })

        $secondArtifact = Invoke-SmokeJsonRequest `
            -Path "$casePath/$($caseId.ToString('D'))/export" `
            -Method POST `
            -Token $assuredToken `
            -Body ([ordered]@{
                idempotencyKey = [Guid]::NewGuid().ToString('D')
                expectedVersion = [long]$case.version
            })
        if ($secondArtifact.StatusCode -ne 409 -or
            (Get-BunkFyAuthenticatedProblemCode -Response $secondArtifact) -cne
                'DataRights.ExportArtifactAlreadyRequested') {
            throw 'A second Data Rights export artifact request did not fail closed.'
        }
        Clear-SmokeResponseBody -Response $secondArtifact
        $checks.Add([ordered]@{ name = 'second-artifact-request-denied'; status = 'passed' })

        $availableArtifact = Wait-SmokeExportArtifact
        $artifactRequestedAtUtc = [DateTimeOffset]$availableArtifact.requestedAtUtc
        $artifactExpiresAtUtc = [DateTimeOffset]$availableArtifact.expiresAtUtc
        $checks.Add([ordered]@{ name = 'worker-export-generation-converged'; status = 'passed' })

        [void](Wait-SmokeCaseCompleted)
        $checks.Add([ordered]@{ name = 'case-completed-with-approved-scope'; status = 'passed' })

        $unassuredDownload = Invoke-SmokeExportDownload -Token $unassuredToken
        if ($unassuredDownload.StatusCode -ne 401 -or
            (Get-BunkFyAuthenticatedProblemCode -Response $unassuredDownload) -cne
                'Security.InsufficientAuthentication') {
            throw 'The unassured Data Rights export download did not require step-up.'
        }
        Clear-SmokeResponseBody -Response $unassuredDownload
        $checks.Add([ordered]@{ name = 'unassured-export-download-denied'; status = 'passed' })

        $deniedDownload = Invoke-SmokeExportDownload -Token $deniedToken
        if ($deniedDownload.StatusCode -ne 403) {
            throw "The nonmember Data Rights export download returned HTTP $($deniedDownload.StatusCode); expected HTTP 403."
        }
        Clear-SmokeResponseBody -Response $deniedDownload
        $checks.Add([ordered]@{ name = 'nonmember-export-download-denied'; status = 'passed' })

        $firstDownload = Invoke-SmokeExportDownload -Token $assuredToken
        try {
            if ($firstDownload.StatusCode -ne 200) {
                throw "The protected Data Rights export download returned HTTP $($firstDownload.StatusCode); expected HTTP 200."
            }
            Assert-SmokeDownloadHeaders -Download $firstDownload
            $exportShape = Test-SmokeExportShape -Body $firstDownload.Body
            if ($exportShape.ExpiresAtUtc -ne $artifactExpiresAtUtc -or
                $exportShape.GeneratedAtUtc -lt $artifactRequestedAtUtc -or
                $exportShape.GeneratedAtUtc -ge $artifactExpiresAtUtc) {
                throw 'The protected Data Rights export timestamps do not match the artifact lifecycle.'
            }
            $downloadByteCount = $firstDownload.Body.Length
            $checks.Add([ordered]@{ name = 'protected-download-headers-and-shape-verified'; status = 'passed' })

            $secondDownload = Invoke-SmokeExportDownload -Token $assuredToken
            try {
                if ($secondDownload.StatusCode -ne 200) {
                    throw "The replayed Data Rights export download returned HTTP $($secondDownload.StatusCode); expected HTTP 200."
                }
                Assert-SmokeDownloadHeaders -Download $secondDownload
                [void](Test-SmokeExportShape -Body $secondDownload.Body)
                if ($secondDownload.Body.Length -ne $firstDownload.Body.Length) {
                    throw 'The replayed Data Rights export download changed byte length.'
                }
                $firstHash = [Security.Cryptography.SHA256]::HashData($firstDownload.Body)
                $secondHash = [Security.Cryptography.SHA256]::HashData($secondDownload.Body)
                try {
                    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                            $firstHash,
                            $secondHash)) {
                        throw 'The replayed Data Rights export download changed content.'
                    }
                }
                finally {
                    [Security.Cryptography.CryptographicOperations]::ZeroMemory($firstHash)
                    [Security.Cryptography.CryptographicOperations]::ZeroMemory($secondHash)
                }
                $checks.Add([ordered]@{ name = 'download-replay-stable'; status = 'passed' })
            }
            finally {
                Clear-SmokeResponseBody -Response $secondDownload
            }
        }
        finally {
            Clear-SmokeResponseBody -Response $firstDownload
        }
    }
    catch {
        $workflowError = $_
    }
    finally {
        if ($guestCreated -and -not $guestArchived) {
            try {
                $archived = Invoke-SmokeGuestArchive
                if ([Guid]$archived.guestId -ne $guestId -or
                    [int]$archived.status -ne 2 -or
                    [long]$archived.version -le $guestVersion) {
                    throw 'Synthetic Guest archival returned an unexpected receipt.'
                }
                $guestArchived = $true
            }
            catch {
                $cleanupError = $_
            }
        }
    }

    if ($null -ne $cleanupError) {
        if ($null -ne $workflowError) {
            throw "Data Rights workflow failed ('$($workflowError.Exception.Message)') and synthetic Guest cleanup failed ('$($cleanupError.Exception.Message)')."
        }
        throw $cleanupError
    }
    if ($null -ne $workflowError) {
        throw $workflowError
    }

    if (-not $guestArchived) {
        throw 'The synthetic Guest was not archived.'
    }
    $checks.Add([ordered]@{ name = 'synthetic-guest-archived'; status = 'passed' })

    $artifactLifetime = $artifactExpiresAtUtc - $artifactRequestedAtUtc
    if ($artifactLifetime -lt [TimeSpan]::FromMinutes(5) -or
        $artifactLifetime -gt [TimeSpan]::FromDays(7)) {
        throw 'The Data Rights export artifact lifetime is outside the supported bounded policy.'
    }
    $artifactExpiryHours = $artifactLifetime.TotalHours
    $checks.Add([ordered]@{ name = 'artifact-expiry-bounded-and-scheduled'; status = 'passed' })

    $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds
    if ($observedReleaseId -cne $releaseIdBefore) {
        throw 'The public API release identity changed during Data Rights verification.'
    }
    $checks.Add([ordered]@{ name = 'release-identity-continuous'; status = 'passed' })
}
finally {
    $client.Dispose()
    $assuredToken = $null
    $unassuredToken = $null
    $deniedToken = $null
}

$evidence = [ordered]@{
    schemaVersion = 1
    evidenceKind = 'bunkfy-deployed-data-rights-access-export-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-fixture' }
    result = 'passed'
    workflow = [ordered]@{
        caseType = 'guest-rights'
        requestedOperation = 'access-export'
        requesterRelationship = 'controller-initiated'
        finalStatus = 'completed'
        selectedSubjectCount = 1
    }
    artifact = [ordered]@{
        finalStatus = 'available'
        formatVersion = [int]$exportShape.FormatVersion
        subjectCount = [int]$exportShape.SubjectCount
        recordCount = [int]$exportShape.RecordCount
        byteCount = $downloadByteCount
        expiryHours = $artifactExpiryHours
    }
    cleanup = [ordered]@{
        guestArchived = $guestArchived
        artifactDisposition = 'scheduled-expiry'
    }
    checks = @($checks)
    limitations = @(
        'browser-privacy-workflow-not-exercised',
        'multi-subject-and-large-exports-not-exercised',
        'independent-object-store-and-key-custody-not-inspected',
        'case-history-and-encrypted-artifact-retained-until-configured-lifecycle'
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

Write-Host "BunkFy deployed Data Rights access export verification passed for '$ExpectedReleaseId'."
Write-Host "Evidence: $OutputPath"
