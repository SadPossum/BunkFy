[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)][Guid] $WorkspaceId,
    [Parameter(Mandatory = $true)][Guid] $AllowedPropertyId,
    [Parameter(Mandatory = $true)][Guid] $DeniedPropertyId,
    [Parameter(Mandatory = $true)][ValidateLength(3, 320)][string] $ApplicantEmail,
    [ValidateLength(1, 160)][string] $ApplicantDisplayName = 'BunkFy deployment smoke',
    [Security.SecureString] $OwnerAccessToken,
    [Security.SecureString] $ApplicantAccessToken,
    [ValidateRange(1, 60)][int] $RequestTimeoutSeconds = 15,
    [ValidateRange(10, 300)][int] $ConvergenceTimeoutSeconds = 90,
    [ValidateRange(500, 5000)][int] $PollIntervalMilliseconds = 1000,
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
if ($AllowedPropertyId -eq $DeniedPropertyId) {
    throw 'AllowedPropertyId and DeniedPropertyId must identify different properties.'
}
$profileKey = 'front-desk'

$mailAddress = $null
try {
    $mailAddress = [Net.Mail.MailAddress]::new($ApplicantEmail.Trim())
}
catch {
    throw 'ApplicantEmail must be one plain email address.'
}
if (-not $mailAddress.Address.Equals(
        $ApplicantEmail.Trim(),
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ApplicantEmail must be one plain email address.'
}
$normalizedApplicantEmail = $mailAddress.Address.ToLowerInvariant()

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture)
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/workspace-invitation-$stamp.json"
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

$ownerToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $OwnerAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_OWNER_TOKEN' `
    -Prompt 'Workspace owner access token'
$applicantToken = Resolve-BunkFySmokeAccessToken `
    -AccessToken $ApplicantAccessToken `
    -EnvironmentVariable 'BUNKFY_SMOKE_APPLICANT_TOKEN' `
    -Prompt 'Applicant access token'
if ([string]::IsNullOrWhiteSpace($ownerToken) -or
    [string]::IsNullOrWhiteSpace($applicantToken)) {
    throw 'Both smoke access tokens are required.'
}
if ($ownerToken.Equals($applicantToken, [StringComparison]::Ordinal)) {
    throw 'Owner and applicant access tokens must represent distinct accounts.'
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
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Deployed-Workspace-Invitation-Probe/1')

$sourceId = [Guid]::NewGuid()
$invitationToken = $null
$sourceIssued = $false
$accepted = $false
$application = $null
$membership = $null
$staff = $null
$checks = [Collections.Generic.List[object]]::new()

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

function Test-SmokePermission {
    param(
        [Parameter(Mandatory = $true)][object] $Evaluation,
        [Parameter(Mandatory = $true)][string] $Permission,
        [Parameter(Mandatory = $true)][string] $Scope,
        [Parameter(Mandatory = $true)][bool] $Allowed
    )

    $matches = @($Evaluation.permissions | Where-Object {
            $_.permission -ceq $Permission -and $_.scope -ceq $Scope
        })
    return $matches.Count -eq 1 -and [bool]$matches[0].allowed -eq $Allowed
}

function Revoke-SmokeInvitationBestEffort {
    if ($accepted -or -not $sourceIssued) {
        return
    }

    try {
        $list = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path '/api/workspace-staff-enrollment/sources?sourceKind=1&page=1&pageSize=100' `
                -Method GET `
                -TenantId $WorkspaceId.ToString('D') `
                -Token $ownerToken `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List invitation sources for cleanup'
        $source = @($list.items | Where-Object { [Guid]$_.sourceId -eq $sourceId }) | Select-Object -First 1
        if ($null -ne $source -and [int]$source.status -eq 1) {
            $response = Invoke-SmokeApi `
                -Path "/api/workspace-staff-enrollment/sources/invitations/$($sourceId.ToString('D'))/revoke" `
                -Method POST `
                -TenantId $WorkspaceId.ToString('D') `
                -Token $ownerToken `
                -Body @{ expectedVersion = [long]$source.version }
            Assert-BunkFyAuthenticatedStatus `
                -Response $response `
                -ExpectedStatus 200 `
                -Operation 'Revoke incomplete smoke invitation'
        }
    }
    catch {
        Write-Warning "The incomplete smoke invitation '$sourceId' could not be revoked automatically."
    }
}

try {
    $methods = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/auth/methods' `
            -Method GET `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read applicant authentication methods'
    $verifiedAddress = @($methods.emails | Where-Object {
            $_.email -ieq $normalizedApplicantEmail -and
            [bool]$_.isActive -and
            [bool]$_.isVerified
        })
    if ($verifiedAddress.Count -ne 1) {
        throw 'The applicant token does not expose the requested active, verified email address.'
    }

    $page = 1
    do {
        $organizations = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/organizations?page=$page&pageSize=100" `
                -Method GET `
                -TenantId 'global' `
                -Token $applicantToken `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List applicant workspaces'
        if (@($organizations.items | Where-Object {
                    [Guid]$_.organization.organizationId -eq $WorkspaceId
                }).Count -gt 0) {
            throw 'The applicant already belongs to the target workspace; use a clean smoke identity.'
        }
        $page++
        if ($page -gt 100) {
            throw 'The applicant workspace preflight exceeded 100 pages.'
        }
    } while ([bool]$organizations.hasMore)

    foreach ($propertyId in @($AllowedPropertyId, $DeniedPropertyId)) {
        $propertyResponse = Invoke-SmokeApi `
            -Path "/api/properties/$($propertyId.ToString('D'))" `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $ownerToken `
            -Body $null
        $property = Read-SmokeJson `
            -Response $propertyResponse `
            -ExpectedStatus 200 `
            -Operation "Owner property preflight '$propertyId'"
        if ([Guid]$property.propertyId -ne $propertyId) {
            throw "Owner property preflight '$propertyId' returned a different property."
        }
    }

    if (-not $PSCmdlet.ShouldProcess(
            "workspace '$WorkspaceId'",
            "invite '$normalizedApplicantEmail' and create its Staff/access records")) {
        return
    }

    $issuance = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/workspace-staff-enrollment/sources/invitations' `
            -Method POST `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $ownerToken `
            -Body @{
                sourceId = $sourceId
                recipientEmail = $normalizedApplicantEmail
                lifetimeHours = 1
                profileKey = $profileKey
                propertyIds = @($AllowedPropertyId)
            }) `
        -ExpectedStatus 200 `
        -Operation 'Issue recipient-bound invitation'
    $invitationToken = [string]$issuance.token
    $sourceIssued =
        -not [bool]$issuance.alreadyIssued -and
        [Guid]$issuance.plan.sourceId -eq $sourceId
    if ([string]::IsNullOrWhiteSpace($invitationToken) -or
        [bool]$issuance.alreadyIssued -or
        [Guid]$issuance.plan.sourceId -ne $sourceId -or
        [string]$issuance.plan.profileKey -cne $profileKey -or
        @($issuance.plan.propertyIds).Count -ne 1 -or
        [Guid]$issuance.plan.propertyIds[0] -ne $AllowedPropertyId) {
        throw 'Invitation issuance did not preserve the requested source and access plan.'
    }
    $checks.Add([ordered]@{ name = 'recipient-bound-source-issued'; status = 'passed' })

    $preview = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/organization-invitations/preview' `
            -Method POST `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body @{ token = $invitationToken }) `
        -ExpectedStatus 200 `
        -Operation 'Preview invitation as applicant'
    if ([Guid]$preview.organizationId -ne $WorkspaceId -or
        [Guid]$preview.invitationId -eq [Guid]::Empty) {
        throw 'Invitation preview resolved to an unexpected workspace or invitation.'
    }
    $checks.Add([ordered]@{ name = 'recipient-preview-authorized'; status = 'passed' })

    $applicationBody = @{
        sourceKind = 1
        token = $invitationToken
        displayName = $ApplicantDisplayName.Trim()
        legalName = $null
        workEmail = $normalizedApplicantEmail
        workPhone = $null
        employeeNumber = $null
        jobTitle = 'Deployment smoke'
        department = 'Operations verification'
    }
    $application = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/workspace-staff-enrollment/applications' `
            -Method POST `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body $applicationBody) `
        -ExpectedStatus 200 `
        -Operation 'Submit Staff onboarding application'
    if ([Guid]$application.organizationId -ne $WorkspaceId -or
        [Guid]$application.sourceId -ne $sourceId -or
        [Guid]$application.applicationId -eq [Guid]::Empty) {
        throw 'The Staff onboarding application did not preserve the invitation correlation.'
    }

    $acceptance = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/organization-invitations/accept' `
            -Method POST `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body @{ token = $invitationToken }) `
        -ExpectedStatus 200 `
        -Operation 'Accept invitation as applicant'
    $membership = $acceptance.membership.membership
    if ([Guid]$acceptance.membership.organization.organizationId -ne $WorkspaceId -or
        [Guid]$membership.membershipId -eq [Guid]::Empty -or
        [string]::IsNullOrWhiteSpace([string]$membership.subjectId)) {
        throw 'Invitation acceptance did not return the expected membership.'
    }
    $accepted = $true
    $checks.Add([ordered]@{ name = 'separate-account-membership-created'; status = 'passed' })

    $convergenceDeadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    while ($true) {
        $currentResponse = Invoke-SmokeApi `
            -Path "/api/workspace-staff-enrollment/$($WorkspaceId.ToString('D'))/applications/current?sourceKind=1&sourceId=$($sourceId.ToString('D'))" `
            -Method GET `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body $null
        $current = Read-SmokeJson `
            -Response $currentResponse `
            -ExpectedStatus 200 `
            -Operation 'Read current Staff onboarding application'
        if ([int]$current.status -eq 5) {
            $application = $current
            break
        }
        if ([int]$current.status -in @(6, 7, 8, 9)) {
            throw "Staff onboarding reached terminal status $([int]$current.status)."
        }
        if ([DateTimeOffset]::UtcNow -ge $convergenceDeadline) {
            throw 'Staff onboarding did not converge before the timeout.'
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }

    while ($true) {
        $staffResponse = Invoke-SmokeApi `
            -Path '/api/staff/me' `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $applicantToken `
            -Body $null
        if ($staffResponse.StatusCode -eq 200) {
            $staff = Read-SmokeJson $staffResponse 200 'Read applicant Staff profile'
            if ([string]$staff.authSubjectId -cne [string]$membership.subjectId -or
                [Guid]$staff.staffMemberId -ne [Guid]$application.staffMemberId) {
                throw 'The converged Staff profile does not match the accepted identity and application.'
            }
            break
        }
        if ($staffResponse.StatusCode -ne 404) {
            Assert-BunkFyAuthenticatedStatus $staffResponse 200 'Read applicant Staff profile'
        }
        if ([DateTimeOffset]::UtcNow -ge $convergenceDeadline) {
            throw 'The applicant Staff profile did not become visible before the timeout.'
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }
    $checks.Add([ordered]@{ name = 'staff-profile-converged'; status = 'passed' })

    $tenantScope = "tenant:$($WorkspaceId.ToString('D'))"
    $allowedScope = "$tenantScope/property:$($AllowedPropertyId.ToString('D'))"
    $deniedScope = "$tenantScope/property:$($DeniedPropertyId.ToString('D'))"
    $permissionBody = @{
        checks = @(
            @{ permission = 'properties.read'; scope = $allowedScope },
            @{ permission = 'reservations.create'; scope = $allowedScope },
            @{ permission = 'properties.read'; scope = $deniedScope },
            @{ permission = 'staff.manage'; scope = $tenantScope }
        )
    }
    while ($true) {
        $evaluation = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path '/api/access/permissions/evaluate' `
                -Method POST `
                -TenantId $WorkspaceId.ToString('D') `
                -Token $applicantToken `
                -Body $permissionBody) `
            -ExpectedStatus 200 `
            -Operation 'Evaluate applicant access'
        $accessReady =
            (Test-SmokePermission $evaluation 'properties.read' $allowedScope $true) -and
            (Test-SmokePermission $evaluation 'reservations.create' $allowedScope $true) -and
            (Test-SmokePermission $evaluation 'properties.read' $deniedScope $false) -and
            (Test-SmokePermission $evaluation 'staff.manage' $tenantScope $false)
        if ($accessReady) {
            break
        }
        if ([DateTimeOffset]::UtcNow -ge $convergenceDeadline) {
            throw 'The applicant access profile did not converge before the timeout.'
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }
    $checks.Add([ordered]@{ name = 'least-privilege-policy-evaluation'; status = 'passed' })

    Assert-BunkFyAuthenticatedStatus `
        -Response (Invoke-SmokeApi `
            -Path "/api/properties/$($AllowedPropertyId.ToString('D'))" `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $applicantToken `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read allowed property as applicant'
    Assert-BunkFyAuthenticatedStatus `
        -Response (Invoke-SmokeApi `
            -Path "/api/properties/$($DeniedPropertyId.ToString('D'))" `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $applicantToken `
            -Body $null) `
        -ExpectedStatus 403 `
        -Operation 'Reject out-of-scope property read'
    $checks.Add([ordered]@{ name = 'property-route-enforcement'; status = 'passed' })

    $subjectPath = [Uri]::EscapeDataString([string]$membership.subjectId)
    while ($true) {
        $memberAccessResponse = Invoke-SmokeApi `
            -Path "/api/workspace-access/members/$subjectPath/access" `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $ownerToken `
            -Body $null
        if ($memberAccessResponse.StatusCode -eq 200) {
            $memberAccess = Read-SmokeJson `
                -Response $memberAccessResponse `
                -ExpectedStatus 200 `
                -Operation 'Read owner-visible member access'
            $assignments = @($memberAccess.assignments)
            if ($assignments.Count -eq 1 -and
                [string]$assignments[0].profileKey -ceq $profileKey -and
                [Guid]$assignments[0].propertyId -eq $AllowedPropertyId) {
                break
            }
        }
        elseif ($memberAccessResponse.StatusCode -ne 404) {
            Assert-BunkFyAuthenticatedStatus `
                -Response $memberAccessResponse `
                -ExpectedStatus 200 `
                -Operation 'Read owner-visible member access'
        }
        if ([DateTimeOffset]::UtcNow -ge $convergenceDeadline) {
            throw 'Owner-visible member access did not converge to the invitation plan.'
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }

    $replayedApplication = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/workspace-staff-enrollment/applications' `
            -Method POST `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body $applicationBody) `
        -ExpectedStatus 200 `
        -Operation 'Replay Staff onboarding application'
    $replayedAcceptance = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/organization-invitations/accept' `
            -Method POST `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body @{ token = $invitationToken }) `
        -ExpectedStatus 200 `
        -Operation 'Replay invitation acceptance'
    if ([Guid]$replayedApplication.applicationId -ne [Guid]$application.applicationId -or
        [Guid]$replayedAcceptance.membership.membership.membershipId -ne
            [Guid]$membership.membershipId) {
        throw 'Same-subject replay produced a different application or membership.'
    }
    $replayedStaff = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/staff/me' `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $applicantToken `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read Staff profile after replay'
    if ([Guid]$replayedStaff.staffMemberId -ne [Guid]$staff.staffMemberId) {
        throw 'Same-subject replay produced a different Staff profile.'
    }
    $checks.Add([ordered]@{ name = 'same-subject-replay-stable'; status = 'passed' })
}
catch {
    Revoke-SmokeInvitationBestEffort
    throw
}
finally {
    $client.Dispose()
    $invitationToken = $null
    $ownerToken = $null
    $applicantToken = $null
}

$evidence = [ordered]@{
    schemaVersion = 1
    evidenceKind = 'bunkfy-deployed-workspace-invitation-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-fixture' }
    result = 'passed'
    workspaceId = $WorkspaceId.ToString('D')
    allowedPropertyId = $AllowedPropertyId.ToString('D')
    deniedPropertyId = $DeniedPropertyId.ToString('D')
    sourceId = $sourceId.ToString('D')
    applicationId = ([Guid]$application.applicationId).ToString('D')
    membershipId = ([Guid]$membership.membershipId).ToString('D')
    staffMemberId = ([Guid]$staff.staffMemberId).ToString('D')
    checks = @($checks)
    limitations = @(
        'browser-ui-not-exercised',
        'registration-and-email-delivery-not-exercised',
        'joined-member-not-automatically-offboarded'
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

Write-Host "BunkFy deployed workspace invitation passed $($checks.Count) checks."
Write-Host "Evidence: $OutputPath"
