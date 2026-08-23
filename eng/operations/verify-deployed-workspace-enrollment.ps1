[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $ExpectedReleaseId,
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

$observedAdmissionEvidenceReference = $null
$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowLoopbackHttp
if ($AllowedPropertyId -eq $DeniedPropertyId) {
    throw 'AllowedPropertyId and DeniedPropertyId must identify different properties.'
}
$profileKey = 'front-desk'

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
    $OutputPath = Join-BunkFyPath ".tmp/deployment-probes/workspace-enrollment-$stamp.json"
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
$client.DefaultRequestHeaders.UserAgent.ParseAdd('BunkFy-Deployed-Workspace-Enrollment-Probe/1')

$activeSourceIds = [Collections.Generic.HashSet[Guid]]::new()
$checks = [Collections.Generic.List[object]]::new()
$rejectedFlow = $null
$approvedFlow = $null
$approvedMembership = $null
$staff = $null

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

function Get-SmokeApplicantWorkspaces {
    $items = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $response = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/organizations?page=$page&pageSize=100" `
                -Method GET `
                -TenantId 'global' `
                -Token $applicantToken `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'List applicant workspaces'
        foreach ($item in @($response.items)) {
            $items.Add($item)
        }
        $page++
        if ($page -gt 100) {
            throw 'The applicant workspace check exceeded 100 pages.'
        }
    } while ([bool]$response.hasMore)

    return $items.ToArray()
}

function Assert-SmokeApplicantHasNoMembership {
    if (@(Get-SmokeApplicantWorkspaces | Where-Object {
                [Guid]$_.organization.organizationId -eq $WorkspaceId
            }).Count -gt 0) {
        throw 'The applicant already belongs to the target workspace.'
    }
}

function New-SmokeEnrollmentSource {
    $sourceId = [Guid]::NewGuid()
    $issuance = Invoke-BunkFyAuthenticatedJsonRequestWithConvergence `
        -Client $client `
        -Origin $origin `
        -Path '/api/workspace-staff-enrollment/sources/enrollment-links' `
        -Method POST `
        -TenantId $WorkspaceId.ToString('D') `
        -AccessToken $ownerToken `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -Body @{
            sourceId = $sourceId
            lifetimeHours = 1
            maximumClaims = 1
            approvalMode = 'requires-approval'
            profileKey = $profileKey
            propertyIds = @($AllowedPropertyId)
        } `
        -ExpectedStatus 200 `
        -Operation 'Issue approval-required enrollment link' `
        -ConvergenceTimeoutSeconds $ConvergenceTimeoutSeconds `
        -PollIntervalMilliseconds $PollIntervalMilliseconds `
        -RetryableProblemCodes @(
            'Workspaces.StaffAccessProfileUnavailable',
            'Workspaces.StaffAccessPropertyUnavailable')
    $secret = [string]$issuance.token
    if (-not [bool]$issuance.alreadyIssued -and
        [Guid]$issuance.plan.sourceId -eq $sourceId) {
        [void]$activeSourceIds.Add($sourceId)
    }
    if ([string]::IsNullOrWhiteSpace($secret) -or
        [bool]$issuance.alreadyIssued -or
        [Guid]$issuance.plan.sourceId -ne $sourceId -or
        [string]$issuance.plan.profileKey -cne $profileKey -or
        @($issuance.plan.propertyIds).Count -ne 1 -or
        [Guid]$issuance.plan.propertyIds[0] -ne $AllowedPropertyId) {
        throw 'Enrollment issuance did not preserve the requested source and access plan.'
    }

    return [pscustomobject]@{
        SourceId = $sourceId
        Token = $secret
    }
}

function Submit-SmokeEnrollmentClaim {
    param([Parameter(Mandatory = $true)][object] $Source)

    $preview = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/organization-enrollment/preview' `
            -Method POST `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body @{ token = $Source.Token }) `
        -ExpectedStatus 200 `
        -Operation 'Preview enrollment link as applicant'
    if ([Guid]$preview.organizationId -ne $WorkspaceId -or
        [Guid]$preview.enrollmentLinkId -eq [Guid]::Empty) {
        throw 'Enrollment preview resolved to an unexpected workspace or link.'
    }

    $applicationBody = @{
        sourceKind = 2
        token = $Source.Token
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
        -Operation 'Submit enrollment Staff application'
    $claim = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/organization-enrollment/claim' `
            -Method POST `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body @{ token = $Source.Token }) `
        -ExpectedStatus 200 `
        -Operation 'Submit approval-required enrollment claim'

    if ([Guid]$application.organizationId -ne $WorkspaceId -or
        [Guid]$application.sourceId -ne $Source.SourceId -or
        [Guid]$application.applicationId -eq [Guid]::Empty -or
        [Guid]$claim.claim.organizationId -ne $WorkspaceId -or
        [Guid]$claim.claim.claimId -eq [Guid]::Empty -or
        [string]$claim.claim.status -cne 'pending' -or
        $null -ne $claim.membership) {
        throw 'Enrollment submission did not produce one pending claim without membership.'
    }

    return [pscustomobject]@{
        Source = $Source
        ApplicationBody = $applicationBody
        Application = $application
        Claim = $claim.claim
    }
}

function Wait-SmokeActionableApplication {
    param([Parameter(Mandatory = $true)][object] $Flow)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    while ($true) {
        $page = 1
        do {
            $applications = Read-SmokeJson `
                -Response (Invoke-SmokeApi `
                    -Path "/api/workspace-staff-enrollment/applications?page=$page&pageSize=100" `
                    -Method GET `
                    -TenantId $WorkspaceId.ToString('D') `
                    -Token $ownerToken `
                    -Body $null) `
                -ExpectedStatus 200 `
                -Operation 'List owner-actionable Staff applications'
            $candidate = @($applications.items | Where-Object {
                    [Guid]$_.applicationId -eq [Guid]$Flow.Application.applicationId
                }) | Select-Object -First 1
            if ($null -ne $candidate -and
                $null -ne $candidate.claimId -and
                $null -ne $candidate.claimVersion) {
                return $candidate
            }
            $page++
            if ($page -gt 100) {
                throw 'The owner application check exceeded 100 pages.'
            }
        } while ([bool]$applications.hasMore)

        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw 'The enrollment claim did not appear in the owner queue before the timeout.'
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }
}

function Resolve-SmokeEnrollmentClaim {
    param(
        [Parameter(Mandatory = $true)][object] $Flow,
        [Parameter(Mandatory = $true)][ValidateSet('approve', 'reject')][string] $Decision
    )

    $actionable = Wait-SmokeActionableApplication -Flow $Flow
    $outcome = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path "/api/organizations/$($WorkspaceId.ToString('D'))/join-requests/$([Guid]$actionable.claimId)/$Decision" `
            -Method POST `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $ownerToken `
            -Body @{ expectedVersion = [long]$actionable.claimVersion }) `
        -ExpectedStatus 200 `
        -Operation "$Decision enrollment claim"
    return $outcome
}

function Wait-SmokeApplicationStatus {
    param(
        [Parameter(Mandatory = $true)][object] $Flow,
        [Parameter(Mandatory = $true)][int] $ExpectedStatus
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    while ($true) {
        $current = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/workspace-staff-enrollment/$($WorkspaceId.ToString('D'))/applications/current?sourceKind=2&sourceId=$($Flow.Source.SourceId.ToString('D'))" `
                -Method GET `
                -TenantId 'global' `
                -Token $applicantToken `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation 'Read current enrollment Staff application'
        if ([int]$current.status -eq $ExpectedStatus) {
            return $current
        }
        if ([int]$current.status -in @(6, 7, 8, 9) -and
            [int]$current.status -ne $ExpectedStatus) {
            throw "Enrollment Staff application reached terminal status $([int]$current.status)."
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw "Enrollment Staff application did not reach status $ExpectedStatus before the timeout."
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }
}

function Get-SmokeEnrollmentSource {
    param([Parameter(Mandatory = $true)][Guid] $SourceId)

    $sources = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/workspace-staff-enrollment/sources?sourceKind=2&page=1&pageSize=100' `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $ownerToken `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'List enrollment sources'
    return @($sources.items | Where-Object { [Guid]$_.sourceId -eq $SourceId }) |
        Select-Object -First 1
}

function Disable-SmokeEnrollmentSource {
    param([Parameter(Mandatory = $true)][Guid] $SourceId)

    $source = Get-SmokeEnrollmentSource -SourceId $SourceId
    if ($null -eq $source) {
        throw "Enrollment source '$SourceId' is not visible to its owner."
    }
    if ([int]$source.status -eq 1) {
        $disabled = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/workspace-staff-enrollment/sources/enrollment-links/$($SourceId.ToString('D'))/disable" `
                -Method POST `
                -TenantId $WorkspaceId.ToString('D') `
                -Token $ownerToken `
                -Body @{ expectedVersion = [long]$source.version }) `
            -ExpectedStatus 200 `
            -Operation 'Disable enrollment source'
        if ([int]$disabled.status -ne 6) {
            throw 'Enrollment source disablement did not become terminal.'
        }
    }
    [void]$activeSourceIds.Remove($SourceId)
}

function Disable-SmokeEnrollmentSourcesBestEffort {
    foreach ($sourceId in @($activeSourceIds)) {
        try {
            Disable-SmokeEnrollmentSource -SourceId $sourceId
        }
        catch {
            Write-Warning "The incomplete smoke enrollment source '$sourceId' could not be disabled automatically."
        }
    }
}

function Assert-SmokePendingAccessDenied {
    Assert-SmokeApplicantHasNoMembership
    $response = Invoke-SmokeApi `
        -Path "/api/properties/$($AllowedPropertyId.ToString('D'))" `
        -Method GET `
        -TenantId $WorkspaceId.ToString('D') `
        -Token $applicantToken `
        -Body $null
    Assert-BunkFyAuthenticatedStatus `
        -Response $response `
        -ExpectedStatus 403 `
        -Operation 'Reject property read before owner approval'
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

try {
    $releaseIdBefore = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -ObservedAdmissionEvidenceReference ([ref]$observedAdmissionEvidenceReference)
    $methods = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/auth/methods' `
            -Method GET `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read applicant authentication methods'
    if (@($methods.emails | Where-Object {
                $_.email -ieq $normalizedApplicantEmail -and
                [bool]$_.isActive -and
                [bool]$_.isVerified
            }).Count -ne 1) {
        throw 'The applicant token does not expose the requested active, verified email address.'
    }
    Assert-SmokeApplicantHasNoMembership

    foreach ($propertyId in @($AllowedPropertyId, $DeniedPropertyId)) {
        $property = Read-SmokeJson `
            -Response (Invoke-SmokeApi `
                -Path "/api/properties/$($propertyId.ToString('D'))" `
                -Method GET `
                -TenantId $WorkspaceId.ToString('D') `
                -Token $ownerToken `
                -Body $null) `
            -ExpectedStatus 200 `
            -Operation "Owner property preflight '$propertyId'"
        if ([Guid]$property.propertyId -ne $propertyId) {
            throw "Owner property preflight '$propertyId' returned a different property."
        }
    }

    if (-not $PSCmdlet.ShouldProcess(
            "workspace '$WorkspaceId'",
            "exercise rejected and approved QR enrollment for '$normalizedApplicantEmail'")) {
        return
    }

    $rejectedFlow = Submit-SmokeEnrollmentClaim -Source (New-SmokeEnrollmentSource)
    $checks.Add([ordered]@{ name = 'approval-required-source-issued'; status = 'passed' })
    Assert-SmokePendingAccessDenied
    $checks.Add([ordered]@{ name = 'pending-claim-has-no-access'; status = 'passed' })

    $rejection = Resolve-SmokeEnrollmentClaim -Flow $rejectedFlow -Decision reject
    if ([string]$rejection.claim.status -cne 'rejected' -or
        $null -ne $rejection.membership -or
        [Guid]$rejection.claim.claimId -ne [Guid]$rejectedFlow.Claim.claimId) {
        throw 'Owner rejection did not return the expected terminal claim without membership.'
    }
    $rejectedFlow.Application = Wait-SmokeApplicationStatus `
        -Flow $rejectedFlow `
        -ExpectedStatus 7
    Assert-SmokePendingAccessDenied
    $replayedRejection = Invoke-SmokeApi `
        -Path '/api/organization-enrollment/claim' `
        -Method POST `
        -TenantId 'global' `
        -Token $applicantToken `
        -Body @{ token = $rejectedFlow.Source.Token }
    $replayedRejectionCode = Get-BunkFyAuthenticatedProblemCode `
        -Response $replayedRejection
    if ($replayedRejection.StatusCode -ne 409 -or
        $replayedRejectionCode -cne 'Organizations.EnrollmentClaimUnavailable') {
        throw "Rejected enrollment replay returned HTTP $($replayedRejection.StatusCode) with problem '$replayedRejectionCode'; expected the terminal claim denial."
    }
    Assert-SmokePendingAccessDenied
    $checks.Add([ordered]@{ name = 'owner-rejection-terminal'; status = 'passed' })
    Disable-SmokeEnrollmentSource -SourceId $rejectedFlow.Source.SourceId
    $checks.Add([ordered]@{ name = 'rejected-source-disabled'; status = 'passed' })

    $approvedFlow = Submit-SmokeEnrollmentClaim -Source (New-SmokeEnrollmentSource)
    Assert-SmokePendingAccessDenied
    $approval = Resolve-SmokeEnrollmentClaim -Flow $approvedFlow -Decision approve
    if ([string]$approval.claim.status -cne 'accepted' -or
        $null -eq $approval.membership -or
        [Guid]$approval.membership.organization.organizationId -ne $WorkspaceId -or
        [Guid]$approval.membership.membership.membershipId -eq [Guid]::Empty) {
        throw 'Owner approval did not create the expected membership.'
    }
    $approvedMembership = $approval.membership.membership
    $approvedFlow.Application = Wait-SmokeApplicationStatus `
        -Flow $approvedFlow `
        -ExpectedStatus 5
    $checks.Add([ordered]@{ name = 'second-claim-owner-approved'; status = 'passed' })

    $convergenceDeadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    while ($true) {
        $staffResponse = Invoke-SmokeApi `
            -Path '/api/staff/me' `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $applicantToken `
            -Body $null
        if ($staffResponse.StatusCode -eq 200) {
            $staff = Read-SmokeJson $staffResponse 200 'Read approved applicant Staff profile'
            if ([string]$staff.authSubjectId -cne
                    [string]$approval.membership.membership.subjectId -or
                [Guid]$staff.staffMemberId -ne
                    [Guid]$approvedFlow.Application.staffMemberId) {
                throw 'The approved Staff profile does not match the membership and application.'
            }
            break
        }
        if ($staffResponse.StatusCode -ne 404) {
            Assert-BunkFyAuthenticatedStatus $staffResponse 200 'Read approved applicant Staff profile'
        }
        if ([DateTimeOffset]::UtcNow -ge $convergenceDeadline) {
            throw 'The approved applicant Staff profile did not converge before the timeout.'
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
            -Operation 'Evaluate approved applicant access'
        if ((Test-SmokePermission $evaluation 'properties.read' $allowedScope $true) -and
            (Test-SmokePermission $evaluation 'reservations.create' $allowedScope $true) -and
            (Test-SmokePermission $evaluation 'properties.read' $deniedScope $false) -and
            (Test-SmokePermission $evaluation 'staff.manage' $tenantScope $false)) {
            break
        }
        if ([DateTimeOffset]::UtcNow -ge $convergenceDeadline) {
            throw 'The approved applicant access profile did not converge before the timeout.'
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }
    Assert-BunkFyAuthenticatedStatus `
        -Response (Invoke-SmokeApi `
            -Path "/api/properties/$($AllowedPropertyId.ToString('D'))" `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $applicantToken `
            -Body $null) `
        -ExpectedStatus 200 `
        -Operation 'Read approved property as applicant'
    Assert-BunkFyAuthenticatedStatus `
        -Response (Invoke-SmokeApi `
            -Path "/api/properties/$($DeniedPropertyId.ToString('D'))" `
            -Method GET `
            -TenantId $WorkspaceId.ToString('D') `
            -Token $applicantToken `
            -Body $null) `
        -ExpectedStatus 403 `
        -Operation 'Reject approved applicant out-of-scope property read'

    $subjectPath = [Uri]::EscapeDataString([string]$approvedMembership.subjectId)
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
                -Operation 'Read approved member access'
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
                -Operation 'Read approved member access'
        }
        if ([DateTimeOffset]::UtcNow -ge $convergenceDeadline) {
            throw 'Owner-visible approved member access did not converge to the QR plan.'
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }
    $checks.Add([ordered]@{ name = 'least-privilege-route-enforcement'; status = 'passed' })

    $replayedApplication = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/workspace-staff-enrollment/applications' `
            -Method POST `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body $approvedFlow.ApplicationBody) `
        -ExpectedStatus 200 `
        -Operation 'Replay approved enrollment Staff application'
    $replayedApproval = Read-SmokeJson `
        -Response (Invoke-SmokeApi `
            -Path '/api/organization-enrollment/claim' `
            -Method POST `
            -TenantId 'global' `
            -Token $applicantToken `
            -Body @{ token = $approvedFlow.Source.Token }) `
        -ExpectedStatus 200 `
        -Operation 'Replay approved enrollment claim'
    if ([Guid]$replayedApplication.applicationId -ne
            [Guid]$approvedFlow.Application.applicationId -or
        [string]$replayedApproval.claim.status -cne 'accepted' -or
        [Guid]$replayedApproval.membership.membership.membershipId -ne
            [Guid]$approvedMembership.membershipId) {
        throw 'Approved enrollment replay produced a different application, claim outcome, or membership.'
    }
    $targetMemberships = @(Get-SmokeApplicantWorkspaces | Where-Object {
            [Guid]$_.organization.organizationId -eq $WorkspaceId
        })
    if ($targetMemberships.Count -ne 1 -or
        [Guid]$targetMemberships[0].membership.membershipId -ne
            [Guid]$approvedMembership.membershipId) {
        throw 'Approved enrollment did not converge to exactly one target membership.'
    }

    while ($true) {
        $approvedSource = Get-SmokeEnrollmentSource -SourceId $approvedFlow.Source.SourceId
        if ($null -ne $approvedSource -and [int]$approvedSource.status -eq 7) {
            break
        }
        if ([DateTimeOffset]::UtcNow -ge $convergenceDeadline) {
            throw 'The one-use approved enrollment source did not reach capacity.'
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }
    $checks.Add([ordered]@{ name = 'same-subject-claim-replay-stable'; status = 'passed' })

    [void]$activeSourceIds.Remove($approvedFlow.Source.SourceId)
    $observedReleaseId = Assert-BunkFyPublicApiReleaseIdentity `
        -Client $client `
        -Origin $origin `
        -ExpectedReleaseId $ExpectedReleaseId `
        -TimeoutSeconds $RequestTimeoutSeconds `
        -ObservedAdmissionEvidenceReference ([ref]$observedAdmissionEvidenceReference)
    if ($observedReleaseId -cne $releaseIdBefore) {
        throw 'The public API release identity changed during enrollment verification.'
    }
    $checks.Add([ordered]@{ name = 'release-identity-continuous'; status = 'passed' })
}
catch {
    Disable-SmokeEnrollmentSourcesBestEffort
    throw
}
finally {
    $client.Dispose()
    if ($null -ne $rejectedFlow) {
        $rejectedFlow.Source.Token = $null
    }
    if ($null -ne $approvedFlow) {
        $approvedFlow.Source.Token = $null
    }
    $ownerToken = $null
    $applicantToken = $null
}

$evidence = [ordered]@{
    schemaVersion = 2
    evidenceKind = 'bunkfy-deployed-workspace-enrollment-probe'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    origin = $origin.GetLeftPart([UriPartial]::Authority)
    releaseId = $observedReleaseId
    admissionEvidenceReference = $observedAdmissionEvidenceReference
    transport = if ($origin.Scheme -eq 'https') { 'trusted-https' } else { 'loopback-http-fixture' }
    result = 'passed'
    workspaceId = $WorkspaceId.ToString('D')
    allowedPropertyId = $AllowedPropertyId.ToString('D')
    deniedPropertyId = $DeniedPropertyId.ToString('D')
    rejected = [ordered]@{
        sourceId = $rejectedFlow.Source.SourceId.ToString('D')
        applicationId = ([Guid]$rejectedFlow.Application.applicationId).ToString('D')
        claimId = ([Guid]$rejectedFlow.Claim.claimId).ToString('D')
    }
    approved = [ordered]@{
        sourceId = $approvedFlow.Source.SourceId.ToString('D')
        applicationId = ([Guid]$approvedFlow.Application.applicationId).ToString('D')
        claimId = ([Guid]$approvedFlow.Claim.claimId).ToString('D')
        membershipId = ([Guid]$approvedMembership.membershipId).ToString('D')
        staffMemberId = ([Guid]$staff.staffMemberId).ToString('D')
    }
    checks = @($checks)
    limitations = @(
        'browser-ui-and-qr-rendering-not-exercised',
        'registration-and-email-delivery-not-exercised',
        'joined-member-not-automatically-offboarded'
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

Write-Host "BunkFy deployed workspace enrollment passed $($checks.Count) checks."
Write-Host "Evidence: $OutputPath"
