[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $BaseUri = $(if ($env:BUNKFY_ADMIN_API_BASE_URL) { $env:BUNKFY_ADMIN_API_BASE_URL } else { 'http://127.0.0.1:5195' }),
    [Parameter(Mandatory = $true)][string] $TenantId,
    [Parameter(Mandatory = $true)][string] $Username,
    [ValidateSet('email', 'phone')][string] $UsernameType = 'email',
    [Security.SecureString] $Password,
    [switch] $GeneratePassword,
    [Parameter(Mandatory = $true)][string] $DisplayName,
    [string] $LegalName,
    [string] $WorkEmail,
    [string] $WorkPhone,
    [string] $EmployeeNumber,
    [string] $JobTitle,
    [string] $Department,
    [Guid[]] $PropertyId = @(),
    [Guid] $PrimaryPropertyId,
    [string[]] $RoleName = @(),
    [string] $AccessScope,
    [DateTime] $EffectiveFrom = $(Get-Date),
    [string] $StatePath,
    [Security.SecureString] $AccessToken
)

. (Join-Path $PSScriptRoot 'admin-api.common.ps1')

if ($GeneratePassword -and $null -ne $Password) {
    throw 'Use -Password or -GeneratePassword, not both.'
}

if ($PSBoundParameters.ContainsKey('PrimaryPropertyId') -and $PropertyId -notcontains $PrimaryPropertyId) {
    throw '-PrimaryPropertyId must also be present in -PropertyId.'
}

$normalizedTenant = $TenantId.Trim()
$normalizedUsername = $Username.Trim()
if ([string]::IsNullOrWhiteSpace($normalizedTenant) -or [string]::IsNullOrWhiteSpace($normalizedUsername)) {
    throw 'TenantId and Username are required.'
}

if ([string]::IsNullOrWhiteSpace($AccessScope)) {
    $AccessScope = "tenant:$normalizedTenant"
}

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $safeUsername = $normalizedUsername -replace '[^a-zA-Z0-9._-]', '_'
    $StatePath = Join-Path $PSScriptRoot "..\..\.tmp\operations\provision-$safeUsername.json"
}
$StatePath = [IO.Path]::GetFullPath($StatePath)

$state = Read-BunkFyOperationState -Path $StatePath
if ($null -eq $state) {
    $state = [pscustomobject]@{
        schemaVersion = 1
        workflow = 'provision-staff-access'
        tenantId = $normalizedTenant
        username = $normalizedUsername
        authMemberId = $null
        staffMemberId = $null
        propertyAssignments = @()
        roleAssignments = @()
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        completedAtUtc = $null
    }
}
elseif ($state.workflow -ne 'provision-staff-access' -or
        $state.tenantId -ne $normalizedTenant -or
        $state.username -ne $normalizedUsername) {
    throw "State file '$StatePath' belongs to a different provisioning request."
}

if ($null -ne $state.PSObject.Properties['offboarding']) {
    throw "State file '$StatePath' has entered offboarding and cannot be used to provision access again."
}

if ($WhatIfPreference) {
    Write-Host "Would provision '$normalizedUsername' in tenant '$normalizedTenant'."
    Write-Host "Would journal progress to '$StatePath'."
    return
}

$token = Resolve-BunkFyAdminAccessToken -AccessToken $AccessToken

if ([string]::IsNullOrWhiteSpace([string]$state.authMemberId)) {
    $plainPassword = $null
    if (-not $GeneratePassword) {
        if ($null -eq $Password) {
            $Password = Read-Host 'Initial member password' -AsSecureString
        }
        $plainPassword = ConvertFrom-BunkFySecureString -Value $Password
    }

    if ($PSCmdlet.ShouldProcess($normalizedUsername, 'Create Auth member')) {
        try {
            $createdMember = Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $normalizedTenant `
                -AccessToken $token -Method POST -Path '/api/admin/auth/members' -Body @{
                    username = $normalizedUsername
                    usernameType = $UsernameType
                    password = $plainPassword
                    generatePassword = [bool]$GeneratePassword
                }
        }
        finally {
            $plainPassword = $null
        }

        $state.authMemberId = [string]$createdMember.memberId
        Write-BunkFyOperationState -Path $StatePath -State $state
        Write-Host "Created Auth member $($state.authMemberId)."
        if (-not [string]::IsNullOrWhiteSpace([string]$createdMember.generatedPassword)) {
            Write-Host "Generated password (shown once): $($createdMember.generatedPassword)"
        }
    }
}
else {
    Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $normalizedTenant -AccessToken $token `
        -Method GET -Path "/api/admin/auth/members/$($state.authMemberId)" | Out-Null
    Write-Host "Auth member $($state.authMemberId) already exists."
}

if ([string]::IsNullOrWhiteSpace([string]$state.staffMemberId)) {
    if ($PSCmdlet.ShouldProcess($DisplayName, 'Create Staff profile')) {
        $createdStaff = Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $normalizedTenant `
            -AccessToken $token -Method POST -Path '/api/admin/staff/members' -Body @{
                displayName = $DisplayName
                legalName = $LegalName
                workEmail = $WorkEmail
                workPhone = $WorkPhone
                employeeNumber = $EmployeeNumber
                jobTitle = $JobTitle
                department = $Department
                authSubjectId = [string]$state.authMemberId
            }
        $state.staffMemberId = [string]$createdStaff.staffMemberId
        Write-BunkFyOperationState -Path $StatePath -State $state
        Write-Host "Created Staff profile $($state.staffMemberId)."
    }
}

$staff = Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $normalizedTenant -AccessToken $token `
    -Method GET -Path "/api/admin/staff/members/$($state.staffMemberId)"
if ([string]$staff.authSubjectId -ne [string]$state.authMemberId) {
    throw 'The Staff profile is not linked to the journaled Auth member.'
}

foreach ($property in $PropertyId) {
    $existing = @($staff.assignments) | Where-Object { $_.propertyId -eq $property -and $_.isCurrent }
    if ($existing.Count -eq 0 -and $PSCmdlet.ShouldProcess([string]$property, 'Assign Staff property')) {
        $staff = Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $normalizedTenant `
            -AccessToken $token -Method PUT `
            -Path "/api/admin/staff/members/$($state.staffMemberId)/properties/$property" -Body @{
                propertyJobTitle = $JobTitle
                isPrimary = ($PSBoundParameters.ContainsKey('PrimaryPropertyId') -and $property -eq $PrimaryPropertyId)
                effectiveFrom = $EffectiveFrom.ToString('yyyy-MM-dd')
                expectedVersion = [long]$staff.version
            }
    }

    if (@($state.propertyAssignments | Where-Object { $_.propertyId -eq [string]$property }).Count -eq 0) {
        $state.propertyAssignments = @($state.propertyAssignments) + [pscustomobject]@{
            propertyId = [string]$property
            isPrimary = ($PSBoundParameters.ContainsKey('PrimaryPropertyId') -and $property -eq $PrimaryPropertyId)
        }
        Write-BunkFyOperationState -Path $StatePath -State $state
    }
}

foreach ($role in ($RoleName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
    $encodedRole = ConvertTo-BunkFyUrlValue -Value $role
    $assignments = @(Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $normalizedTenant `
        -AccessToken $token -Method GET -Path "/api/admin/roles/$encodedRole/assignments")
    $exists = $assignments | Where-Object {
        $_.subjectKind -eq 'user' -and
        $_.subjectId -eq [string]$state.authMemberId -and
        [string]$_.scope -eq $AccessScope
    }
    if ($null -eq $exists -and $PSCmdlet.ShouldProcess($role, 'Assign access role')) {
        Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $normalizedTenant -AccessToken $token `
            -Method POST -Path "/api/admin/roles/$encodedRole/assignments" -Body @{
                subjectKind = 'user'
                subjectId = [string]$state.authMemberId
                scope = $AccessScope
            } | Out-Null

        $assignments = @(Invoke-BunkFyAdminApi -BaseUri $BaseUri -TenantId $normalizedTenant `
            -AccessToken $token -Method GET -Path "/api/admin/roles/$encodedRole/assignments")
        $exists = $assignments | Where-Object {
            $_.subjectKind -eq 'user' -and
            $_.subjectId -eq [string]$state.authMemberId -and
            [string]$_.scope -eq $AccessScope
        }
        if ($null -eq $exists) {
            throw "Role '$role' was not persisted for Auth member $($state.authMemberId)."
        }
    }

    if (@($state.roleAssignments | Where-Object { $_.roleName -eq $role -and $_.scope -eq $AccessScope }).Count -eq 0) {
        $state.roleAssignments = @($state.roleAssignments) + [pscustomobject]@{
            roleName = $role
            scope = $AccessScope
        }
        Write-BunkFyOperationState -Path $StatePath -State $state
    }
}

$state.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
Write-BunkFyOperationState -Path $StatePath -State $state
Write-Host "Provisioning complete. State: $StatePath"
