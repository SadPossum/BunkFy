Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-BunkFyPreviewPropertyProcessingEnumValue {
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][int] $NumericValue,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $text = [string]$Value
    return $text -ceq [string]$NumericValue -or
        $text.Equals($Name, [StringComparison]::OrdinalIgnoreCase)
}

function Get-BunkFyPreviewEngineeringCountryPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock] $InvokeApi,
        [Parameter(Mandatory = $true)][Guid] $PropertyId
    )

    if ($PropertyId -eq [Guid]::Empty) {
        throw 'A non-empty property id is required for Preview property processing.'
    }

    $response = & $InvokeApi `
        -Path "/api/properties/$($PropertyId.ToString('D'))/country-policies" `
        -Method 'GET' `
        -Body $null `
        -Operation 'List Preview engineering country policies'
    $nowUtc = [DateTimeOffset]::UtcNow
    $eligible = @($response.items | Where-Object {
            $effectiveAtUtc = [DateTimeOffset]$_.effectiveAtUtc
            $expiresAtUtc = [DateTimeOffset]$_.expiresAtUtc
            [string]$_.launchStatus -ceq 'engineering' -and
            [string]$_.approvalState -ceq 'example' -and
            $effectiveAtUtc -le $nowUtc -and
            $nowUtc -lt $expiresAtUtc -and
            [bool]$_.supportsRightsResponseDeadlines -and
            @($_.accommodationTypes) -ccontains 'hostel' -and
            @($_.permittedDataRegions).Count -gt 0 -and
            @($_.permittedTransferProfiles).Count -gt 0 -and
            @($_.retentionPolicies).Count -gt 0 -and
            @($_.requiredAcknowledgements).Count -gt 0 -and
            [string]$_.contentSha256 -cmatch '^[a-f0-9]{64}$'
        })
    if ($eligible.Count -ne 1) {
        throw "Preview must expose exactly one current engineering/example hostel policy with rights deadlines; found $($eligible.Count)."
    }

    return $eligible[0]
}

function Enable-BunkFyPreviewEngineeringPropertyProcessing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock] $InvokeApi,
        [Parameter(Mandatory = $true)][Guid] $PropertyId,
        [ValidateRange(1, 600)][int] $ConvergenceTimeoutSeconds = 180,
        [ValidateRange(1, 5000)][int] $PollIntervalMilliseconds = 1000
    )

    $property = & $InvokeApi `
        -Path "/api/properties/$($PropertyId.ToString('D'))" `
        -Method 'GET' `
        -Body $null `
        -Operation 'Read Preview property before processing activation'
    if ([Guid]$property.propertyId -ne $PropertyId -or
        -not (Test-BunkFyPreviewPropertyProcessingEnumValue `
            -Value $property.status `
            -NumericValue 1 `
            -Name 'active') -or
        -not (Test-BunkFyPreviewPropertyProcessingEnumValue `
            -Value $property.processingStatus `
            -NumericValue 1 `
            -Name 'unconfigured') -or
        $null -ne $property.governancePolicy -or
        [long]$property.version -lt 1) {
        throw 'The Preview property is not a fresh active property with unconfigured processing.'
    }

    $policy = Get-BunkFyPreviewEngineeringCountryPolicy `
        -InvokeApi $InvokeApi `
        -PropertyId $PropertyId
    $dataRegionId = @($policy.permittedDataRegions | Sort-Object)[0]
    $transferProfileId = @($policy.permittedTransferProfiles | Sort-Object)[0]
    $retentionPolicy = @($policy.retentionPolicies | Sort-Object `
            -Property retentionPolicyId, retentionPolicyVersion)[0]
    $acknowledgements = @($policy.requiredAcknowledgements | Sort-Object `
            -Property acknowledgementId, acknowledgementVersion | ForEach-Object {
                [ordered]@{
                    acknowledgementId = [string]$_.acknowledgementId
                    acknowledgementVersion = [int]$_.acknowledgementVersion
                }
            })

    $receipt = & $InvokeApi `
        -Path "/api/properties/$($PropertyId.ToString('D'))/processing/activate" `
        -Method 'POST' `
        -Body ([ordered]@{
            operationId = [Guid]::NewGuid()
            operatingCountryCode = [string]$policy.operatingCountryCode
            policyId = [string]$policy.policyId
            policyVersion = [int]$policy.policyVersion
            dataRegionId = [string]$dataRegionId
            transferProfileId = [string]$transferProfileId
            retentionPolicyId = [string]$retentionPolicy.retentionPolicyId
            retentionPolicyVersion = [int]$retentionPolicy.retentionPolicyVersion
            acceptedAcknowledgements = $acknowledgements
            confirmed = $true
            expectedVersion = [long]$property.version
        }) `
        -Operation 'Activate Preview engineering property processing'
    if ([Guid]$receipt.propertyId -ne $PropertyId -or
        -not (Test-BunkFyPreviewPropertyProcessingEnumValue `
            -Value $receipt.status `
            -NumericValue 1 `
            -Name 'active') -or
        -not (Test-BunkFyPreviewPropertyProcessingEnumValue `
            -Value $receipt.processingStatus `
            -NumericValue 2 `
            -Name 'enabled') -or
        [long]$receipt.version -le [long]$property.version) {
        throw 'Preview property-processing activation returned an invalid receipt.'
    }

    $expectedAcknowledgements = @($acknowledgements | ForEach-Object {
            "$($_.acknowledgementId):$($_.acknowledgementVersion)"
        })
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ConvergenceTimeoutSeconds)
    do {
        $state = & $InvokeApi `
            -Path "/api/properties/$($PropertyId.ToString('D'))/processing" `
            -Method 'GET' `
            -Body $null `
            -Operation 'Read Preview property-processing state'
        $binding = $state.governancePolicy
        $actualAcknowledgements = @()
        if ($null -ne $binding) {
            $actualAcknowledgements = @($binding.acknowledgements | Sort-Object `
                    -Property acknowledgementId, acknowledgementVersion | ForEach-Object {
                        "$($_.acknowledgementId):$($_.acknowledgementVersion)"
                    })
        }
        $acknowledgementsMatch = $expectedAcknowledgements.Count -eq $actualAcknowledgements.Count -and
            -not (Compare-Object $expectedAcknowledgements $actualAcknowledgements -CaseSensitive)
        if ([Guid]$state.propertyId -eq $PropertyId -and
            (Test-BunkFyPreviewPropertyProcessingEnumValue `
                -Value $state.configuredStatus `
                -NumericValue 2 `
                -Name 'enabled') -and
            (Test-BunkFyPreviewPropertyProcessingEnumValue `
                -Value $state.effectiveStatus `
                -NumericValue 2 `
                -Name 'enabled') -and
            [string]$state.reasonCode -ceq 'Properties.CountryPolicy.Allowed' -and
            $null -ne $binding -and
            [string]$binding.operatingCountryCode -ceq [string]$policy.operatingCountryCode -and
            [string]$binding.policyId -ceq [string]$policy.policyId -and
            [int]$binding.policyVersion -eq [int]$policy.policyVersion -and
            [string]$binding.dataRegionId -ceq [string]$dataRegionId -and
            [string]$binding.transferProfileId -ceq [string]$transferProfileId -and
            [string]$binding.retentionPolicyId -ceq [string]$retentionPolicy.retentionPolicyId -and
            [int]$binding.retentionPolicyVersion -eq [int]$retentionPolicy.retentionPolicyVersion -and
            [string]$binding.contentSha256 -ceq [string]$policy.contentSha256 -and
            $acknowledgementsMatch -and
            [long]$state.propertyVersion -ge [long]$receipt.version) {
            return [pscustomobject]@{
                PropertyId = $PropertyId
                PropertyVersion = [long]$state.propertyVersion
                PolicyVersion = [int]$policy.policyVersion
                Status = 'enabled-engineering-policy'
            }
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw 'Preview property processing did not converge to the exact engineering policy binding before the timeout.'
}
