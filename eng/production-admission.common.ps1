. (Join-Path $PSScriptRoot 'image-promotion.common.ps1')
. (Join-Path $PSScriptRoot 'operations/deployed-public-edge.common.ps1')

$script:BunkFyProductionAdmissionLimitations = @(
    'private-evidence-content-and-authenticity-not-verified',
    'registry-immutability-after-promotion-not-observed',
    'production-traffic-and-data-not-exercised',
    'bundle-checksum-is-not-a-signature')
$script:BunkFyProductionAdmissionPrivateControls = @(
    'browser-workspace-onboarding',
    'deployment-approval-alerting-and-rollback',
    'hosted-backup-and-recovery',
    'runtime-topology-restart-and-credential-rotation')
$script:BunkFyProductionAdmissionChecks = @(
    'candidate-and-rollback-promotions-verified',
    'deployed-rollback-rehearsal-verified',
    'production-migration-rehearsal-verified',
    'deployed-release-and-admin-boundary-verified',
    'deployed-domain-workflows-verified',
    'private-control-references-declared',
    'source-evidence-hashes-bound')

function Assert-BunkFyProductionAdmissionReference {
    param(
        [Parameter(Mandatory = $true)][string] $Value,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($Value.Length -gt 224 -or
        $Value -cnotmatch '^[a-z][a-z0-9-]{1,31}:[A-Za-z0-9][A-Za-z0-9._/-]{2,190}$') {
        throw "$Name must be a bounded non-secret evidence reference such as 'record:OPS-123'."
    }
    return $Value
}

function Assert-BunkFyProductionAdmissionSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -cnotmatch '^[a-f0-9]{64}$' -or $Value -ceq ('0' * 64)) {
        throw "$Context must be a nonzero lowercase SHA-256 value."
    }
    return $Value
}

function ConvertTo-BunkFyProductionAdmissionTimestamp {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $parsed = [DateTimeOffset]::MinValue
    if ($Value -is [DateTimeOffset]) {
        $parsed = [DateTimeOffset]$Value
    }
    elseif ($Value -is [DateTime]) {
        $dateTime = [DateTime]$Value
        if ($dateTime.Kind -ne [DateTimeKind]::Utc) {
            throw "$Context must be a valid non-future UTC round-trip timestamp."
        }
        $parsed = [DateTimeOffset]::new($dateTime)
    }
    elseif (-not [DateTimeOffset]::TryParseExact(
            [string]$Value,
            'O',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        throw "$Context must be a valid non-future UTC round-trip timestamp."
    }
    if (
        $parsed.Offset -ne [TimeSpan]::Zero -or
        $parsed -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        throw "$Context must be a valid non-future UTC round-trip timestamp."
    }
    return $parsed.ToUniversalTime()
}

function Assert-BunkFyProductionAdmissionStringSequence {
    param(
        [Parameter(Mandatory = $true)][object[]] $Actual,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context,
        [switch] $OrderIndependent
    )

    $actualStrings = @($Actual | ForEach-Object { [string]$_ })
    $expectedStrings = @($Expected)
    if ($OrderIndependent) {
        $actualStrings = @($actualStrings | Sort-Object)
        $expectedStrings = @($expectedStrings | Sort-Object)
    }
    if (($actualStrings -join "`n") -cne ($expectedStrings -join "`n")) {
        throw "$Context does not match the required values."
    }
}

function Get-BunkFyProductionAdmissionEvidenceFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context,
        [long] $MaximumBytes = 1MB
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($resolvedPath)) {
        throw "Missing $Context '$resolvedPath'."
    }
    $file = [IO.FileInfo]::new($resolvedPath)
    Assert-BunkFyCandidateRegularFile -File $file -Context $Context
    if ($file.Length -le 0 -or $file.Length -gt $MaximumBytes) {
        throw "$Context '$resolvedPath' has an invalid size."
    }
    try {
        $record = [IO.File]::ReadAllText($resolvedPath) |
            ConvertFrom-Json -DateKind String
    }
    catch {
        throw "$Context '$resolvedPath' is not valid JSON."
    }
    if ($null -eq $record -or
        $record -is [string] -or
        $record -is [Array]) {
        throw "$Context '$resolvedPath' must contain an object."
    }
    return [pscustomobject]@{
        Path = $resolvedPath
        Record = $record
        Sha256 = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-BunkFyProductionAdmissionProbeSpecification {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'public-edge',
            'admin-allowed',
            'admin-denied',
            'workspace-invitation',
            'workspace-enrollment',
            'operations-notifications',
            'adapter-host',
            'retention')]
        [string] $Name
    )

    switch ($Name) {
        'public-edge' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-public-edge-probe'
                SchemaVersion = 3
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'transport', 'result', 'checks', 'limitations')
                Checks = @('web-root-and-browser-policy', 'web-release-identity', 'edge-health', 'public-api-smoke', 'admin-api-absent', 'untrusted-host-rejected')
                Limitations = @('registry-and-image-provenance-require-promotion-record', 'private-infrastructure-not-observed', 'authenticated-workflows-not-executed')
                GuidProperties = @()
            }
        }
        { $_ -in @('admin-allowed', 'admin-denied') } {
            $checks = if ($Name -ceq 'admin-allowed') {
                @('public-edge-healthy', 'admin-api-absent-from-public-edge', 'admin-api-reachable-from-approved-network', 'admin-api-anonymous-access-denied', 'release-identity-continuous')
            }
            else {
                @('public-edge-healthy', 'admin-api-absent-from-public-edge', 'admin-api-denied-outside-approved-network', 'release-identity-continuous')
            }
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-admin-boundary-probe'
                SchemaVersion = 1
                OriginProperty = 'publicOrigin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'evidenceSetId', 'releaseId', 'expectedAdminReachability', 'publicOrigin', 'adminOrigin', 'transport', 'result', 'adminObservation', 'checks', 'limitations')
                Checks = $checks
                Limitations = @('single-vantage-point-observation', 'deployment-configuration-not-inspected', 'authenticated-admin-operations-not-executed')
                GuidProperties = @('evidenceSetId')
            }
        }
        'workspace-invitation' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-workspace-invitation-probe'
                SchemaVersion = 1
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'transport', 'result', 'workspaceId', 'allowedPropertyId', 'deniedPropertyId', 'sourceId', 'applicationId', 'membershipId', 'staffMemberId', 'checks', 'limitations')
                Checks = @('recipient-bound-source-issued', 'recipient-preview-authorized', 'separate-account-membership-created', 'staff-profile-converged', 'least-privilege-policy-evaluation', 'property-route-enforcement', 'same-subject-replay-stable', 'release-identity-continuous')
                Limitations = @('browser-ui-not-exercised', 'registration-and-email-delivery-not-exercised', 'joined-member-not-automatically-offboarded')
                GuidProperties = @('workspaceId', 'allowedPropertyId', 'deniedPropertyId', 'sourceId', 'applicationId', 'membershipId', 'staffMemberId')
            }
        }
        'workspace-enrollment' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-workspace-enrollment-probe'
                SchemaVersion = 1
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'transport', 'result', 'workspaceId', 'allowedPropertyId', 'deniedPropertyId', 'rejected', 'approved', 'checks', 'limitations')
                Checks = @('approval-required-source-issued', 'pending-claim-has-no-access', 'owner-rejection-terminal', 'rejected-source-disabled', 'second-claim-owner-approved', 'staff-profile-converged', 'least-privilege-route-enforcement', 'same-subject-claim-replay-stable', 'release-identity-continuous')
                Limitations = @('browser-ui-and-qr-rendering-not-exercised', 'registration-and-email-delivery-not-exercised', 'joined-member-not-automatically-offboarded')
                GuidProperties = @('workspaceId', 'allowedPropertyId', 'deniedPropertyId')
            }
        }
        'operations-notifications' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-operations-notifications-probe'
                SchemaVersion = 1
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'transport', 'result', 'workspaceId', 'propertyId', 'inventoryUnitId', 'arrival', 'departure', 'blockGroupId', 'createdNotification', 'releasedNotification', 'checks', 'limitations')
                Checks = @('distinct-scoped-identities-preflight', 'cross-workspace-history-denied', 'created-notification-live-streamed', 'created-notification-detail-and-read-state', 'released-notification-live-streamed', 'released-notification-detail-and-read-state', 'initiating-actor-excluded', 'observer-history-exactly-once', 'inventory-block-cleanup-confirmed', 'release-identity-continuous')
                Limitations = @('browser-attention-rendering-not-exercised', 'external-delivery-adapters-not-exercised', 'released-block-and-notification-history-retained')
                GuidProperties = @('workspaceId', 'propertyId', 'inventoryUnitId', 'blockGroupId')
            }
        }
        'adapter-host' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-adapter-host-probe'
                SchemaVersion = 1
                OriginProperty = 'publicOrigin'
                TransportProperty = 'publicTransport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'publicOrigin', 'releaseId', 'adapterHostOrigin', 'publicTransport', 'adapterHostTransport', 'result', 'workspaceId', 'propertyId', 'connectionId', 'adapterType', 'workerId', 'statusEndpointExposure', 'run', 'receipt', 'checks', 'limitations')
                Checks = @('adapter-host-ready-and-exposure-correct', 'remote-polling-connection-preflight', 'remote-lease-run-proof-complete', 'durable-receipt-provenance-correlated', 'server-checkpoint-advanced', 'connection-health-converged', 'adapter-host-post-cycle-healthy', 'release-identity-continuous')
                Limitations = @('synthetic-provider-record-injection-not-performed-by-probe', 'credential-rotation-and-process-restart-not-exercised', 'production-admission-log-and-orchestrator-topology-not-observed', 'raw-payload-content-not-read')
                GuidProperties = @('workspaceId', 'propertyId', 'connectionId', 'workerId')
            }
        }
        'retention' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-retention-probe'
                SchemaVersion = 1
                OriginProperty = 'publicOrigin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'publicOrigin', 'releaseId', 'transport', 'result', 'workspaceId', 'observedDataClassKey', 'catalogueCount', 'schedules', 'checks', 'limitations')
                Checks = @('retention-catalogue-present', 'cross-workspace-retention-denied', 'automatic-retention-occurrence-observed', 'retention-schedules-terminal-and-current', 'retention-summary-consistent', 'retention-outcomes-pii-minimized', 'release-identity-continuous')
                Limitations = @('owner-data-not-seeded-or-read', 'generic-task-lease-and-restart-not-observed', 'legal-hold-and-admin-retry-not-exercised', 'private-maintenance-owner-topology-and-alerting-not-observed')
                GuidProperties = @('workspaceId')
            }
        }
    }
}

function Get-BunkFyVerifiedProductionAdmissionProbe {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $SpecificationName,
        [Parameter(Mandatory = $true)][Uri] $ExpectedOrigin,
        [Parameter(Mandatory = $true)][string] $ExpectedReleaseId,
        [switch] $AllowFixtureEvidence
    )

    $spec = Get-BunkFyProductionAdmissionProbeSpecification -Name $SpecificationName
    $source = Get-BunkFyProductionAdmissionEvidenceFile `
        -Path $Path `
        -Context "$SpecificationName deployment evidence"
    $record = $source.Record
    Assert-BunkFyCandidateProperties `
        -Value $record `
        -ExpectedProperties $spec.Properties `
        -Context "$SpecificationName deployment evidence"
    if ($record.schemaVersion -ne $spec.SchemaVersion -or
        $record.evidenceKind -cne $spec.EvidenceKind -or
        $record.result -cne 'passed' -or
        $record.releaseId -cne $ExpectedReleaseId -or
        [string]$record.($spec.OriginProperty) -cne
            $ExpectedOrigin.GetLeftPart([UriPartial]::Authority)) {
        throw "$SpecificationName deployment evidence does not match the candidate release."
    }
    $expectedTransport = if ($AllowFixtureEvidence) {
        'loopback-http-fixture'
    }
    else {
        'trusted-https'
    }
    if ([string]$record.($spec.TransportProperty) -cne $expectedTransport) {
        throw "$SpecificationName deployment evidence has the wrong transport profile."
    }
    $generatedAt = ConvertTo-BunkFyProductionAdmissionTimestamp `
        -Value $record.generatedAtUtc `
        -Context "$SpecificationName generation time"
    foreach ($propertyName in $spec.GuidProperties) {
        $parsed = [Guid]::Empty
        if (-not [Guid]::TryParseExact(
                [string]$record.$propertyName,
                'D',
                [ref]$parsed) -or
            $parsed -eq [Guid]::Empty) {
            throw "$SpecificationName deployment evidence has invalid '$propertyName'."
        }
    }
    $checks = @($record.checks)
    $checkNames = @($checks | ForEach-Object { [string]$_.name })
    if ($checks.Count -ne $spec.Checks.Count -or
        @($checkNames | Sort-Object -Unique).Count -ne $checks.Count) {
        throw "$SpecificationName deployment evidence has invalid checks."
    }
    Assert-BunkFyProductionAdmissionStringSequence `
        -Actual $checkNames `
        -Expected $spec.Checks `
        -Context "$SpecificationName checks" `
        -OrderIndependent
    foreach ($check in $checks) {
        if ($check.PSObject.Properties.Name -contains 'status' -and
            $check.status -is [string] -and
            [string]$check.status -cne 'passed') {
            throw "$SpecificationName deployment evidence contains a failing check."
        }
    }
    Assert-BunkFyProductionAdmissionStringSequence `
        -Actual @($record.limitations) `
        -Expected $spec.Limitations `
        -Context "$SpecificationName limitations"

    if ($SpecificationName.StartsWith('admin-', [StringComparison]::Ordinal)) {
        $expectedReachability = $SpecificationName.Substring(6)
        if ([string]$record.expectedAdminReachability -cne $expectedReachability) {
            throw "$SpecificationName evidence has the wrong vantage point."
        }
        $adminOrigin = [Uri]::new([string]$record.adminOrigin)
        if (-not $adminOrigin.IsAbsoluteUri -or
            $adminOrigin.GetLeftPart([UriPartial]::Authority) -cne [string]$record.adminOrigin -or
            $adminOrigin.Authority -ceq $ExpectedOrigin.Authority -or
            (-not $AllowFixtureEvidence -and $adminOrigin.Scheme -cne 'https')) {
            throw "$SpecificationName evidence has an invalid Admin origin."
        }
    }

    return [pscustomobject]@{
        Name = $spec.Name
        EvidenceKind = $spec.EvidenceKind
        SourceSha256 = $source.Sha256
        GeneratedAtUtc = $generatedAt
        CheckCount = $checks.Count
        Record = $record
        Path = $source.Path
    }
}

function Assert-BunkFyProductionAdmissionPromotionIdentity {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][object] $Promotion,
        [Parameter(Mandatory = $true)][string] $Context
    )

    Assert-BunkFyCandidateProperties `
        -Value $Value `
        -ExpectedProperties @('releaseId', 'sourceCommit', 'promotionEvidenceReference', 'promotionChecksumsSha256', 'images') `
        -Context $Context
    if ($Value.releaseId -cne $Promotion.ReleaseId -or
        $Value.sourceCommit -cne $Promotion.SourceCommit -or
        $Value.promotionEvidenceReference -cne $Promotion.PromotionEvidenceReference -or
        $Value.promotionChecksumsSha256 -cne $Promotion.ChecksumsSha256) {
        throw "$Context does not match verified promotion evidence."
    }
    $images = @($Value.images | Sort-Object name)
    $expectedImages = @($Promotion.Images | Sort-Object Name)
    if ($images.Count -ne 2 -or $expectedImages.Count -ne 2) {
        throw "$Context must bind backend and web images."
    }
    for ($index = 0; $index -lt 2; $index++) {
        Assert-BunkFyCandidateProperties `
            -Value $images[$index] `
            -ExpectedProperties @('name', 'digestReference') `
            -Context "$Context image"
        if ($images[$index].name -cne $expectedImages[$index].Name -or
            $images[$index].digestReference -cne $expectedImages[$index].DigestReference) {
            throw "$Context contains a different image identity."
        }
    }
}

function Get-BunkFyVerifiedProductionMigrationRehearsal {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedSourceCommit,
        [Parameter(Mandatory = $true)][string] $ExpectedBackendDigest
    )

    $source = Get-BunkFyProductionAdmissionEvidenceFile `
        -Path $Path `
        -Context 'production migration rehearsal evidence'
    $record = $source.Record
    Assert-BunkFyCandidateProperties `
        -Value $record `
        -ExpectedProperties @('schemaVersion', 'evidenceKind', 'completedAtUtc', 'runId', 'sourceCommitSha', 'images', 'isolation', 'plan', 'admission', 'apply') `
        -Context 'production migration rehearsal evidence'
    Assert-BunkFyCandidateProperties -Value $record.images -ExpectedProperties @('backend', 'postgresql') -Context 'migration image identities'
    foreach ($name in @('backend', 'postgresql')) {
        Assert-BunkFyCandidateProperties `
            -Value $record.images.$name `
            -ExpectedProperties @('reference', 'imageId', 'repositoryDigest') `
            -Context "migration $name image identity"
        if ($record.images.$name.imageId -cnotmatch '^sha256:[a-f0-9]{64}$' -or
            $record.images.$name.repositoryDigest -cnotmatch '^sha256:[a-f0-9]{64}$') {
            throw "Migration $name image identity is invalid."
        }
    }
    Assert-BunkFyCandidateProperties -Value $record.isolation -ExpectedProperties @('internalNetwork', 'publishedPorts', 'persistentVolumes', 'resourcesRemoved') -Context 'migration isolation evidence'
    Assert-BunkFyCandidateProperties -Value $record.plan -ExpectedProperties @('databaseTargetSha256', 'targetCatalogVersion', 'targetCatalogSha256', 'currentStateSha256', 'pendingPlanSha256', 'moduleCount', 'targetMigrationCount', 'appliedMigrationCount', 'pendingMigrationCount', 'schemaFingerprintBefore', 'noMutation') -Context 'migration plan evidence'
    Assert-BunkFyCandidateProperties -Value $record.admission -ExpectedProperties @('malformedSourceRejected', 'malformedBackupReferenceRejected', 'wrongDatabaseTargetRejected') -Context 'migration admission evidence'
    Assert-BunkFyCandidateProperties -Value $record.apply -ExpectedProperties @('appliedMigrationCount', 'pendingMigrationCount', 'resultingStateSha256', 'schemaFingerprintAfter', 'idempotentRerun') -Context 'migration apply evidence'

    if ($record.schemaVersion -ne 1 -or
        $record.evidenceKind -cne 'bunkfy-production-migration-rehearsal' -or
        $record.sourceCommitSha -cne $ExpectedSourceCommit -or
        $record.images.backend.repositoryDigest -cne $ExpectedBackendDigest -or
        $record.runId -cnotmatch '^[a-f0-9]{12}$' -or
        $record.isolation.internalNetwork -isnot [bool] -or
        -not $record.isolation.internalNetwork -or
        [int]$record.isolation.publishedPorts -ne 0 -or
        [int]$record.isolation.persistentVolumes -ne 0 -or
        $record.isolation.resourcesRemoved -isnot [bool] -or
        -not $record.isolation.resourcesRemoved -or
        $record.plan.noMutation -isnot [bool] -or
        -not $record.plan.noMutation -or
        [int]$record.plan.moduleCount -le 0 -or
        [int]$record.plan.targetMigrationCount -le 0 -or
        [int]$record.plan.pendingMigrationCount -le 0 -or
        [int]$record.apply.pendingMigrationCount -ne 0 -or
        [int]$record.apply.appliedMigrationCount -ne [int]$record.plan.targetMigrationCount -or
        $record.apply.idempotentRerun -isnot [bool] -or
        -not $record.apply.idempotentRerun -or
        $record.admission.malformedSourceRejected -isnot [bool] -or
        -not $record.admission.malformedSourceRejected -or
        $record.admission.malformedBackupReferenceRejected -isnot [bool] -or
        -not $record.admission.malformedBackupReferenceRejected -or
        $record.admission.wrongDatabaseTargetRejected -isnot [bool] -or
        -not $record.admission.wrongDatabaseTargetRejected) {
        throw 'Production migration rehearsal evidence does not prove the admitted candidate path.'
    }
    foreach ($property in @('databaseTargetSha256', 'targetCatalogSha256', 'currentStateSha256', 'pendingPlanSha256', 'schemaFingerprintBefore')) {
        [void](Assert-BunkFyProductionAdmissionSha256 -Value ([string]$record.plan.$property) -Context "migration plan $property")
    }
    foreach ($property in @('resultingStateSha256', 'schemaFingerprintAfter')) {
        [void](Assert-BunkFyProductionAdmissionSha256 -Value ([string]$record.apply.$property) -Context "migration apply $property")
    }
    if ($record.plan.schemaFingerprintBefore -ceq $record.apply.schemaFingerprintAfter) {
        throw 'Production migration rehearsal did not advance the empty schema.'
    }
    $completedAt = ConvertTo-BunkFyProductionAdmissionTimestamp `
        -Value $record.completedAtUtc `
        -Context 'migration rehearsal completion time'
    return [pscustomobject]@{
        Name = 'production-migration'
        EvidenceKind = [string]$record.evidenceKind
        SourceSha256 = $source.Sha256
        GeneratedAtUtc = $completedAt
        CheckCount = 6
        Record = $record
        Path = $source.Path
    }
}

function Get-BunkFyVerifiedDeployedRollbackRehearsal {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][Uri] $ExpectedOrigin,
        [Parameter(Mandatory = $true)][object] $CandidatePromotion,
        [Parameter(Mandatory = $true)][object] $RollbackPromotion,
        [switch] $AllowFixtureEvidence
    )

    $resolvedDirectory = [IO.Path]::GetFullPath($Directory)
    $closed = Get-BunkFyClosedChecksumSet `
        -Directory $resolvedDirectory `
        -MaximumPayloadBytes 4MB `
        -Context 'deployed rollback rehearsal evidence'
    $expectedFiles = @('candidate-baseline-public-edge.json', 'candidate-restored-public-edge.json', 'rollback-public-edge.json', 'rollback-rehearsal.json')
    Assert-BunkFyProductionAdmissionStringSequence `
        -Actual @($closed.Files.RelativePath) `
        -Expected $expectedFiles `
        -Context 'deployed rollback rehearsal files' `
        -OrderIndependent
    $recordPath = Join-Path $resolvedDirectory 'rollback-rehearsal.json'
    $source = Get-BunkFyProductionAdmissionEvidenceFile -Path $recordPath -Context 'deployed rollback rehearsal record'
    $record = $source.Record
    Assert-BunkFyCandidateProperties `
        -Value $record `
        -ExpectedProperties @('schemaVersion', 'evidenceKind', 'rehearsalId', 'rollbackEvidenceReference', 'generatedAtUtc', 'result', 'origin', 'candidate', 'rollback', 'timing', 'checks', 'limitations') `
        -Context 'deployed rollback rehearsal record'
    if ($record.schemaVersion -ne 1 -or
        $record.evidenceKind -cne 'bunkfy-deployed-release-rollback-rehearsal' -or
        $record.result -cne 'passed' -or
        $record.origin -cne $ExpectedOrigin.GetLeftPart([UriPartial]::Authority)) {
        throw 'Deployed rollback rehearsal does not match the candidate origin.'
    }
    $rehearsalId = [Guid]::Empty
    if (-not [Guid]::TryParseExact([string]$record.rehearsalId, 'D', [ref]$rehearsalId) -or
        $rehearsalId -eq [Guid]::Empty -or
        $record.rollbackEvidenceReference -cne "rollback:$($rehearsalId.ToString('N'))") {
        throw 'Deployed rollback rehearsal has an invalid identity.'
    }
    Assert-BunkFyProductionAdmissionPromotionIdentity -Value $record.candidate -Promotion $CandidatePromotion -Context 'rollback candidate identity'
    Assert-BunkFyProductionAdmissionPromotionIdentity -Value $record.rollback -Promotion $RollbackPromotion -Context 'rollback release identity'

    $expectedChecks = [ordered]@{
        'candidate-baseline-public-edge' = [pscustomobject]@{ File = 'candidate-baseline-public-edge.json'; ReleaseId = $CandidatePromotion.ReleaseId }
        'candidate-restored-public-edge' = [pscustomobject]@{ File = 'candidate-restored-public-edge.json'; ReleaseId = $CandidatePromotion.ReleaseId }
        'rollback-public-edge' = [pscustomobject]@{ File = 'rollback-public-edge.json'; ReleaseId = $RollbackPromotion.ReleaseId }
    }
    $checks = @($record.checks)
    if ($checks.Count -ne $expectedChecks.Count) {
        throw 'Deployed rollback rehearsal must contain three release checks.'
    }
    foreach ($check in $checks) {
        Assert-BunkFyCandidateProperties -Value $check -ExpectedProperties @('name', 'result', 'releaseId', 'evidenceFile', 'evidenceSha256') -Context 'rollback release check'
        $expected = $expectedChecks[[string]$check.name]
        if ($null -eq $expected -or
            $check.result -cne 'passed' -or
            $check.releaseId -cne $expected.ReleaseId -or
            $check.evidenceFile -cne $expected.File) {
            throw 'Deployed rollback rehearsal contains an unsupported release check.'
        }
        $edgePath = Join-Path $resolvedDirectory $expected.File
        $edge = Get-BunkFyVerifiedProductionAdmissionProbe `
            -Path $edgePath `
            -SpecificationName 'public-edge' `
            -ExpectedOrigin $ExpectedOrigin `
            -ExpectedReleaseId $expected.ReleaseId `
            -AllowFixtureEvidence:$AllowFixtureEvidence
        if ($check.evidenceSha256 -cne $edge.SourceSha256) {
            throw "Deployed rollback rehearsal check '$($check.name)' has the wrong evidence hash."
        }
    }
    Assert-BunkFyCandidateProperties -Value $record.timing -ExpectedProperties @('startedAtUtc', 'baselineVerifiedAtUtc', 'rollbackObservedAtUtc', 'rollbackVerifiedAtUtc', 'candidateRestoredObservedAtUtc', 'completedAtUtc', 'rollbackConvergenceMilliseconds', 'restorationConvergenceMilliseconds', 'totalDurationMilliseconds') -Context 'rollback timing evidence'
    $times = @{}
    foreach ($name in @('startedAtUtc', 'baselineVerifiedAtUtc', 'rollbackObservedAtUtc', 'rollbackVerifiedAtUtc', 'candidateRestoredObservedAtUtc', 'completedAtUtc')) {
        $times[$name] = ConvertTo-BunkFyProductionAdmissionTimestamp -Value $record.timing.$name -Context "rollback $name"
    }
    if ($times.startedAtUtc -gt $times.baselineVerifiedAtUtc -or
        $times.baselineVerifiedAtUtc -gt $times.rollbackObservedAtUtc -or
        $times.rollbackObservedAtUtc -gt $times.rollbackVerifiedAtUtc -or
        $times.rollbackVerifiedAtUtc -gt $times.candidateRestoredObservedAtUtc -or
        $times.candidateRestoredObservedAtUtc -gt $times.completedAtUtc -or
        [long]$record.timing.rollbackConvergenceMilliseconds -lt 0 -or
        [long]$record.timing.restorationConvergenceMilliseconds -lt 0 -or
        [long]$record.timing.totalDurationMilliseconds -lt 0 -or
        [string]$record.generatedAtUtc -cne [string]$record.timing.completedAtUtc) {
        throw 'Deployed rollback rehearsal timing is inconsistent.'
    }
    Assert-BunkFyProductionAdmissionStringSequence `
        -Actual @($record.limitations) `
        -Expected @('deployment-control-plane-and-commands-not-observed', 'worker-and-admin-release-identities-not-observed', 'public-smoke-does-not-prove-all-schema-and-domain-compatibility', 'registry-availability-and-immutability-not-reverified', 'hosted-approval-alerting-and-traffic-drain-not-observed') `
        -Context 'deployed rollback rehearsal limitations'
    return [pscustomobject]@{
        Name = 'deployed-release-rollback'
        EvidenceKind = [string]$record.evidenceKind
        SourceSha256 = $closed.ChecksumsSha256
        GeneratedAtUtc = $times.completedAtUtc
        CheckCount = 3
        Reference = [string]$record.rollbackEvidenceReference
        Record = $record
        Directory = $resolvedDirectory
    }
}

function ConvertTo-BunkFyProductionAdmissionPromotionSummary {
    param([Parameter(Mandatory = $true)][object] $Promotion)

    return [ordered]@{
        releaseId = $Promotion.ReleaseId
        sourceCommit = $Promotion.SourceCommit
        promotionEvidenceReference = $Promotion.PromotionEvidenceReference
        promotionChecksumsSha256 = $Promotion.ChecksumsSha256
        images = @($Promotion.Images | Sort-Object Name | ForEach-Object {
                [ordered]@{
                    name = $_.Name
                    digestReference = $_.DigestReference
                }
            })
    }
}

function Get-BunkFyProductionAdmissionExpectedEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateReleaseId,
        [Parameter(Mandatory = $true)][string] $RollbackReleaseId
    )

    return [ordered]@{
        'candidate-image-promotion' = [pscustomobject]@{ Kind = 'bunkfy-image-promotion'; ReleaseId = $CandidateReleaseId; Count = 2 }
        'deployed-adapter-host' = [pscustomobject]@{ Kind = 'bunkfy-deployed-adapter-host-probe'; ReleaseId = $CandidateReleaseId; Count = 8 }
        'deployed-admin-allowed' = [pscustomobject]@{ Kind = 'bunkfy-deployed-admin-boundary-probe'; ReleaseId = $CandidateReleaseId; Count = 5 }
        'deployed-admin-denied' = [pscustomobject]@{ Kind = 'bunkfy-deployed-admin-boundary-probe'; ReleaseId = $CandidateReleaseId; Count = 4 }
        'deployed-operations-notifications' = [pscustomobject]@{ Kind = 'bunkfy-deployed-operations-notifications-probe'; ReleaseId = $CandidateReleaseId; Count = 10 }
        'deployed-public-edge' = [pscustomobject]@{ Kind = 'bunkfy-deployed-public-edge-probe'; ReleaseId = $CandidateReleaseId; Count = 6 }
        'deployed-release-rollback' = [pscustomobject]@{ Kind = 'bunkfy-deployed-release-rollback-rehearsal'; ReleaseId = $CandidateReleaseId; Count = 3 }
        'deployed-retention' = [pscustomobject]@{ Kind = 'bunkfy-deployed-retention-probe'; ReleaseId = $CandidateReleaseId; Count = 7 }
        'deployed-workspace-enrollment' = [pscustomobject]@{ Kind = 'bunkfy-deployed-workspace-enrollment-probe'; ReleaseId = $CandidateReleaseId; Count = 9 }
        'deployed-workspace-invitation' = [pscustomobject]@{ Kind = 'bunkfy-deployed-workspace-invitation-probe'; ReleaseId = $CandidateReleaseId; Count = 8 }
        'production-migration' = [pscustomobject]@{ Kind = 'bunkfy-production-migration-rehearsal'; ReleaseId = $CandidateReleaseId; Count = 6 }
        'rollback-image-promotion' = [pscustomobject]@{ Kind = 'bunkfy-image-promotion'; ReleaseId = $RollbackReleaseId; Count = 2 }
    }
}

function Get-BunkFyVerifiedProductionAdmission {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][Uri] $ExpectedPublicOrigin,
        [Parameter(Mandatory = $true)][string] $ExpectedReleaseId,
        [Parameter(Mandatory = $true)][string] $ExpectedSourceCommit,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^admission:[0-9a-f]{32}$')]
        [string] $ExpectedAdmissionEvidenceReference,
        [switch] $AllowFixtureEvidence
    )

    $origin = Assert-BunkFyPublicEdgeOrigin `
        -Origin $ExpectedPublicOrigin `
        -AllowLoopbackHttp:$AllowFixtureEvidence
    if ($AllowFixtureEvidence -and -not (Test-BunkFyLoopbackHost -HostName $origin.Host)) {
        throw 'Fixture admission evidence is restricted to an explicit loopback origin.'
    }
    $resolvedDirectory = [IO.Path]::GetFullPath($Directory)
    $closed = Get-BunkFyClosedChecksumSet -Directory $resolvedDirectory -MaximumPayloadBytes 2MB -Context 'production admission evidence'
    if ($closed.Files.Count -ne 1 -or $closed.Files[0].RelativePath -cne 'production-admission.json') {
        throw 'Production admission evidence must contain only production-admission.json and checksums.sha256.'
    }
    $source = Get-BunkFyProductionAdmissionEvidenceFile -Path (Join-Path $resolvedDirectory 'production-admission.json') -Context 'production admission record'
    $record = $source.Record
    Assert-BunkFyCandidateProperties `
        -Value $record `
        -ExpectedProperties @('schemaVersion', 'evidenceKind', 'admissionId', 'admissionEvidenceReference', 'generatedAtUtc', 'result', 'decision', 'repository', 'profile', 'candidate', 'rollback', 'deployment', 'evidence', 'privateEvidence', 'checks', 'limitations') `
        -Context 'production admission record'
    $admissionId = [Guid]::Empty
    $expectedProfile = if ($AllowFixtureEvidence) { 'loopback-fixture' } else { 'production' }
    if ($record.schemaVersion -ne 1 -or
        $record.evidenceKind -cne 'bunkfy-production-admission-bundle' -or
        $record.result -cne 'passed' -or
        $record.decision -cne 'evidence-complete-awaiting-private-approval' -or
        $record.repository -cne 'SadPossum/BunkFy' -or
        $record.profile -cne $expectedProfile -or
        -not [Guid]::TryParseExact([string]$record.admissionId, 'D', [ref]$admissionId) -or
        $admissionId -eq [Guid]::Empty -or
        $record.admissionEvidenceReference -cne "admission:$($admissionId.ToString('N'))") {
        throw 'Production admission record has an invalid identity or result.'
    }
    if ($record.admissionEvidenceReference -cne $ExpectedAdmissionEvidenceReference) {
        throw 'Production admission record does not match the expected admission evidence reference.'
    }
    [void](ConvertTo-BunkFyProductionAdmissionTimestamp -Value $record.generatedAtUtc -Context 'production admission generation time')
    Assert-BunkFyCandidateProperties -Value $record.candidate -ExpectedProperties @('releaseId', 'sourceCommit', 'promotionEvidenceReference', 'promotionChecksumsSha256', 'images') -Context 'admission candidate identity'
    Assert-BunkFyCandidateProperties -Value $record.rollback -ExpectedProperties @('releaseId', 'sourceCommit', 'promotionEvidenceReference', 'promotionChecksumsSha256', 'images') -Context 'admission rollback identity'
    if ($record.candidate.releaseId -cne $ExpectedReleaseId -or
        $record.candidate.sourceCommit -cne $ExpectedSourceCommit -or
        $record.rollback.releaseId -ceq $ExpectedReleaseId -or
        $record.rollback.sourceCommit -ceq $ExpectedSourceCommit) {
        throw 'Production admission record does not bind a distinct rollback to the expected candidate.'
    }
    foreach ($identityName in @('candidate', 'rollback')) {
        $identity = $record.$identityName
        [void](Assert-BunkFyProductionAdmissionSha256 -Value ([string]$identity.promotionChecksumsSha256) -Context "$identityName promotion checksum")
        [void](Assert-BunkFyProductionAdmissionReference -Value ([string]$identity.promotionEvidenceReference) -Name "$identityName promotion reference")
        $images = @($identity.images | Sort-Object name)
        if (($images.name -join "`n") -cne "backend`nweb") {
            throw "Production admission $identityName identity must contain backend and web images."
        }
        foreach ($image in $images) {
            Assert-BunkFyCandidateProperties -Value $image -ExpectedProperties @('name', 'digestReference') -Context "$identityName image identity"
            if ([string]$image.digestReference -notmatch '@sha256:[a-f0-9]{64}$' -or
                [string]$image.digestReference -match '[\s\\?#]' -or
                [string]$image.digestReference -match '://') {
                throw "Production admission $identityName image identity is invalid."
            }
        }
    }
    Assert-BunkFyCandidateProperties -Value $record.deployment -ExpectedProperties @('publicOrigin', 'rollbackEvidenceReference', 'adminEvidenceSetId') -Context 'admission deployment identity'
    if ($record.deployment.publicOrigin -cne $origin.GetLeftPart([UriPartial]::Authority)) {
        throw 'Production admission record has the wrong public origin.'
    }
    [void](Assert-BunkFyProductionAdmissionReference -Value ([string]$record.deployment.rollbackEvidenceReference) -Name 'rollback evidence reference')
    $adminEvidenceSetId = [Guid]::Empty
    if (-not [Guid]::TryParseExact([string]$record.deployment.adminEvidenceSetId, 'D', [ref]$adminEvidenceSetId) -or
        $adminEvidenceSetId -eq [Guid]::Empty) {
        throw 'Production admission record has an invalid Admin evidence set id.'
    }

    $expectedEvidence = Get-BunkFyProductionAdmissionExpectedEvidence -CandidateReleaseId $ExpectedReleaseId -RollbackReleaseId ([string]$record.rollback.releaseId)
    $evidence = @($record.evidence)
    if ($evidence.Count -ne $expectedEvidence.Count) {
        throw 'Production admission record has an incomplete source evidence catalogue.'
    }
    $seenEvidence = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $evidence) {
        Assert-BunkFyCandidateProperties -Value $entry -ExpectedProperties @('name', 'evidenceKind', 'boundReleaseId', 'sourceSha256', 'observedAtUtc', 'proofCount') -Context 'admission source evidence entry'
        if (-not $seenEvidence.Add([string]$entry.name)) {
            throw 'Production admission source evidence names must be unique.'
        }
        $expected = $expectedEvidence[[string]$entry.name]
        if ($null -eq $expected -or
            $entry.evidenceKind -cne $expected.Kind -or
            $entry.boundReleaseId -cne $expected.ReleaseId -or
            [int]$entry.proofCount -ne $expected.Count) {
            throw "Production admission source '$($entry.name)' has an invalid binding."
        }
        [void](Assert-BunkFyProductionAdmissionSha256 -Value ([string]$entry.sourceSha256) -Context "admission source '$($entry.name)' checksum")
        [void](ConvertTo-BunkFyProductionAdmissionTimestamp -Value $entry.observedAtUtc -Context "admission source '$($entry.name)' observation time")
    }

    $privateEvidence = @($record.privateEvidence)
    if ($privateEvidence.Count -ne $script:BunkFyProductionAdmissionPrivateControls.Count) {
        throw 'Production admission record has an incomplete private evidence declaration.'
    }
    $privateControls = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $privateEvidence) {
        Assert-BunkFyCandidateProperties -Value $entry -ExpectedProperties @('control', 'reference') -Context 'private evidence declaration'
        if (-not $privateControls.Add([string]$entry.control)) {
            throw 'Production admission private evidence controls must be unique.'
        }
        [void](Assert-BunkFyProductionAdmissionReference -Value ([string]$entry.reference) -Name "private evidence '$($entry.control)'")
    }
    Assert-BunkFyProductionAdmissionStringSequence -Actual @($privateControls) -Expected $script:BunkFyProductionAdmissionPrivateControls -Context 'private evidence controls' -OrderIndependent

    $checks = @($record.checks)
    if ($checks.Count -ne $script:BunkFyProductionAdmissionChecks.Count) {
        throw 'Production admission record has an invalid check count.'
    }
    foreach ($check in $checks) {
        Assert-BunkFyCandidateProperties -Value $check -ExpectedProperties @('name', 'status') -Context 'production admission check'
        if ($check.status -cne 'passed') {
            throw 'Production admission record contains a failing check.'
        }
    }
    Assert-BunkFyProductionAdmissionStringSequence -Actual @($checks.name) -Expected $script:BunkFyProductionAdmissionChecks -Context 'production admission checks' -OrderIndependent
    Assert-BunkFyProductionAdmissionStringSequence -Actual @($record.limitations) -Expected $script:BunkFyProductionAdmissionLimitations -Context 'production admission limitations'

    return [pscustomobject]@{
        Directory = $resolvedDirectory
        ChecksumsSha256 = $closed.ChecksumsSha256
        AdmissionId = $admissionId
        AdmissionEvidenceReference = [string]$record.admissionEvidenceReference
        ReleaseId = [string]$record.candidate.releaseId
        SourceCommit = [string]$record.candidate.sourceCommit
        RollbackReleaseId = [string]$record.rollback.releaseId
        PublicOrigin = [string]$record.deployment.publicOrigin
        Record = $record
    }
}
