[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $BaseUri = $(if ($env:BUNKFY_ADMIN_API_BASE_URL) { $env:BUNKFY_ADMIN_API_BASE_URL } else { 'http://127.0.0.1:5195' }),
    [Parameter(Mandatory = $true)][string] $StatePath,
    [Parameter(Mandatory = $true)][string] $Reason,
    [DateTime] $EffectiveOn = $(Get-Date),
    [Security.SecureString] $AccessToken
)

. (Join-Path $PSScriptRoot 'admin-api.common.ps1')

function Test-BunkFyStaffDepartedStatus {
    param([object] $Status)

    if ([string]$Status -ieq 'departed') {
        return $true
    }

    $numericStatus = 0
    return [int]::TryParse([string]$Status, [ref]$numericStatus) -and $numericStatus -eq 3
}

$StatePath = [IO.Path]::GetFullPath($StatePath)
$state = Read-BunkFyOperationState -Path $StatePath
if ($null -eq $state -or $state.workflow -ne 'provision-staff-access') {
    throw "A provisioning state file is required: '$StatePath'."
}
if ([string]::IsNullOrWhiteSpace([string]$state.authMemberId) -or
    [string]::IsNullOrWhiteSpace([string]$state.staffMemberId)) {
    throw 'The provisioning state does not contain both Auth and Staff identifiers.'
}

Add-BunkFyStateProperty -State $state -Name offboarding -Value ([pscustomobject]@{
    startedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    rolesRevokedAtUtc = $null
    authDisabledAtUtc = $null
    staffDepartedAtUtc = $null
    completedAtUtc = $null
})

if (-not [string]::IsNullOrWhiteSpace([string]$state.offboarding.completedAtUtc)) {
    Write-Host "Offboarding already complete. State: $StatePath"
    return
}

if ($WhatIfPreference) {
    Write-Host "Would offboard Staff member $($state.staffMemberId) and Auth member $($state.authMemberId)."
    Write-Host "Would resume from '$StatePath' after any partial failure."
    return
}

$token = Resolve-BunkFyAdminAccessToken -AccessToken $AccessToken
$tenantId = [string]$state.tenantId

# Preflight every owned role before changing Auth or Staff. AccessControl protects the last owner.
foreach ($assignment in @($state.roleAssignments)) {
    $encodedRole = ConvertTo-BunkFyUrlValue -Value ([string]$assignment.roleName)
    Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $tenantId -AccessToken $token `
        -Method GET -Path "/api/admin/roles/$encodedRole/assignments" | Out-Null
}

foreach ($assignment in @($state.roleAssignments)) {
    $role = [string]$assignment.roleName
    $scope = [string]$assignment.scope
    $encodedRole = ConvertTo-BunkFyUrlValue -Value $role
    $assignments = @(Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $tenantId -AccessToken $token `
        -Method GET -Path "/api/admin/roles/$encodedRole/assignments")
    $exists = $assignments | Where-Object {
        $_.subjectKind -eq 'user' -and
        $_.subjectId -eq [string]$state.authMemberId -and
        [string]$_.scope -eq $scope
    }
    if ($null -ne $exists -and $PSCmdlet.ShouldProcess($role, 'Unassign access role')) {
        $query = 'subjectKind=user&subjectId={0}&scope={1}' -f `
            (ConvertTo-BunkFyUrlValue -Value ([string]$state.authMemberId)), `
            (ConvertTo-BunkFyUrlValue -Value $scope)
        Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $tenantId -AccessToken $token `
            -Method DELETE -Path "/api/admin/roles/$encodedRole/assignments?$query" | Out-Null
    }

    $remainingAssignments = @(
        @(Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $tenantId `
            -AccessToken $token -Method GET -Path "/api/admin/roles/$encodedRole/assignments") |
        Where-Object {
            $_.subjectKind -eq 'user' -and
            $_.subjectId -eq [string]$state.authMemberId -and
            [string]$_.scope -eq $scope
        }
    )
    if ($remainingAssignments.Count -gt 0) {
        throw "Role '$role' is still assigned to Auth member $($state.authMemberId)."
    }
}
$state.offboarding.rolesRevokedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
Write-BunkFyOperationState -Path $StatePath -State $state

$member = Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $tenantId -AccessToken $token `
    -Method GET -Path "/api/admin/auth/members/$($state.authMemberId)"
if ($PSCmdlet.ShouldProcess([string]$state.authMemberId, 'Revoke Auth sessions')) {
    Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $tenantId -AccessToken $token `
        -Method POST -Path "/api/admin/auth/members/$($state.authMemberId)/revoke-sessions" `
        -Body @{ confirmed = $true } | Out-Null
}
if ([string]$member.status -ine 'disabled' -and
    $PSCmdlet.ShouldProcess([string]$state.authMemberId, 'Disable Auth member')) {
    Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $tenantId -AccessToken $token `
        -Method POST -Path "/api/admin/auth/members/$($state.authMemberId)/disable" `
        -Body @{ reason = $Reason; confirmed = $true } | Out-Null
}
$member = Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $tenantId -AccessToken $token `
    -Method GET -Path "/api/admin/auth/members/$($state.authMemberId)"
if ([string]$member.status -ine 'disabled') {
    throw "Auth member $($state.authMemberId) was not disabled."
}
$state.offboarding.authDisabledAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
Write-BunkFyOperationState -Path $StatePath -State $state

$staff = Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $tenantId -AccessToken $token `
    -Method GET -Path "/api/admin/staff/members/$($state.staffMemberId)"
foreach ($propertyAssignment in @($staff.assignments | Where-Object { $_.isCurrent })) {
    $effectiveTo = $EffectiveOn.Date
    $assignmentStart = [DateTime]::Parse([string]$propertyAssignment.effectiveFrom)
    if ($assignmentStart.Date -gt $effectiveTo) {
        $effectiveTo = $assignmentStart.Date
    }

    if ($PSCmdlet.ShouldProcess([string]$propertyAssignment.propertyId, 'End Staff property assignment')) {
        $staff = Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $tenantId -AccessToken $token `
            -Method POST `
            -Path "/api/admin/staff/members/$($state.staffMemberId)/properties/$($propertyAssignment.propertyId)/unassign" `
            -Body @{
                effectiveTo = $effectiveTo.ToString('yyyy-MM-dd')
                reason = $Reason
                expectedVersion = [long]$staff.version
            }
    }
}

if (-not (Test-BunkFyStaffDepartedStatus -Status $staff.status) -and
    $PSCmdlet.ShouldProcess([string]$state.staffMemberId, 'Mark Staff member departed')) {
    $staff = Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $tenantId -AccessToken $token `
        -Method POST -Path "/api/admin/staff/members/$($state.staffMemberId)/depart" -Body @{
            effectiveOn = $EffectiveOn.ToString('yyyy-MM-dd')
            reason = $Reason
            expectedVersion = [long]$staff.version
            confirmed = $true
        }
}

if (-not (Test-BunkFyStaffDepartedStatus -Status $staff.status)) {
    throw "Staff member $($state.staffMemberId) was not marked departed."
}

$state.offboarding.staffDepartedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
$state.offboarding.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
Write-BunkFyOperationState -Path $StatePath -State $state
Write-Host "Offboarding complete. State: $StatePath"
