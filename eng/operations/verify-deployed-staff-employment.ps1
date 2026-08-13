[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
    [Parameter(Mandatory = $true)][Guid] $WorkspaceId,
    [Parameter(Mandatory = $true)][Guid] $PropertyId,
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
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/staff-employment-$stamp.json"
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
    -EnvironmentVariable 'BUNKFY_SMOKE_STAFF_OPERATOR_TOKEN' `
    -Prompt 'Staff employment workflow operator access token'
$deniedToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $DeniedAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_STAFF_DENIED_TOKEN' `
    -Prompt 'Staff employment workflow nonmember access token'
if ([string]::IsNullOrWhiteSpace($operatorToken) -or
    [string]::IsNullOrWhiteSpace($deniedToken)) {
    throw 'Both Staff employment verification access tokens are required.'
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
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Deployed-Staff-Employment-Probe/1')

$checks = [Collections.Generic.List[object]]::new()
$staffPath = '/api/staff/members'
$propertyStaffPath = "/api/staff/properties/$($PropertyId.ToString('D'))/members"
$createOperationId = [Guid]::NewGuid()
$updateOperationId = [Guid]::NewGuid()
$assignmentOperationId = [Guid]::NewGuid()
$suspendOperationId = [Guid]::NewGuid()
$resumeOperationId = [Guid]::NewGuid()
$departOperationId = [Guid]::NewGuid()
$staffMemberId = $createOperationId
$staffCreateAttempted = $false
$staffDeparted = $false
$currentAssignmentsClosed = $false
$observedReleaseId = $null
$initialVersion = 0L
$finalVersion = 0L
$suffix = $createOperationId.ToString('N').Substring(0, 8)
$initialLabel = "BunkFy staff proof $suffix"
$updatedLabel = "BunkFy staff proof updated $suffix"
$effectiveDate = [DateOnly]::FromDateTime([DateTime]::UtcNow)
$effectiveDateText = $effectiveDate.ToString(
    'yyyy-MM-dd',
    [Globalization.CultureInfo]::InvariantCulture)
$changeReason = 'Synthetic deployment verification'

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

function Get-SmokeStaffDirectory {
    param(
        [Parameter(Mandatory = $true)][ValidateSet(1, 2, 3)][int] $Status,
        [Parameter(Mandatory = $true)][string] $Search
    )

    $encodedSearch = [Uri]::EscapeDataString($Search)
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "$staffPath`?search=$encodedSearch&status=$Status&page=1&pageSize=10" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read synthetic Staff directory result'
}

function Get-SmokePropertyStaffDirectory {
    param([Parameter(Mandatory = $true)][ValidateSet(1, 2, 3)][int] $Status)

    $encodedSearch = [Uri]::EscapeDataString($updatedLabel)
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "$propertyStaffPath`?search=$encodedSearch&status=$Status&page=1&pageSize=10" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read synthetic property Staff directory result'
}

function Get-SmokeStaffDirectoryMember {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "$staffPath/$($staffMemberId.ToString('D'))" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read synthetic Staff directory member'
}

function Get-SmokeStaffProfile {
    return Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "$staffPath/$($staffMemberId.ToString('D'))/profile" `
            -Method GET `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read synthetic Staff profile'
}

function Invoke-SmokeStaffCreate {
    param([Parameter(Mandatory = $true)][string] $DisplayName)

    return Invoke-SmokeApi `
        -Path $staffPath `
        -Method POST `
        -Body ([ordered]@{
            operationId = $createOperationId.ToString('D')
            displayName = $DisplayName
            legalName = $null
            workEmail = $null
            workPhone = $null
            employeeNumber = $null
            jobTitle = $null
            department = $null
        })
}

function Invoke-SmokeStaffUpdate {
    param(
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][string] $DisplayName,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion
    )

    return Invoke-SmokeApi `
        -Path "$staffPath/$($staffMemberId.ToString('D'))" `
        -Method PUT `
        -Body ([ordered]@{
            operationId = $OperationId.ToString('D')
            displayName = $DisplayName
            legalName = $null
            workEmail = $null
            workPhone = $null
            employeeNumber = $null
            jobTitle = $null
            department = $null
            expectedVersion = $ExpectedVersion
        })
}

function Invoke-SmokeStaffAssignment {
    param(
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][bool] $IsPrimary,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion,
        [switch] $AllowProjectionConvergence
    )

    $body = [ordered]@{
        operationId = $OperationId.ToString('D')
        propertyJobTitle = $null
        isPrimary = $IsPrimary
        effectiveFrom = $effectiveDateText
        expectedVersion = $ExpectedVersion
    }
    if ($AllowProjectionConvergence) {
        return Invoke-BunkFyAuthenticatedJsonRequestWithConvergence `
            -Client $client `
            -Origin $origin `
            -Path "$propertyStaffPath/$($staffMemberId.ToString('D'))/assignment" `
            -Method PUT `
            -TenantId $WorkspaceId.ToString('D') `
            -AccessToken $operatorToken `
            -TimeoutSeconds $RequestTimeoutSeconds `
            -Body $body `
            -ExpectedStatus 200 `
            -Operation 'Assign synthetic Staff to property' `
            -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
            -PollIntervalMilliseconds $PollIntervalMilliseconds `
            -RetryableProblemCodes @('Staff.PropertyUnavailable')
    }

    return Invoke-SmokeApi `
        -Path "$propertyStaffPath/$($staffMemberId.ToString('D'))/assignment" `
        -Method PUT `
        -Body $body
}

function Invoke-SmokeStaffLifecycle {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('suspend', 'resume', 'depart')]
        [string] $Action,
        [Parameter(Mandatory = $true)][Guid] $OperationId,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion
    )

    $body = [ordered]@{
        operationId = $OperationId.ToString('D')
        reason = $changeReason
        expectedVersion = $ExpectedVersion
    }
    if ($Action -ceq 'depart') {
        $body = [ordered]@{
            operationId = $OperationId.ToString('D')
            effectiveOn = $effectiveDateText
            reason = $changeReason
            expectedVersion = $ExpectedVersion
        }
    }
    return Invoke-SmokeApi `
        -Path "$staffPath/$($staffMemberId.ToString('D'))/$Action" `
        -Method POST `
        -Body $body
}

function Assert-SmokeReceipt {
    param(
        [Parameter(Mandatory = $true)][object] $Receipt,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus,
        [Parameter(Mandatory = $true)][long] $ExpectedVersion,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ([Guid]$Receipt.staffMemberId -ne $staffMemberId -or
        [int]$Receipt.status -ne $ExpectedStatus -or
        [long]$Receipt.version -ne $ExpectedVersion -or
        [DateTimeOffset]$Receipt.completedAtUtc -eq [DateTimeOffset]::MinValue) {
        throw "$Operation returned an unexpected Staff mutation receipt."
    }
}

function Assert-SmokeReceiptReplay {
    param(
        [Parameter(Mandatory = $true)][object] $Original,
        [Parameter(Mandatory = $true)][object] $Replay,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    if ([Guid]$Replay.staffMemberId -ne [Guid]$Original.staffMemberId -or
        [int]$Replay.status -ne [int]$Original.status -or
        [long]$Replay.version -ne [long]$Original.version -or
        -not (Test-SmokeTimestampReplayEquivalent `
            -Left ([DateTimeOffset]$Replay.completedAtUtc) `
            -Right ([DateTimeOffset]$Original.completedAtUtc))) {
        throw "$Operation did not return the stable Staff mutation receipt."
    }
}

function Complete-SmokeStaffCleanup {
    if (-not $staffCreateAttempted) {
        return
    }

    $response = Invoke-SmokeApi `
        -Path "$staffPath/$($staffMemberId.ToString('D'))/profile" `
        -Method GET `
        -Body $null
    if ($response.StatusCode -eq 404) {
        Clear-SmokeResponseBody -Response $response
        return
    }
    $profile = Read-SmokeJson `
        -Response $response `
        -ExpectedStatus 200 `
        -Operation 'Read Staff profile during cleanup'
    if ([int]$profile.status -eq 3) {
        $staffDeparted = $true
        $finalVersion = [long]$profile.version
        $currentAssignmentsClosed = @($profile.assignments | Where-Object {
                [bool]$_.isCurrent
            }).Count -eq 0
        return
    }
    if ([int]$profile.status -notin @(1, 2)) {
        throw "Staff proof cleanup found unsupported status '$([int]$profile.status)'."
    }

    $departed = Read-SmokeJson `
        -Response (Invoke-SmokeStaffLifecycle `
            -Action depart `
            -OperationId ([Guid]::NewGuid()) `
            -ExpectedVersion ([long]$profile.version)) `
        -ExpectedStatus 200 `
        -Operation 'Depart synthetic Staff during cleanup'
    if ([int]$departed.status -ne 3) {
        throw 'Staff proof cleanup did not reach departed status.'
    }
    $terminal = Get-SmokeStaffProfile
    $staffDeparted = [int]$terminal.status -eq 3
    $finalVersion = [long]$terminal.version
    $currentAssignmentsClosed = @($terminal.assignments | Where-Object {
            [bool]$_.isCurrent
        }).Count -eq 0
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
        $property = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($PropertyId.ToString('D'))" `
                -Method GET `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read Staff proof property'
        if ([Guid]$property.propertyId -ne $PropertyId) {
            throw 'The Staff proof property preflight returned a different property.'
        }
        $checks.Add([ordered]@{ name = 'scoped-operator-and-property-preflight'; status = 'passed' })

        $deniedDirectory = Invoke-SmokeApi `
            -Path "$staffPath`?page=1&pageSize=1" `
            -Method GET `
            -Body $null `
            -Token $deniedToken
        Assert-BunkFyAuthenticatedStatus `
            -Response $deniedDirectory `
            -ExpectedStatus 403 `
            -Operation 'Nonmember Staff directory read'
        Clear-SmokeResponseBody -Response $deniedDirectory
        $checks.Add([ordered]@{ name = 'nonmember-staff-directory-denied'; status = 'passed' })

        if (-not $PSCmdlet.ShouldProcess(
                "workspace $($WorkspaceId.ToString('D'))",
                'Create, assign, suspend, resume, and depart a synthetic Staff profile')) {
            return
        }

        $staffCreateAttempted = $true
        $created = Read-SmokeJson `
            -Response (Invoke-SmokeStaffCreate -DisplayName $initialLabel) `
            -ExpectedStatus 200 `
            -Operation 'Create synthetic Staff profile'
        if ([Guid]$created.staffMemberId -ne $staffMemberId -or
            [string]$created.displayName -cne $initialLabel -or
            [int]$created.status -ne 1 -or
            [long]$created.version -ne 1 -or
            @($created.assignments).Count -ne 0) {
            throw 'Synthetic Staff creation returned an unexpected directory member.'
        }
        $initialVersion = [long]$created.version
        $checks.Add([ordered]@{ name = 'staff-created-with-minimal-unlinked-profile'; status = 'passed' })

        $createReplay = Read-SmokeJson `
            -Response (Invoke-SmokeStaffCreate -DisplayName $initialLabel) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Staff creation'
        if ([Guid]$createReplay.staffMemberId -ne $staffMemberId -or
            [string]$createReplay.displayName -cne $initialLabel -or
            [int]$createReplay.status -ne 1 -or
            [long]$createReplay.version -ne 1 -or
            @($createReplay.assignments).Count -ne 0) {
            throw 'The exact Staff create replay did not return the stable directory member.'
        }
        $checks.Add([ordered]@{ name = 'staff-create-replay-stable'; status = 'passed' })

        $createConflict = Invoke-SmokeStaffCreate -DisplayName "$initialLabel conflict"
        Assert-SmokeProblem `
            -Response $createConflict `
            -ExpectedStatus 409 `
            -ExpectedCode 'Staff.CreationOperationConflict' `
            -Operation 'Conflicting Staff creation operation reuse'
        $checks.Add([ordered]@{ name = 'staff-create-conflict-rejected'; status = 'passed' })

        $directoryMember = Get-SmokeStaffDirectoryMember
        $profile = Get-SmokeStaffProfile
        $activeDirectory = Get-SmokeStaffDirectory -Status 1 -Search $initialLabel
        $activeMatches = @($activeDirectory.items | Where-Object {
                [Guid]$_.staffMemberId -eq $staffMemberId
            })
        if ([Guid]$directoryMember.staffMemberId -ne $staffMemberId -or
            [string]$directoryMember.displayName -cne $initialLabel -or
            [long]$directoryMember.version -ne 1 -or
            @($directoryMember.assignments).Count -ne 0 -or
            [Guid]$profile.staffMemberId -ne $staffMemberId -or
            [string]$profile.displayName -cne $initialLabel -or
            [long]$profile.version -ne 1 -or
            $null -ne $profile.legalName -or
            $null -ne $profile.workEmail -or
            $null -ne $profile.workPhone -or
            $null -ne $profile.employeeNumber -or
            $null -ne $profile.jobTitle -or
            $null -ne $profile.department -or
            $null -ne $profile.authSubjectId -or
            @($profile.assignments).Count -ne 0 -or
            $activeMatches.Count -ne 1 -or
            [int]$activeMatches[0].status -ne 1 -or
            [int]$activeMatches[0].currentPropertyCount -ne 0) {
            throw 'The Staff directory and sensitive profile did not expose the exact minimal unlinked record.'
        }
        $checks.Add([ordered]@{ name = 'staff-directory-and-sensitive-profile-coherent'; status = 'passed' })

        $updated = Read-SmokeJson `
            -Response (Invoke-SmokeStaffUpdate `
                -OperationId $updateOperationId `
                -DisplayName $updatedLabel `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Update synthetic Staff profile'
        Assert-SmokeReceipt `
            -Receipt $updated `
            -ExpectedStatus 1 `
            -ExpectedVersion 2 `
            -Operation 'Synthetic Staff update'
        $checks.Add([ordered]@{ name = 'staff-versioned-update-recorded'; status = 'passed' })

        $updateReplay = Read-SmokeJson `
            -Response (Invoke-SmokeStaffUpdate `
                -OperationId $updateOperationId `
                -DisplayName $updatedLabel `
                -ExpectedVersion 1) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Staff update'
        Assert-SmokeReceiptReplay `
            -Original $updated `
            -Replay $updateReplay `
            -Operation 'Exact Staff update replay'
        $checks.Add([ordered]@{ name = 'staff-update-replay-stable'; status = 'passed' })

        $updateConflict = Invoke-SmokeStaffUpdate `
            -OperationId $updateOperationId `
            -DisplayName "$updatedLabel conflict" `
            -ExpectedVersion 1
        Assert-SmokeProblem `
            -Response $updateConflict `
            -ExpectedStatus 409 `
            -ExpectedCode 'Staff.ProfileUpdateOperationConflict' `
            -Operation 'Conflicting Staff update operation reuse'
        $checks.Add([ordered]@{ name = 'staff-update-conflict-rejected'; status = 'passed' })

        $staleUpdate = Invoke-SmokeStaffUpdate `
            -OperationId ([Guid]::NewGuid()) `
            -DisplayName $updatedLabel `
            -ExpectedVersion 1
        Assert-SmokeProblem `
            -Response $staleUpdate `
            -ExpectedStatus 409 `
            -ExpectedCode 'Staff.VersionConflict' `
            -Operation 'Stale Staff update'
        $checks.Add([ordered]@{ name = 'staff-stale-update-rejected'; status = 'passed' })

        $updatedProfile = Get-SmokeStaffProfile
        if ([string]$updatedProfile.displayName -cne $updatedLabel -or
            [long]$updatedProfile.version -ne 2 -or
            $null -ne $updatedProfile.authSubjectId) {
            throw 'The Staff profile did not expose the committed versioned update.'
        }
        $checks.Add([ordered]@{ name = 'staff-update-visible'; status = 'passed' })

        $assigned = Invoke-SmokeStaffAssignment `
            -OperationId $assignmentOperationId `
            -IsPrimary $true `
            -ExpectedVersion 2 `
            -AllowProjectionConvergence
        Assert-SmokeReceipt `
            -Receipt $assigned `
            -ExpectedStatus 1 `
            -ExpectedVersion 3 `
            -Operation 'Synthetic Staff property assignment'
        $checks.Add([ordered]@{ name = 'staff-property-assignment-recorded'; status = 'passed' })

        $assignmentReplay = Read-SmokeJson `
            -Response (Invoke-SmokeStaffAssignment `
                -OperationId $assignmentOperationId `
                -IsPrimary $true `
                -ExpectedVersion 2) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Staff property assignment'
        Assert-SmokeReceiptReplay `
            -Original $assigned `
            -Replay $assignmentReplay `
            -Operation 'Exact Staff property assignment replay'
        $checks.Add([ordered]@{ name = 'staff-assignment-replay-stable'; status = 'passed' })

        $assignmentConflict = Invoke-SmokeStaffAssignment `
            -OperationId $assignmentOperationId `
            -IsPrimary $false `
            -ExpectedVersion 2
        Assert-SmokeProblem `
            -Response $assignmentConflict `
            -ExpectedStatus 409 `
            -ExpectedCode 'Staff.AssignmentOperationConflict' `
            -Operation 'Conflicting Staff assignment operation reuse'
        $checks.Add([ordered]@{ name = 'staff-assignment-conflict-rejected'; status = 'passed' })

        $assignedDirectory = Get-SmokeStaffDirectoryMember
        $assignedProfile = Get-SmokeStaffProfile
        $propertyDirectory = Get-SmokePropertyStaffDirectory -Status 1
        $propertyMatches = @($propertyDirectory.items | Where-Object {
                [Guid]$_.staffMemberId -eq $staffMemberId
            })
        $directoryAssignments = @($assignedDirectory.assignments)
        $profileAssignments = @($assignedProfile.assignments)
        if ([long]$assignedDirectory.version -ne 3 -or
            $directoryAssignments.Count -ne 1 -or
            [Guid]$directoryAssignments[0].propertyId -ne $PropertyId -or
            -not [bool]$directoryAssignments[0].isPrimary -or
            $profileAssignments.Count -ne 1 -or
            [Guid]$profileAssignments[0].propertyId -ne $PropertyId -or
            -not [bool]$profileAssignments[0].isPrimary -or
            -not [bool]$profileAssignments[0].isCurrent -or
            [long]$profileAssignments[0].assignedAtVersion -ne 3 -or
            $propertyMatches.Count -ne 1 -or
            [Guid]$propertyMatches[0].assignment.propertyId -ne $PropertyId -or
            -not [bool]$propertyMatches[0].assignment.isPrimary) {
            throw 'The canonical and property Staff directories did not expose one current primary assignment.'
        }
        $checks.Add([ordered]@{ name = 'staff-canonical-and-property-assignment-visible'; status = 'passed' })

        $suspended = Read-SmokeJson `
            -Response (Invoke-SmokeStaffLifecycle `
                -Action suspend `
                -OperationId $suspendOperationId `
                -ExpectedVersion 3) `
            -ExpectedStatus 200 `
            -Operation 'Suspend synthetic Staff member'
        Assert-SmokeReceipt `
            -Receipt $suspended `
            -ExpectedStatus 2 `
            -ExpectedVersion 4 `
            -Operation 'Synthetic Staff suspension'
        $suspendReplay = Read-SmokeJson `
            -Response (Invoke-SmokeStaffLifecycle `
                -Action suspend `
                -OperationId $suspendOperationId `
                -ExpectedVersion 3) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Staff suspension'
        Assert-SmokeReceiptReplay `
            -Original $suspended `
            -Replay $suspendReplay `
            -Operation 'Exact Staff suspension replay'
        $suspendedProfile = Get-SmokeStaffProfile
        $suspendedAssignments = @($suspendedProfile.assignments | Where-Object {
                [bool]$_.isCurrent
            })
        $suspendedPropertyDirectory = Get-SmokePropertyStaffDirectory -Status 2
        if ([int]$suspendedProfile.status -ne 2 -or
            [long]$suspendedProfile.version -ne 4 -or
            $suspendedAssignments.Count -ne 1 -or
            @($suspendedPropertyDirectory.items | Where-Object {
                    [Guid]$_.staffMemberId -eq $staffMemberId
                }).Count -ne 1) {
            throw 'Staff suspension did not retain the current property assignment.'
        }
        $checks.Add([ordered]@{ name = 'staff-suspension-replay-stable-and-assignment-retained'; status = 'passed' })

        $resumed = Read-SmokeJson `
            -Response (Invoke-SmokeStaffLifecycle `
                -Action resume `
                -OperationId $resumeOperationId `
                -ExpectedVersion 4) `
            -ExpectedStatus 200 `
            -Operation 'Resume synthetic Staff member'
        Assert-SmokeReceipt `
            -Receipt $resumed `
            -ExpectedStatus 1 `
            -ExpectedVersion 5 `
            -Operation 'Synthetic Staff resume'
        $resumeReplay = Read-SmokeJson `
            -Response (Invoke-SmokeStaffLifecycle `
                -Action resume `
                -OperationId $resumeOperationId `
                -ExpectedVersion 4) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Staff resume'
        Assert-SmokeReceiptReplay `
            -Original $resumed `
            -Replay $resumeReplay `
            -Operation 'Exact Staff resume replay'
        $resumedProfile = Get-SmokeStaffProfile
        if ([int]$resumedProfile.status -ne 1 -or
            [long]$resumedProfile.version -ne 5 -or
            @($resumedProfile.assignments | Where-Object {
                    [bool]$_.isCurrent
                }).Count -ne 1) {
            throw 'Staff resume did not restore active status with its assignment intact.'
        }
        $checks.Add([ordered]@{ name = 'staff-resume-replay-stable'; status = 'passed' })

        $departed = Read-SmokeJson `
            -Response (Invoke-SmokeStaffLifecycle `
                -Action depart `
                -OperationId $departOperationId `
                -ExpectedVersion 5) `
            -ExpectedStatus 200 `
            -Operation 'Depart synthetic Staff member'
        Assert-SmokeReceipt `
            -Receipt $departed `
            -ExpectedStatus 3 `
            -ExpectedVersion 6 `
            -Operation 'Synthetic Staff departure'
        $departReplay = Read-SmokeJson `
            -Response (Invoke-SmokeStaffLifecycle `
                -Action depart `
                -OperationId $departOperationId `
                -ExpectedVersion 5) `
            -ExpectedStatus 200 `
            -Operation 'Replay synthetic Staff departure'
        Assert-SmokeReceiptReplay `
            -Original $departed `
            -Replay $departReplay `
            -Operation 'Exact Staff departure replay'
        $staffDeparted = $true
        $finalVersion = [long]$departed.version
        $checks.Add([ordered]@{ name = 'staff-departure-replay-stable'; status = 'passed' })

        $departedProfile = Get-SmokeStaffProfile
        $historicalAssignments = @($departedProfile.assignments)
        $departedDirectoryMember = Get-SmokeStaffDirectoryMember
        $departedPropertyDirectory = Get-SmokePropertyStaffDirectory -Status 3
        if ([int]$departedProfile.status -ne 3 -or
            [long]$departedProfile.version -ne 6 -or
            $null -eq $departedProfile.departedAtUtc -or
            $historicalAssignments.Count -ne 1 -or
            [bool]$historicalAssignments[0].isCurrent -or
            [string]$historicalAssignments[0].effectiveTo -cne $effectiveDateText -or
            [long]$historicalAssignments[0].unassignedAtVersion -ne 6 -or
            @($departedDirectoryMember.assignments).Count -ne 0 -or
            @($departedPropertyDirectory.items | Where-Object {
                    [Guid]$_.staffMemberId -eq $staffMemberId
                }).Count -ne 0) {
            throw 'Staff departure did not close the current assignment atomically.'
        }
        $currentAssignmentsClosed = $true
        $checks.Add([ordered]@{ name = 'staff-departure-closes-current-assignment'; status = 'passed' })

        $activeAfterDeparture = Get-SmokeStaffDirectory -Status 1 -Search $updatedLabel
        $departedDirectory = Get-SmokeStaffDirectory -Status 3 -Search $updatedLabel
        $departedMatches = @($departedDirectory.items | Where-Object {
                [Guid]$_.staffMemberId -eq $staffMemberId
            })
        if (@($activeAfterDeparture.items | Where-Object {
                    [Guid]$_.staffMemberId -eq $staffMemberId
                }).Count -ne 0 -or
            $departedMatches.Count -ne 1 -or
            [int]$departedMatches[0].status -ne 3 -or
            [int]$departedMatches[0].currentPropertyCount -ne 0) {
            throw 'The active and departed Staff directory filters did not expose the terminal record correctly.'
        }
        $checks.Add([ordered]@{ name = 'staff-active-and-departed-filters-coherent'; status = 'passed' })

        $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
            -Client $client `
            -Origin $origin `
            -ExpectedReleaseId $ExpectedReleaseId `
            -TimeoutSeconds $RequestTimeoutSeconds
        if ($observedReleaseId -cne $releaseIdBefore) {
            throw 'The public API release identity changed during Staff verification.'
        }
        $checks.Add([ordered]@{ name = 'release-identity-continuous'; status = 'passed' })
    }
    catch {
        $workflowError = $_.Exception
    }
    finally {
        try {
            Complete-SmokeStaffCleanup
        }
        catch {
            $cleanupErrors.Add("staff: $($_.Exception.Message)")
        }
    }
}
finally {
    $client.Dispose()
    $operatorToken = $null
    $deniedToken = $null
    $initialLabel = $null
    $updatedLabel = $null
    $changeReason = $null
}

if ($cleanupErrors.Count -gt 0) {
    $cleanupSummary = $cleanupErrors -join '; '
    if ($null -ne $workflowError) {
        throw "Staff employment workflow failed: $($workflowError.Message) Cleanup also failed: $cleanupSummary"
    }
    throw "Staff employment workflow cleanup failed: $cleanupSummary"
}
if ($null -ne $workflowError) {
    throw $workflowError
}
if (-not $staffDeparted -or -not $currentAssignmentsClosed) {
    throw 'Staff employment verification did not reach its required terminal cleanup state.'
}
if ($checks.Count -ne 21) {
    throw "Staff employment verification recorded $($checks.Count) checks; expected 21."
}

$evidence = [ordered]@{
    schemaVersion = 1
    evidenceKind = 'bunkfy-deployed-staff-employment-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-fixture' }
    result = 'passed'
    workflow = [ordered]@{
        finalStatus = 'departed'
        authSubjectLinked = $false
        profileVersionAdvanced = $finalVersion -gt $initialVersion
        assignmentLifecycle = 'assigned-then-closed'
        currentAssignmentCount = 0
        historicalAssignmentCount = 1
        suspensionRetainedAssignment = $true
    }
    cleanup = [ordered]@{
        staffDisposition = 'synthetic-departed-retained'
        currentAssignmentsClosed = $currentAssignmentsClosed
        propertyDisposition = 'parent-rehearsal-owned'
    }
    checks = @($checks)
    limitations = @(
        'browser-staff-workflow-not-exercised',
        'account-link-membership-and-role-lifecycle-not-exercised',
        'governance-data-rights-and-retention-not-exercised',
        'synthetic-departed-staff-record-retained'
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

Write-Host "BunkFy deployed Staff employment verification passed for '$ExpectedReleaseId'."
Write-Host "Evidence: $OutputPath"
