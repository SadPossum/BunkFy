Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'operations\preview-property-processing-fixture.common.ps1')

$propertyId = [Guid]'11111111-1111-4111-8111-111111111111'
$digest = '82661c0757dc035b20a63a8d6d3c55b8ef3987de40d8962b37f6565e10e4ba4d'
$script:processingReads = 0
$calls = [Collections.Generic.List[string]]::new()

function New-TestCountryPolicy {
    param([string] $LaunchStatus = 'engineering')

    return [pscustomobject]@{
        policyId = 'development-hostel-example'
        policyVersion = 2
        operatingCountryCode = 'GB'
        launchStatus = $LaunchStatus
        approvalState = 'example'
        effectiveAtUtc = '2020-01-01T00:00:00Z'
        expiresAtUtc = '2099-01-01T00:00:00Z'
        contentSha256 = $digest
        accommodationTypes = @('hostel')
        permittedDataRegions = @('development-local')
        permittedTransferProfiles = @('development-no-transfer')
        supportsRightsResponseDeadlines = $true
        retentionPolicies = @(
            [pscustomobject]@{
                retentionPolicyId = 'development-staff-employment'
                retentionPolicyVersion = 1
            },
            [pscustomobject]@{
                retentionPolicyId = 'development-guest-operational'
                retentionPolicyVersion = 1
            })
        requiredAcknowledgements = @([pscustomobject]@{
                acknowledgementId = 'development-example-notice'
                acknowledgementVersion = 1
            })
    }
}

$invokeApi = {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Method,
        [AllowNull()][object] $Body,
        [Parameter(Mandatory = $true)][string] $Operation
    )

    $calls.Add("$Method $Path")
    if ($Method -ceq 'GET' -and $Path -ceq "/api/properties/$($propertyId.ToString('D'))") {
        return [pscustomobject]@{
            propertyId = $propertyId
            status = 'active'
            processingStatus = 'unconfigured'
            governancePolicy = $null
            version = 1
        }
    }
    if ($Method -ceq 'GET' -and $Path.EndsWith('/country-policies', [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ items = @((New-TestCountryPolicy)) }
    }
    if ($Method -ceq 'POST' -and $Path.EndsWith('/processing/activate', [StringComparison]::Ordinal)) {
        if ([Guid]$Body.operationId -eq [Guid]::Empty -or
            [string]$Body.operatingCountryCode -cne 'GB' -or
            [string]$Body.policyId -cne 'development-hostel-example' -or
            [int]$Body.policyVersion -ne 2 -or
            [string]$Body.dataRegionId -cne 'development-local' -or
            [string]$Body.transferProfileId -cne 'development-no-transfer' -or
            [string]$Body.retentionPolicyId -cne 'development-guest-operational' -or
            [int]$Body.retentionPolicyVersion -ne 1 -or
            @($Body.acceptedAcknowledgements).Count -ne 1 -or
            [string]$Body.acceptedAcknowledgements[0].acknowledgementId -cne 'development-example-notice' -or
            [int]$Body.acceptedAcknowledgements[0].acknowledgementVersion -ne 1 -or
            -not [bool]$Body.confirmed -or
            [long]$Body.expectedVersion -ne 1) {
            throw 'Preview property-processing fixture used an invalid activation request.'
        }
        return [pscustomobject]@{
            propertyId = $propertyId
            status = 1
            processingStatus = 2
            version = 2
        }
    }
    if ($Method -ceq 'GET' -and $Path.EndsWith('/processing', [StringComparison]::Ordinal)) {
        $script:processingReads++
        if ($script:processingReads -eq 1) {
            return [pscustomobject]@{
                propertyId = $propertyId
                configuredStatus = 'enabled'
                effectiveStatus = 'unconfigured'
                reasonCode = 'Properties.PropertyProcessing.Unconfigured'
                governancePolicy = $null
                propertyVersion = 2
            }
        }
        return [pscustomobject]@{
            propertyId = $propertyId
            configuredStatus = 'enabled'
            effectiveStatus = 'enabled'
            reasonCode = 'Properties.CountryPolicy.Allowed'
            governancePolicy = [pscustomobject]@{
                operatingCountryCode = 'GB'
                policyId = 'development-hostel-example'
                policyVersion = 2
                dataRegionId = 'development-local'
                transferProfileId = 'development-no-transfer'
                retentionPolicyId = 'development-guest-operational'
                retentionPolicyVersion = 1
                contentSha256 = $digest
                acknowledgements = @([pscustomobject]@{
                        acknowledgementId = 'development-example-notice'
                        acknowledgementVersion = 1
                    })
            }
            propertyVersion = 2
        }
    }

    throw "Unexpected Preview property-processing call '$Method $Path' ($Operation)."
}

$fixture = Enable-BunkFyPreviewEngineeringPropertyProcessing `
    -InvokeApi $invokeApi `
    -PropertyId $propertyId `
    -ConvergenceTimeoutSeconds 2 `
    -PollIntervalMilliseconds 1
if ([Guid]$fixture.PropertyId -ne $propertyId -or
    [long]$fixture.PropertyVersion -ne 2 -or
    [int]$fixture.PolicyVersion -ne 2 -or
    [string]$fixture.Status -cne 'enabled-engineering-policy' -or
    $script:processingReads -ne 2) {
    throw 'Preview property-processing fixture did not converge to the exact policy binding.'
}

foreach ($requiredCall in @(
        "GET /api/properties/$($propertyId.ToString('D'))/country-policies",
        "POST /api/properties/$($propertyId.ToString('D'))/processing/activate",
        "GET /api/properties/$($propertyId.ToString('D'))/processing")) {
    if (-not $calls.Contains($requiredCall)) {
        throw "Preview property-processing fixture did not issue '$requiredCall'."
    }
}

$ambiguousApi = {
    param($Path, $Method, $Body, $Operation)
    return [pscustomobject]@{
        items = @((New-TestCountryPolicy), (New-TestCountryPolicy))
    }
}
$ambiguousRejected = $false
try {
    [void](Get-BunkFyPreviewEngineeringCountryPolicy `
            -InvokeApi $ambiguousApi `
            -PropertyId $propertyId)
}
catch {
    $ambiguousRejected = $_.Exception.Message.Contains(
        'exactly one',
        [StringComparison]::OrdinalIgnoreCase)
}
if (-not $ambiguousRejected) {
    throw 'Preview property-processing fixture accepted ambiguous engineering policies.'
}

$approvedApi = {
    param($Path, $Method, $Body, $Operation)
    return [pscustomobject]@{ items = @((New-TestCountryPolicy -LaunchStatus 'approved')) }
}
$approvedRejected = $false
try {
    [void](Get-BunkFyPreviewEngineeringCountryPolicy `
            -InvokeApi $approvedApi `
            -PropertyId $propertyId)
}
catch {
    $approvedRejected = $_.Exception.Message.Contains(
        'found 0',
        [StringComparison]::OrdinalIgnoreCase)
}
if (-not $approvedRejected) {
    throw 'Preview property-processing fixture treated an approved policy as engineering evidence.'
}

Write-Host 'BunkFy Preview property-processing fixture passed.'
