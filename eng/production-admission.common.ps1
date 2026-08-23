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
    'runtime-topology-restart-and-credential-rotation',
    'workspace-access-seed-estate')
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
        [Parameter(Mandatory = $true)][string] $Context,
        [switch] $AllowFuture
    )

    $timestampRequirement = if ($AllowFuture) {
        'a valid UTC round-trip timestamp'
    }
    else {
        'a valid non-future UTC round-trip timestamp'
    }
    $parsed = [DateTimeOffset]::MinValue
    if ($Value -is [DateTimeOffset]) {
        $parsed = [DateTimeOffset]$Value
    }
    elseif ($Value -is [DateTime]) {
        $dateTime = [DateTime]$Value
        if ($dateTime.Kind -ne [DateTimeKind]::Utc) {
            throw "$Context must be $timestampRequirement."
        }
        $parsed = [DateTimeOffset]::new($dateTime)
    }
    elseif (-not [DateTimeOffset]::TryParseExact(
            [string]$Value,
            'O',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        throw "$Context must be $timestampRequirement."
    }
    if (
        $parsed.Offset -ne [TimeSpan]::Zero -or
        (-not $AllowFuture -and
         $parsed -gt [DateTimeOffset]::UtcNow.AddMinutes(5))) {
        throw "$Context must be $timestampRequirement."
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
            'reservations-inventory',
            'guests-stay-history',
            'staff-employment',
            'properties-topology',
            'ingestion-connection-lifecycle',
            'ingestion-conflict-proposal-lifecycle',
            'data-rights-access-export',
            'adapter-host',
            'retention')]
        [string] $Name
    )

    switch ($Name) {
        'public-edge' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-public-edge-probe'
                SchemaVersion = 4
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'checks', 'limitations')
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
                SchemaVersion = 2
                OriginProperty = 'publicOrigin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'evidenceSetId', 'releaseId', 'admissionEvidenceReference', 'expectedAdminReachability', 'publicOrigin', 'adminOrigin', 'transport', 'result', 'adminObservation', 'checks', 'limitations')
                Checks = $checks
                Limitations = @('single-vantage-point-observation', 'deployment-configuration-not-inspected', 'authenticated-admin-operations-not-executed')
                GuidProperties = @('evidenceSetId')
            }
        }
        'workspace-invitation' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-workspace-invitation-probe'
                SchemaVersion = 2
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'workspaceId', 'allowedPropertyId', 'deniedPropertyId', 'sourceId', 'applicationId', 'membershipId', 'staffMemberId', 'checks', 'limitations')
                Checks = @('recipient-bound-source-issued', 'recipient-preview-authorized', 'separate-account-membership-created', 'staff-profile-converged', 'least-privilege-policy-evaluation', 'property-route-enforcement', 'same-subject-replay-stable', 'release-identity-continuous')
                Limitations = @('browser-ui-not-exercised', 'registration-and-email-delivery-not-exercised', 'joined-member-not-automatically-offboarded')
                GuidProperties = @('workspaceId', 'allowedPropertyId', 'deniedPropertyId', 'sourceId', 'applicationId', 'membershipId', 'staffMemberId')
            }
        }
        'workspace-enrollment' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-workspace-enrollment-probe'
                SchemaVersion = 2
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'workspaceId', 'allowedPropertyId', 'deniedPropertyId', 'rejected', 'approved', 'checks', 'limitations')
                Checks = @('approval-required-source-issued', 'pending-claim-has-no-access', 'owner-rejection-terminal', 'rejected-source-disabled', 'second-claim-owner-approved', 'staff-profile-converged', 'least-privilege-route-enforcement', 'same-subject-claim-replay-stable', 'release-identity-continuous')
                Limitations = @('browser-ui-and-qr-rendering-not-exercised', 'registration-and-email-delivery-not-exercised', 'joined-member-not-automatically-offboarded')
                GuidProperties = @('workspaceId', 'allowedPropertyId', 'deniedPropertyId')
            }
        }
        'operations-notifications' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-operations-notifications-probe'
                SchemaVersion = 3
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'workflow', 'delivery', 'cleanup', 'checks', 'limitations')
                Checks = @('distinct-scoped-identities-preflight', 'cross-workspace-history-denied', 'created-notification-live-streamed', 'created-notification-detail-and-read-state', 'released-notification-live-streamed', 'released-notification-detail-and-read-state', 'initiating-actor-excluded', 'observer-history-exactly-once', 'inventory-block-cleanup-confirmed', 'release-identity-continuous')
                Limitations = @('browser-attention-rendering-not-exercised', 'external-delivery-adapters-not-exercised', 'released-block-and-notification-history-retained')
                GuidProperties = @()
            }
        }
        'reservations-inventory' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-reservations-inventory-probe'
                SchemaVersion = 3
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'workflow', 'cleanup', 'checks', 'limitations')
                Checks = @('cross-workspace-inventory-read-denied', 'scoped-operator-and-property-preflight', 'inventory-available-before-create', 'reservation-allocation-confirmed', 'reservation-create-replay-stable', 'allocated-inventory-unavailable', 'reservation-check-in-recorded', 'reservation-check-in-replay-stable', 'reservation-checkout-converged', 'reservation-checkout-replay-current', 'inventory-released-after-checkout', 'release-identity-continuous')
                Limitations = @('browser-workflow-not-exercised', 'durable-guest-record-not-created', 'concurrent-overbooking-contention-not-exercised', 'synthetic-checked-out-reservation-retained')
                GuidProperties = @()
            }
        }
        'guests-stay-history' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-guests-stay-history-probe'
                SchemaVersion = 2
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'workflow', 'cleanup', 'checks', 'limitations')
                Checks = @('scoped-operator-property-and-inventory-preflight', 'nonmember-guest-directory-denied', 'guest-created-with-minimal-profile', 'guest-create-replay-stable', 'guest-create-conflict-rejected', 'guest-detail-and-active-directory-visible', 'guest-versioned-update-recorded', 'guest-update-replay-stable', 'guest-conflicting-and-stale-updates-rejected', 'guest-update-visible', 'reservation-allocation-confirmed', 'reservation-primary-guest-link-replay-stable', 'guest-stay-confirmed-projection-converged', 'guest-stay-check-in-projection-converged', 'guest-stay-checkout-projection-converged', 'terminal-reservation-retained-and-inventory-released', 'guest-archive-replay-stable', 'archived-guest-directory-and-history-consistent', 'release-identity-continuous')
                Limitations = @('browser-guest-workflow-not-exercised', 'guest-deduplication-merge-and-consent-not-exercised', 'concurrent-participant-and-overbooking-contention-not-exercised', 'synthetic-archived-guest-and-checked-out-reservation-retained')
                GuidProperties = @()
            }
        }
        'staff-employment' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-staff-employment-probe'
                SchemaVersion = 2
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'workflow', 'cleanup', 'checks', 'limitations')
                Checks = @('scoped-operator-and-property-preflight', 'nonmember-staff-directory-denied', 'staff-created-with-minimal-unlinked-profile', 'staff-create-replay-stable', 'staff-create-conflict-rejected', 'staff-directory-and-sensitive-profile-coherent', 'staff-versioned-update-recorded', 'staff-update-replay-stable', 'staff-update-conflict-rejected', 'staff-stale-update-rejected', 'staff-update-visible', 'staff-property-assignment-recorded', 'staff-assignment-replay-stable', 'staff-assignment-conflict-rejected', 'staff-canonical-and-property-assignment-visible', 'staff-suspension-replay-stable-and-assignment-retained', 'staff-resume-replay-stable', 'staff-departure-replay-stable', 'staff-departure-closes-current-assignment', 'staff-active-and-departed-filters-coherent', 'release-identity-continuous')
                Limitations = @('browser-staff-workflow-not-exercised', 'account-link-membership-and-role-lifecycle-not-exercised', 'governance-data-rights-and-retention-not-exercised', 'synthetic-departed-staff-record-retained')
                GuidProperties = @()
            }
        }
        'properties-topology' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-properties-topology-probe'
                SchemaVersion = 2
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'workflow', 'cleanup', 'checks', 'limitations')
                Checks = @('scoped-operator-preflight', 'nonmember-property-directory-denied', 'property-created', 'property-create-replay-stable', 'property-create-conflict-rejected', 'property-detail-and-directory-visible', 'property-versioned-update-recorded', 'property-update-replay-stable', 'property-update-conflict-and-stale-write-rejected', 'property-update-visible', 'room-created', 'room-create-replay-stable-and-conflict-rejected', 'room-versioned-update-recorded', 'room-update-replay-conflict-and-stale-write-enforced', 'room-detail-and-directory-visible', 'bed-batch-created-atomically', 'bed-batch-replay-stable-and-conflict-rejected', 'bed-directory-visible', 'bed-versioned-update-recorded', 'bed-update-replay-conflict-and-stale-write-enforced', 'bed-update-visible', 'property-retirement-blocked-by-active-room', 'direct-topology-retirement-requires-inventory', 'bed-retirement-request-replay-stable', 'bed-retirement-completed', 'room-retirement-request-replay-stable', 'room-and-beds-retirement-completed', 'property-retirement-replay-stable', 'property-retirement-conflict-rejected', 'retired-topology-directories-and-processing-consistent', 'release-identity-continuous')
                Limitations = @('browser-properties-workflow-not-exercised', 'country-policy-activation-suspension-and-rebinding-not-exercised', 'occupied-and-blocked-topology-drain-not-exercised', 'synthetic-retired-topology-retained')
                GuidProperties = @()
            }
        }
        'ingestion-connection-lifecycle' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-ingestion-connection-lifecycle-probe'
                SchemaVersion = 2
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'workflow', 'cleanup', 'checks', 'limitations')
                Checks = @('scoped-operator-and-processing-preflight', 'nonmember-connections-denied', 'remote-capability-discovered', 'connection-created', 'connection-create-replay-stable', 'connection-create-conflict-rejected', 'connection-directory-detail-and-health-visible', 'connection-updated-with-secret-reference', 'connection-update-replay-stable', 'connection-update-conflict-and-stale-write-rejected', 'secret-reference-cleared', 'connection-disabled', 'connection-disable-replay-stable', 'connection-disable-conflict-and-stale-write-rejected', 'connection-enabled', 'connection-enable-replay-stable', 'connection-enable-conflict-and-stale-write-rejected', 'ingress-credential-issued-once', 'ingress-credential-replay-withholds-token', 'ingress-credential-create-conflict-rejected', 'ingress-credential-directory-visible', 'remote-lease-claimed-with-issued-credential', 'zero-observation-run-completed', 'terminal-run-and-health-visible', 'credential-authentication-telemetry-visible', 'ingress-credential-revoked', 'ingress-credential-revoke-replay-stable', 'ingress-credential-revoke-conflict-and-stale-write-rejected', 'revoked-credential-denied', 'connection-finally-disabled', 'terminal-projections-consistent', 'release-identity-continuous')
                Limitations = @('provider-record-receipt-proposal-and-checkpoint-not-exercised', 'country-policy-activation-and-rebinding-not-exercised', 'production-secret-manager-and-orchestrator-rotation-not-exercised', 'synthetic-disabled-control-state-retained')
                GuidProperties = @()
            }
        }
        'ingestion-conflict-proposal-lifecycle' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-ingestion-conflict-proposal-lifecycle-probe'
                SchemaVersion = 2
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'adapterContract', 'authorityRevisions', 'proposalSummary', 'cleanup', 'checks', 'limitations')
                Checks = @('scoped-operator-processing-and-inventory-preflight', 'nonmember-proposal-read-denied', 'push-capability-discovered', 'push-connection-and-credential-created', 'adapter-ingress-requires-independent-authentication', 'initial-observation-auto-created-reservation', 'observation-replay-is-stable', 'baseline-current-update-auto-applied', 'staff-edit-established-new-authority', 'staff-conflict-created-pending-proposal', 'pending-proposal-did-not-overwrite-staff-state', 'newer-source-proposal-superseded-older-pending', 'only-newest-proposal-remains-actionable', 'superseded-proposal-decision-rejected', 'newest-proposal-rejected-with-audit-reason', 'proposal-rejection-replay-and-conflict-safe', 'later-source-update-created-fresh-proposal', 'proposal-acceptance-started-versioned-operation', 'accepted-proposal-converged-in-reservations', 'proposal-acceptance-replay-and-conflict-safe', 'stale-source-input-created-no-actionable-work', 'reservation-history-preserved-authority-provenance', 'adapter-cancellation-completed-terminally', 'credential-revoked-and-connection-disabled', 'release-identity-continuous', 'terminal-proposal-projection-consistent')
                Limitations = @('synthetic-reservation-data-only', 'loopback-preview-is-not-hosted-production-proof', 'provider-acquisition-and-parser-correctness-not-exercised', 'proposal-acceptance-race-to-stale-covered-by-focused-integration-tests', 'production-country-policy-and-provider-credential-approval-not-exercised')
                GuidProperties = @()
            }
        }
        'data-rights-access-export' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-data-rights-access-export-probe'
                SchemaVersion = 2
                OriginProperty = 'origin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'origin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'workflow', 'artifact', 'cleanup', 'checks', 'limitations')
                Checks = @('scoped-assured-operator-and-property-preflight', 'nonmember-case-access-denied', 'synthetic-guest-created', 'controller-initiated-case-entered-discovery', 'exact-guest-subject-discovered-and-selected', 'review-and-decision-approved', 'export-generation-requested', 'export-request-replay-stable', 'second-artifact-request-denied', 'worker-export-generation-converged', 'case-completed-with-approved-scope', 'unassured-export-download-denied', 'nonmember-export-download-denied', 'protected-download-headers-and-shape-verified', 'download-replay-stable', 'synthetic-guest-archived', 'artifact-expiry-bounded-and-scheduled', 'release-identity-continuous')
                Limitations = @('browser-privacy-workflow-not-exercised', 'multi-subject-and-large-exports-not-exercised', 'independent-object-store-and-key-custody-not-inspected', 'case-history-and-encrypted-artifact-retained-until-configured-lifecycle')
                GuidProperties = @()
            }
        }
        'adapter-host' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-adapter-host-probe'
                SchemaVersion = 2
                OriginProperty = 'publicOrigin'
                TransportProperty = 'publicTransport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'publicOrigin', 'releaseId', 'admissionEvidenceReference', 'adapterHostOrigin', 'publicTransport', 'adapterHostTransport', 'result', 'workspaceId', 'propertyId', 'connectionId', 'adapterType', 'workerId', 'statusEndpointExposure', 'run', 'receipt', 'checks', 'limitations')
                Checks = @('adapter-host-ready-and-exposure-correct', 'remote-polling-connection-preflight', 'remote-lease-run-proof-complete', 'durable-receipt-provenance-correlated', 'server-checkpoint-advanced', 'connection-health-converged', 'adapter-host-post-cycle-healthy', 'release-identity-continuous')
                Limitations = @('synthetic-provider-record-injection-not-performed-by-probe', 'credential-rotation-and-process-restart-not-exercised', 'production-admission-log-and-orchestrator-topology-not-observed', 'raw-payload-content-not-read')
                GuidProperties = @('workspaceId', 'propertyId', 'connectionId', 'workerId')
            }
        }
        'retention' {
            return [pscustomobject]@{
                Name = $Name
                EvidenceKind = 'bunkfy-deployed-retention-probe'
                SchemaVersion = 3
                OriginProperty = 'publicOrigin'
                TransportProperty = 'transport'
                Properties = @('schemaVersion', 'evidenceKind', 'generatedAtUtc', 'publicOrigin', 'releaseId', 'admissionEvidenceReference', 'transport', 'result', 'workspaceId', 'observedDataClassKey', 'catalogueCount', 'observation', 'schedules', 'checks', 'limitations')
                Checks = @('retention-catalogue-present', 'cross-workspace-retention-denied', 'automatic-retention-occurrence-observed', 'retention-schedules-terminal-and-current', 'retention-summary-consistent', 'retention-outcomes-pii-minimized', 'release-identity-continuous')
                Limitations = @('owner-data-not-seeded-or-read', 'generic-task-lease-and-restart-not-observed', 'legal-hold-and-admin-retry-not-exercised', 'private-maintenance-owner-topology-and-alerting-not-observed')
                GuidProperties = @('workspaceId')
            }
        }
    }
}

function Assert-BunkFyRetentionAdmissionEvidence {
    param(
        [Parameter(Mandatory = $true)][object] $Record,
        [Parameter(Mandatory = $true)][DateTimeOffset] $GeneratedAt
    )

    if ([string]$Record.observedDataClassKey -cne 'raw-source-evidence' -or
        [int]$Record.catalogueCount -lt 2 -or
        [int]$Record.catalogueCount -gt 10000) {
        throw 'Retention deployment evidence has an invalid catalogue summary.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.observation `
        -ExpectedProperties @(
            'mode',
            'baselineCapturedAtUtc',
            'completionNotBeforeUtc',
            'baselineObservedRunId',
            'baselineObservedRunning',
            'clockSkewSeconds') `
        -Context 'Retention observation evidence'
    $observation = $Record.observation
    $baselineCapturedAt = ConvertTo-BunkFyProductionAdmissionTimestamp `
        -Value $observation.baselineCapturedAtUtc `
        -Context 'Retention baseline capture time'
    $clockSkewSeconds = [int]$observation.clockSkewSeconds
    if ($clockSkewSeconds -lt 0 -or
        $clockSkewSeconds -gt 600 -or
        $baselineCapturedAt -gt $GeneratedAt.AddSeconds($clockSkewSeconds)) {
        throw 'Retention observation timing is invalid.'
    }
    $baselineRunId = [Guid]::Empty
    if ($null -ne $observation.baselineObservedRunId -and
        (-not [Guid]::TryParseExact(
                [string]$observation.baselineObservedRunId,
                'D',
                [ref]$baselineRunId) -or
         $baselineRunId -eq [Guid]::Empty)) {
        throw 'Retention observation has an invalid baseline run id.'
    }
    $baselineWasRunning = [bool]$observation.baselineObservedRunning
    if ($baselineWasRunning -and $baselineRunId -eq [Guid]::Empty) {
        throw 'A running Retention baseline must identify its run.'
    }

    $completionLowerBound = $null
    switch ([string]$observation.mode) {
        'next-occurrence-after-baseline' {
            if ($null -ne $observation.completionNotBeforeUtc) {
                throw 'Next-occurrence Retention evidence cannot carry a completion lower bound.'
            }
        }
        'completed-after-lower-bound' {
            if ($null -eq $observation.completionNotBeforeUtc) {
                throw 'Lower-bound Retention evidence is missing its completion timestamp.'
            }
            $completionLowerBound = ConvertTo-BunkFyProductionAdmissionTimestamp `
                -Value $observation.completionNotBeforeUtc `
                -Context 'Retention completion lower bound'
            if ($completionLowerBound -gt
                $baselineCapturedAt.AddSeconds($clockSkewSeconds)) {
                throw 'Retention completion lower bound is after the baseline capture.'
            }
        }
        default {
            throw 'Retention deployment evidence has an unsupported observation mode.'
        }
    }

    $expectedSchedules = @{
        'raw-source-evidence' = [pscustomobject]@{
            Outcome = 'ingestion.raw-payload.completed'
            Interval = [TimeSpan]::FromHours(1)
        }
        'sensitive-reservation-history' = [pscustomobject]@{
            Outcome = 'ingestion.sensitive-history.completed'
            Interval = [TimeSpan]::FromHours(6)
        }
    }
    $schedules = @($Record.schedules)
    if ($schedules.Count -ne $expectedSchedules.Count -or
        [int]$Record.catalogueCount -lt $schedules.Count) {
        throw 'Retention deployment evidence has an invalid schedule set.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $rawRunId = [Guid]::Empty
    $rawCompletedAt = [DateTimeOffset]::MinValue
    foreach ($schedule in $schedules) {
        Assert-BunkFyCandidateProperties `
            -Value $schedule `
            -ExpectedProperties @(
                'ownerKey',
                'dataClassKey',
                'executionPolicyVersion',
                'lastRunId',
                'lastStartedAtUtc',
                'lastCompletedAtUtc',
                'nextDueAtUtc',
                'scannedCount',
                'affectedCount',
                'remainingCount',
                'outcomeCode') `
            -Context 'Retention schedule evidence'
        $dataClassKey = [string]$schedule.dataClassKey
        if (-not $seen.Add($dataClassKey) -or
            -not $expectedSchedules.ContainsKey($dataClassKey) -or
            [string]$schedule.ownerKey -cne 'ingestion' -or
            [int]$schedule.executionPolicyVersion -ne 1 -or
            [string]$schedule.outcomeCode -cne
                [string]$expectedSchedules[$dataClassKey].Outcome) {
            throw 'Retention deployment evidence has an unsupported schedule coordinate.'
        }
        $runId = [Guid]::Empty
        if (-not [Guid]::TryParseExact(
                [string]$schedule.lastRunId,
                'D',
                [ref]$runId) -or
            $runId -eq [Guid]::Empty) {
            throw 'Retention schedule evidence has an invalid run id.'
        }
        $startedAt = ConvertTo-BunkFyProductionAdmissionTimestamp `
            -Value $schedule.lastStartedAtUtc `
            -Context 'Retention schedule start time'
        $completedAt = ConvertTo-BunkFyProductionAdmissionTimestamp `
            -Value $schedule.lastCompletedAtUtc `
            -Context 'Retention schedule completion time'
        $nextDueAt = ConvertTo-BunkFyProductionAdmissionTimestamp `
            -Value $schedule.nextDueAtUtc `
            -Context 'Retention schedule next due time' `
            -AllowFuture
        if ($startedAt -gt $completedAt -or
            $completedAt -ge $nextDueAt -or
            $nextDueAt -gt
                $startedAt.Add(
                    [TimeSpan]$expectedSchedules[$dataClassKey].Interval).AddMinutes(5) -or
            $completedAt -gt $GeneratedAt.AddSeconds($clockSkewSeconds) -or
            [int]$schedule.scannedCount -lt 0 -or
            [int]$schedule.affectedCount -lt 0 -or
            [int]$schedule.affectedCount -gt [int]$schedule.scannedCount -or
            [int]$schedule.remainingCount -ne 0) {
            throw 'Retention schedule evidence has invalid timing or bounded counts.'
        }
        if ($null -ne $completionLowerBound -and
            $completedAt -lt
                $completionLowerBound.AddSeconds(-$clockSkewSeconds)) {
            throw 'Retention schedule evidence predates its completion lower bound.'
        }
        if ($dataClassKey -ceq 'raw-source-evidence') {
            $rawRunId = $runId
            $rawCompletedAt = $completedAt
        }
    }

    if ([string]$observation.mode -ceq 'next-occurrence-after-baseline') {
        if (-not $baselineWasRunning -and
            $baselineRunId -ne [Guid]::Empty -and
            $rawRunId -eq $baselineRunId) {
            throw 'Retention evidence did not advance beyond its terminal baseline run.'
        }
        if ($baselineWasRunning -and $rawRunId -ne $baselineRunId) {
            throw 'Retention evidence did not finish the run observed at baseline.'
        }
        if ($rawCompletedAt -lt
            $baselineCapturedAt.AddSeconds(-$clockSkewSeconds)) {
            throw 'Retention observed occurrence completed before its baseline.'
        }
    }
}

function Assert-BunkFyGuestsStayHistoryAdmissionEvidence {
    param([Parameter(Mandatory = $true)][object] $Record)

    Assert-BunkFyCandidateProperties `
        -Value $Record.workflow `
        -ExpectedProperties @(
            'guestFinalStatus',
            'reservationFinalStatus',
            'participantRole',
            'stayFinalStatus',
            'stayCount',
            'guestVersionAdvanced',
            'reservationVersionsMonotonic') `
        -Context 'Guests stay-history workflow'
    if ([string]$Record.workflow.guestFinalStatus -cne 'archived' -or
        [string]$Record.workflow.reservationFinalStatus -cne 'checked-out' -or
        [string]$Record.workflow.participantRole -cne 'primary' -or
        [string]$Record.workflow.stayFinalStatus -cne 'checked-out' -or
        [int]$Record.workflow.stayCount -ne 1 -or
        $Record.workflow.guestVersionAdvanced -isnot [bool] -or
        -not [bool]$Record.workflow.guestVersionAdvanced -or
        $Record.workflow.reservationVersionsMonotonic -isnot [bool] -or
        -not [bool]$Record.workflow.reservationVersionsMonotonic) {
        throw 'Guests stay-history evidence has an invalid workflow summary.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.cleanup `
        -ExpectedProperties @(
            'guestArchived',
            'reservationDisposition',
            'inventoryReleased',
            'roomDisposition') `
        -Context 'Guests stay-history cleanup'
    if ($Record.cleanup.guestArchived -isnot [bool] -or
        -not [bool]$Record.cleanup.guestArchived -or
        [string]$Record.cleanup.reservationDisposition -cne
            'synthetic-checked-out-retained' -or
        $Record.cleanup.inventoryReleased -isnot [bool] -or
        -not [bool]$Record.cleanup.inventoryReleased -or
        [string]$Record.cleanup.roomDisposition -cne 'parent-rehearsal-owned') {
        throw 'Guests stay-history evidence has an invalid cleanup disposition.'
    }
}

function Assert-BunkFyStaffEmploymentAdmissionEvidence {
    param([Parameter(Mandatory = $true)][object] $Record)

    Assert-BunkFyCandidateProperties `
        -Value $Record.workflow `
        -ExpectedProperties @(
            'finalStatus',
            'authSubjectLinked',
            'profileVersionAdvanced',
            'assignmentLifecycle',
            'currentAssignmentCount',
            'historicalAssignmentCount',
            'suspensionRetainedAssignment') `
        -Context 'Staff employment workflow'
    if ([string]$Record.workflow.finalStatus -cne 'departed' -or
        $Record.workflow.authSubjectLinked -isnot [bool] -or
        [bool]$Record.workflow.authSubjectLinked -or
        $Record.workflow.profileVersionAdvanced -isnot [bool] -or
        -not [bool]$Record.workflow.profileVersionAdvanced -or
        [string]$Record.workflow.assignmentLifecycle -cne 'assigned-then-closed' -or
        [int]$Record.workflow.currentAssignmentCount -ne 0 -or
        [int]$Record.workflow.historicalAssignmentCount -ne 1 -or
        $Record.workflow.suspensionRetainedAssignment -isnot [bool] -or
        -not [bool]$Record.workflow.suspensionRetainedAssignment) {
        throw 'Staff employment evidence has an invalid workflow summary.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.cleanup `
        -ExpectedProperties @(
            'staffDisposition',
            'currentAssignmentsClosed',
            'propertyDisposition') `
        -Context 'Staff employment cleanup'
    if ([string]$Record.cleanup.staffDisposition -cne
            'synthetic-departed-retained' -or
        $Record.cleanup.currentAssignmentsClosed -isnot [bool] -or
        -not [bool]$Record.cleanup.currentAssignmentsClosed -or
        [string]$Record.cleanup.propertyDisposition -cne
            'parent-rehearsal-owned') {
        throw 'Staff employment evidence has an invalid cleanup disposition.'
    }
}

function Assert-BunkFyPropertiesTopologyAdmissionEvidence {
    param([Parameter(Mandatory = $true)][object] $Record)

    Assert-BunkFyCandidateProperties `
        -Value $Record.workflow `
        -ExpectedProperties @(
            'propertyFinalStatus',
            'propertyVersionAdvanced',
            'processingFinalStatus',
            'roomFinalStatus',
            'roomVersionAdvanced',
            'bedCount',
            'retiredBedCount',
            'bedVersionsAdvanced',
            'retirementLifecycle',
            'directRetirementDenied') `
        -Context 'Properties topology workflow'
    if ([string]$Record.workflow.propertyFinalStatus -cne 'retired' -or
        $Record.workflow.propertyVersionAdvanced -isnot [bool] -or
        -not [bool]$Record.workflow.propertyVersionAdvanced -or
        [string]$Record.workflow.processingFinalStatus -cne
            'suspended-by-retirement' -or
        [string]$Record.workflow.roomFinalStatus -cne 'retired' -or
        $Record.workflow.roomVersionAdvanced -isnot [bool] -or
        -not [bool]$Record.workflow.roomVersionAdvanced -or
        [int]$Record.workflow.bedCount -ne 2 -or
        [int]$Record.workflow.retiredBedCount -ne 2 -or
        $Record.workflow.bedVersionsAdvanced -isnot [bool] -or
        -not [bool]$Record.workflow.bedVersionsAdvanced -or
        [string]$Record.workflow.retirementLifecycle -cne
            'bed-then-room-completed' -or
        $Record.workflow.directRetirementDenied -isnot [bool] -or
        -not [bool]$Record.workflow.directRetirementDenied) {
        throw 'Properties topology evidence has an invalid workflow summary.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.cleanup `
        -ExpectedProperties @(
            'propertyDisposition',
            'roomDisposition',
            'activeBedCount',
            'topologyRetirementsCompleted',
            'parentCleanupRequired') `
        -Context 'Properties topology cleanup'
    if ([string]$Record.cleanup.propertyDisposition -cne
            'synthetic-retired-retained' -or
        [string]$Record.cleanup.roomDisposition -cne
            'synthetic-retired-retained' -or
        [int]$Record.cleanup.activeBedCount -ne 0 -or
        $Record.cleanup.topologyRetirementsCompleted -isnot [bool] -or
        -not [bool]$Record.cleanup.topologyRetirementsCompleted -or
        $Record.cleanup.parentCleanupRequired -isnot [bool] -or
        [bool]$Record.cleanup.parentCleanupRequired) {
        throw 'Properties topology evidence has an invalid cleanup disposition.'
    }
}

function Assert-BunkFyOperationsNotificationsAdmissionEvidence {
    param([Parameter(Mandatory = $true)][object] $Record)

    Assert-BunkFyCandidateProperties `
        -Value $Record.workflow `
        -ExpectedProperties @(
            'sourceModule',
            'createdNotificationName',
            'releasedNotificationName',
            'notificationVersion',
            'deliveryTag',
            'domainTag') `
        -Context 'Operations Notifications workflow'
    if ([string]$Record.workflow.sourceModule -cne 'inventory' -or
        [string]$Record.workflow.createdNotificationName -cne
            'manual-inventory-block-created' -or
        [string]$Record.workflow.releasedNotificationName -cne
            'manual-inventory-block-released' -or
        [int]$Record.workflow.notificationVersion -ne 1 -or
        [string]$Record.workflow.deliveryTag -cne 'delivery:web' -or
        [string]$Record.workflow.domainTag -cne 'domain:inventory') {
        throw 'Operations Notifications evidence has an invalid workflow summary.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.delivery `
        -ExpectedProperties @(
            'liveNotificationCount',
            'initiallyUnreadCount',
            'durablyReadCount',
            'observerHistoryCount',
            'actorDeliveryCount',
            'ordered') `
        -Context 'Operations Notifications delivery'
    if ([int]$Record.delivery.liveNotificationCount -ne 2 -or
        [int]$Record.delivery.initiallyUnreadCount -ne 2 -or
        [int]$Record.delivery.durablyReadCount -ne 2 -or
        [int]$Record.delivery.observerHistoryCount -ne 2 -or
        [int]$Record.delivery.actorDeliveryCount -ne 0 -or
        $Record.delivery.ordered -isnot [bool] -or
        -not [bool]$Record.delivery.ordered) {
        throw 'Operations Notifications evidence has an invalid delivery summary.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.cleanup `
        -ExpectedProperties @('inventoryBlock', 'notificationHistory') `
        -Context 'Operations Notifications cleanup'
    if ([string]$Record.cleanup.inventoryBlock -cne 'released' -or
        [string]$Record.cleanup.notificationHistory -cne 'retained-read') {
        throw 'Operations Notifications evidence has an invalid cleanup disposition.'
    }
}

function Assert-BunkFyReservationsInventoryAdmissionEvidence {
    param([Parameter(Mandatory = $true)][object] $Record)

    Assert-BunkFyCandidateProperties `
        -Value $Record.workflow `
        -ExpectedProperties @(
            'bookingSource',
            'allocationLifecycle',
            'occupancyLifecycle',
            'createReplay',
            'checkInReplay',
            'checkOutReplay',
            'durableGuestRecordCreated') `
        -Context 'Reservations and Inventory workflow'
    if ([string]$Record.workflow.bookingSource -cne 'direct' -or
        [string]$Record.workflow.allocationLifecycle -cne
            'available-confirmed-released' -or
        [string]$Record.workflow.occupancyLifecycle -cne
            'confirmed-checked-in-checked-out' -or
        [string]$Record.workflow.createReplay -cne 'stable-current' -or
        [string]$Record.workflow.checkInReplay -cne 'stable-current' -or
        [string]$Record.workflow.checkOutReplay -cne 'stable-current' -or
        $Record.workflow.durableGuestRecordCreated -isnot [bool] -or
        [bool]$Record.workflow.durableGuestRecordCreated) {
        throw 'Reservations and Inventory evidence has an invalid workflow summary.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.cleanup `
        -ExpectedProperties @(
            'reservationDisposition',
            'selectedInventoryUnit',
            'activeAllocationCount',
            'topologyMutated') `
        -Context 'Reservations and Inventory cleanup'
    if ([string]$Record.cleanup.reservationDisposition -cne
            'synthetic-checked-out-retained' -or
        [string]$Record.cleanup.selectedInventoryUnit -cne 'available' -or
        [int]$Record.cleanup.activeAllocationCount -ne 0 -or
        $Record.cleanup.topologyMutated -isnot [bool] -or
        [bool]$Record.cleanup.topologyMutated) {
        throw 'Reservations and Inventory evidence has an invalid cleanup disposition.'
    }
}

function Assert-BunkFyIngestionConnectionLifecycleAdmissionEvidence {
    param([Parameter(Mandatory = $true)][object] $Record)

    Assert-BunkFyCandidateProperties `
        -Value $Record.workflow `
        -ExpectedProperties @(
            'executionMode',
            'protocolVersion',
            'configurationSchemaVersion',
            'connectionFinalStatus',
            'connectionVersionAdvanced',
            'secretReferenceLifecycle',
            'credentialFinalStatus',
            'credentialVersionAdvanced',
            'credentialIssuance',
            'independentAuthentication',
            'runFinalStatus',
            'runObservedCount',
            'activeLease') `
        -Context 'Ingestion connection lifecycle workflow'
    if ([string]$Record.workflow.executionMode -cne 'remote-polling' -or
        [int]$Record.workflow.protocolVersion -le 0 -or
        [int]$Record.workflow.configurationSchemaVersion -le 0 -or
        [string]$Record.workflow.connectionFinalStatus -cne 'disabled' -or
        $Record.workflow.connectionVersionAdvanced -isnot [bool] -or
        -not [bool]$Record.workflow.connectionVersionAdvanced -or
        [string]$Record.workflow.secretReferenceLifecycle -cne
            'set-then-cleared' -or
        [string]$Record.workflow.credentialFinalStatus -cne 'revoked' -or
        $Record.workflow.credentialVersionAdvanced -isnot [bool] -or
        -not [bool]$Record.workflow.credentialVersionAdvanced -or
        [string]$Record.workflow.credentialIssuance -cne
            'one-time-nonredisclosing' -or
        [string]$Record.workflow.independentAuthentication -cne
            'issued-accepted-then-revoked-denied' -or
        [string]$Record.workflow.runFinalStatus -cne 'succeeded' -or
        [int]$Record.workflow.runObservedCount -ne 0 -or
        $Record.workflow.activeLease -isnot [bool] -or
        [bool]$Record.workflow.activeLease) {
        throw 'Ingestion connection lifecycle evidence has an invalid workflow summary.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.cleanup `
        -ExpectedProperties @(
            'connectionDisposition',
            'credentialDisposition',
            'runDisposition',
            'parentPropertyLifecycleOwnedByCaller') `
        -Context 'Ingestion connection lifecycle cleanup'
    if ([string]$Record.cleanup.connectionDisposition -cne
            'synthetic-disabled-retained' -or
        [string]$Record.cleanup.credentialDisposition -cne
            'synthetic-revoked-retained' -or
        [string]$Record.cleanup.runDisposition -cne
            'synthetic-succeeded-empty-retained' -or
        $Record.cleanup.parentPropertyLifecycleOwnedByCaller -isnot [bool] -or
        -not [bool]$Record.cleanup.parentPropertyLifecycleOwnedByCaller) {
        throw 'Ingestion connection lifecycle evidence has an invalid cleanup disposition.'
    }
}

function Assert-BunkFyIngestionConflictProposalLifecycleAdmissionEvidence {
    param([Parameter(Mandatory = $true)][object] $Record)

    Assert-BunkFyCandidateProperties `
        -Value $Record.adapterContract `
        -ExpectedProperties @(
            'executionMode',
            'protocolVersion',
            'configurationSchemaVersion') `
        -Context 'Ingestion conflict proposal adapter contract'
    if ([string]$Record.adapterContract.executionMode -cne 'push' -or
        [int]$Record.adapterContract.protocolVersion -le 0 -or
        [int]$Record.adapterContract.configurationSchemaVersion -le 0) {
        throw 'Ingestion conflict proposal evidence has an invalid adapter contract.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.authorityRevisions `
        -ExpectedProperties @(
            'initialAdapter',
            'automaticAdapter',
            'staff',
            'acceptedAdapter') `
        -Context 'Ingestion conflict proposal authority revisions'
    if ([long]$Record.authorityRevisions.initialAdapter -ne 1 -or
        [long]$Record.authorityRevisions.automaticAdapter -ne 2 -or
        [long]$Record.authorityRevisions.staff -ne 3 -or
        [long]$Record.authorityRevisions.acceptedAdapter -ne 4) {
        throw 'Ingestion conflict proposal evidence has invalid authority revisions.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.proposalSummary `
        -ExpectedProperties @('total', 'superseded', 'rejected', 'applied', 'pending') `
        -Context 'Ingestion conflict proposal terminal summary'
    if ([int]$Record.proposalSummary.total -ne 3 -or
        [int]$Record.proposalSummary.superseded -ne 1 -or
        [int]$Record.proposalSummary.rejected -ne 1 -or
        [int]$Record.proposalSummary.applied -ne 1 -or
        [int]$Record.proposalSummary.pending -ne 0) {
        throw 'Ingestion conflict proposal evidence has an invalid terminal proposal summary.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.cleanup `
        -ExpectedProperties @(
            'reservation',
            'credential',
            'connection',
            'credentialVersion',
            'connectionVersion') `
        -Context 'Ingestion conflict proposal cleanup'
    if ([string]$Record.cleanup.reservation -cne 'cancelled' -or
        [string]$Record.cleanup.credential -cne 'revoked' -or
        [string]$Record.cleanup.connection -cne 'disabled' -or
        [long]$Record.cleanup.credentialVersion -lt 2 -or
        [long]$Record.cleanup.connectionVersion -lt 2) {
        throw 'Ingestion conflict proposal evidence has an invalid cleanup disposition.'
    }
}

function Assert-BunkFyDataRightsAccessExportAdmissionEvidence {
    param([Parameter(Mandatory = $true)][object] $Record)

    Assert-BunkFyCandidateProperties `
        -Value $Record.workflow `
        -ExpectedProperties @(
            'caseType',
            'requestedOperation',
            'requesterRelationship',
            'finalStatus',
            'selectedSubjectCount') `
        -Context 'Data Rights access export workflow'
    if ([string]$Record.workflow.caseType -cne 'guest-rights' -or
        [string]$Record.workflow.requestedOperation -cne 'access-export' -or
        [string]$Record.workflow.requesterRelationship -cne 'controller-initiated' -or
        [string]$Record.workflow.finalStatus -cne 'completed' -or
        [int]$Record.workflow.selectedSubjectCount -ne 1) {
        throw 'Data Rights access export evidence has an invalid workflow summary.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.artifact `
        -ExpectedProperties @(
            'finalStatus',
            'formatVersion',
            'subjectCount',
            'recordCount',
            'byteCount',
            'expiryHours') `
        -Context 'Data Rights access export artifact'
    $expiryHours = [double]$Record.artifact.expiryHours
    if ([string]$Record.artifact.finalStatus -cne 'available' -or
        [int]$Record.artifact.formatVersion -ne 1 -or
        [int]$Record.artifact.subjectCount -ne 1 -or
        [int]$Record.artifact.recordCount -lt 1 -or
        [int]$Record.artifact.recordCount -gt 50000 -or
        [long]$Record.artifact.byteCount -lt 1 -or
        [long]$Record.artifact.byteCount -gt 1MB -or
        [double]::IsNaN($expiryHours) -or
        [double]::IsInfinity($expiryHours) -or
        $expiryHours -lt (5.0 / 60.0) -or
        $expiryHours -gt 168.0) {
        throw 'Data Rights access export evidence has an invalid artifact summary.'
    }

    Assert-BunkFyCandidateProperties `
        -Value $Record.cleanup `
        -ExpectedProperties @('guestArchived', 'artifactDisposition') `
        -Context 'Data Rights access export cleanup'
    if ($Record.cleanup.guestArchived -isnot [bool] -or
        -not [bool]$Record.cleanup.guestArchived -or
        [string]$Record.cleanup.artifactDisposition -cne 'scheduled-expiry') {
        throw 'Data Rights access export evidence has an invalid cleanup disposition.'
    }
}

function Get-BunkFyVerifiedProductionAdmissionProbe {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $SpecificationName,
        [Parameter(Mandatory = $true)][Uri] $ExpectedOrigin,
        [Parameter(Mandatory = $true)][string] $ExpectedReleaseId,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^admission:[0-9a-f]{32}$')]
        [string] $ExpectedAdmissionEvidenceReference,
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
    if ([string]$record.admissionEvidenceReference -cne
        $ExpectedAdmissionEvidenceReference) {
        throw "$SpecificationName deployment evidence comes from a different admission attempt."
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

    if ($SpecificationName -ceq 'retention') {
        Assert-BunkFyRetentionAdmissionEvidence `
            -Record $record `
            -GeneratedAt $generatedAt
    }
    elseif ($SpecificationName -ceq 'operations-notifications') {
        Assert-BunkFyOperationsNotificationsAdmissionEvidence -Record $record
    }
    elseif ($SpecificationName -ceq 'reservations-inventory') {
        Assert-BunkFyReservationsInventoryAdmissionEvidence -Record $record
    }
    elseif ($SpecificationName -ceq 'guests-stay-history') {
        Assert-BunkFyGuestsStayHistoryAdmissionEvidence -Record $record
    }
    elseif ($SpecificationName -ceq 'staff-employment') {
        Assert-BunkFyStaffEmploymentAdmissionEvidence -Record $record
    }
    elseif ($SpecificationName -ceq 'properties-topology') {
        Assert-BunkFyPropertiesTopologyAdmissionEvidence -Record $record
    }
    elseif ($SpecificationName -ceq 'ingestion-connection-lifecycle') {
        Assert-BunkFyIngestionConnectionLifecycleAdmissionEvidence -Record $record
    }
    elseif ($SpecificationName -ceq 'ingestion-conflict-proposal-lifecycle') {
        Assert-BunkFyIngestionConflictProposalLifecycleAdmissionEvidence -Record $record
    }
    elseif ($SpecificationName -ceq 'data-rights-access-export') {
        Assert-BunkFyDataRightsAccessExportAdmissionEvidence -Record $record
    }

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
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^admission:[0-9a-f]{32}$')]
        [string] $ExpectedAdmissionEvidenceReference,
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
        -ExpectedProperties @('schemaVersion', 'evidenceKind', 'rehearsalId', 'rollbackEvidenceReference', 'admissionEvidenceReference', 'generatedAtUtc', 'result', 'origin', 'candidate', 'rollback', 'timing', 'checks', 'limitations') `
        -Context 'deployed rollback rehearsal record'
    if ($record.schemaVersion -ne 2 -or
        $record.evidenceKind -cne 'bunkfy-deployed-release-rollback-rehearsal' -or
        $record.result -cne 'passed' -or
        $record.origin -cne $ExpectedOrigin.GetLeftPart([UriPartial]::Authority)) {
        throw 'Deployed rollback rehearsal does not match the candidate origin.'
    }
    if ([string]$record.admissionEvidenceReference -cne
        $ExpectedAdmissionEvidenceReference) {
        throw 'Deployed rollback rehearsal comes from a different admission attempt.'
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
            -ExpectedAdmissionEvidenceReference $ExpectedAdmissionEvidenceReference `
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
        'deployed-data-rights-access-export' = [pscustomobject]@{ Kind = 'bunkfy-deployed-data-rights-access-export-probe'; ReleaseId = $CandidateReleaseId; Count = 18 }
        'deployed-guests-stay-history' = [pscustomobject]@{ Kind = 'bunkfy-deployed-guests-stay-history-probe'; ReleaseId = $CandidateReleaseId; Count = 19 }
        'deployed-staff-employment' = [pscustomobject]@{ Kind = 'bunkfy-deployed-staff-employment-probe'; ReleaseId = $CandidateReleaseId; Count = 21 }
        'deployed-properties-topology' = [pscustomobject]@{ Kind = 'bunkfy-deployed-properties-topology-probe'; ReleaseId = $CandidateReleaseId; Count = 31 }
        'deployed-ingestion-connection-lifecycle' = [pscustomobject]@{ Kind = 'bunkfy-deployed-ingestion-connection-lifecycle-probe'; ReleaseId = $CandidateReleaseId; Count = 32 }
        'deployed-ingestion-conflict-proposal-lifecycle' = [pscustomobject]@{ Kind = 'bunkfy-deployed-ingestion-conflict-proposal-lifecycle-probe'; ReleaseId = $CandidateReleaseId; Count = 26 }
        'deployed-operations-notifications' = [pscustomobject]@{ Kind = 'bunkfy-deployed-operations-notifications-probe'; ReleaseId = $CandidateReleaseId; Count = 10 }
        'deployed-public-edge' = [pscustomobject]@{ Kind = 'bunkfy-deployed-public-edge-probe'; ReleaseId = $CandidateReleaseId; Count = 6 }
        'deployed-reservations-inventory' = [pscustomobject]@{ Kind = 'bunkfy-deployed-reservations-inventory-probe'; ReleaseId = $CandidateReleaseId; Count = 12 }
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
