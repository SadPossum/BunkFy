[CmdletBinding()]
param([string] $RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$root = [IO.Path]::GetFullPath($RepositoryRoot)
. (Join-Path $root 'eng/production-admission.common.ps1')
$assembler = Join-Path $root 'eng/operations/assemble-production-admission.ps1'
$verifier = Join-Path $root 'eng/verify-production-admission.ps1'

function New-TestPromotionEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][string] $ReleaseId,
        [Parameter(Mandatory = $true)][string] $SourceCommit,
        [Parameter(Mandatory = $true)][ValidatePattern('^[1-8]$')][string] $DigestSeed
    )

    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $seed = [int]::Parse($DigestSeed, [Globalization.CultureInfo]::InvariantCulture)
    $promotionId = [Guid]::NewGuid()
    $archiveHash = ([string]$seed) * 64
    $backendDigest = 'sha256:' + ([string]($seed + 1)) * 64
    $webDigest = 'sha256:' + ([string]($seed + 2)) * 64
    $record = [ordered]@{
        schemaVersion = 1
        evidenceKind = 'bunkfy-image-promotion'
        promotionId = $promotionId.ToString('D')
        promotionEvidenceReference = "promotion:$($promotionId.ToString('N'))"
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        result = 'passed'
        repository = 'SadPossum/BunkFy'
        releaseId = $ReleaseId
        sourceCommit = $SourceCommit
        platform = 'linux/amd64'
        candidate = [ordered]@{
            bundleChecksumsSha256 = $archiveHash
            attestationsVerified = $false
        }
        images = @(
            [ordered]@{
                name = 'backend'
                sourceArchiveSha256 = $archiveHash
                sourceManifestDigest = $backendDigest
                tagReference = "registry.fixture.invalid/bunkfy/backend:$ReleaseId"
                digestReference = "registry.fixture.invalid/bunkfy/backend@$backendDigest"
                outcome = 'published'
            },
            [ordered]@{
                name = 'web'
                sourceArchiveSha256 = ([string]($seed + 3)) * 64
                sourceManifestDigest = $webDigest
                tagReference = "registry.fixture.invalid/bunkfy/web:$ReleaseId"
                digestReference = "registry.fixture.invalid/bunkfy/web@$webDigest"
                outcome = 'published'
            })
        limitations = @(
            'registry-tag-immutability-policy-not-observed',
            'deployment-not-observed',
            'rollback-not-executed')
    }
    $recordPath = Join-Path $Directory 'promotion.json'
    Write-BunkFyCandidateJson -Path $recordPath -Value $record
    $hash = (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $Directory 'checksums.sha256'),
        "$hash  promotion.json`n",
        [Text.UTF8Encoding]::new($false))
}

function New-TestProbeEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $SpecificationName,
        [Parameter(Mandatory = $true)][Uri] $Origin,
        [Parameter(Mandatory = $true)][string] $ReleaseId,
        [Guid] $EvidenceSetId = [Guid]::Empty
    )

    $spec = Get-BunkFyProductionAdmissionProbeSpecification -Name $SpecificationName
    $record = [ordered]@{
        schemaVersion = $spec.SchemaVersion
        evidenceKind = $spec.EvidenceKind
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
    switch ($SpecificationName) {
        'public-edge' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
        }
        { $_ -in @('admin-allowed', 'admin-denied') } {
            if ($EvidenceSetId -eq [Guid]::Empty) {
                throw 'Admin fixtures require EvidenceSetId.'
            }
            $record['evidenceSetId'] = $EvidenceSetId.ToString('D')
            $record['releaseId'] = $ReleaseId
            $record['expectedAdminReachability'] = $SpecificationName.Substring(6)
            $record['publicOrigin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['adminOrigin'] = 'http://127.0.0.1:5195'
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            $record['adminObservation'] = [ordered]@{ class = 'fixture' }
        }
        'workspace-invitation' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            foreach ($name in @('workspaceId', 'allowedPropertyId', 'deniedPropertyId', 'sourceId', 'applicationId', 'membershipId', 'staffMemberId')) {
                $record[$name] = [Guid]::NewGuid().ToString('D')
            }
        }
        'workspace-enrollment' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            foreach ($name in @('workspaceId', 'allowedPropertyId', 'deniedPropertyId')) {
                $record[$name] = [Guid]::NewGuid().ToString('D')
            }
            $record['rejected'] = [ordered]@{ sourceId = [Guid]::NewGuid().ToString('D') }
            $record['approved'] = [ordered]@{ sourceId = [Guid]::NewGuid().ToString('D') }
        }
        'operations-notifications' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            foreach ($name in @('workspaceId', 'propertyId', 'inventoryUnitId', 'blockGroupId')) {
                $record[$name] = [Guid]::NewGuid().ToString('D')
            }
            $record['arrival'] = '2027-02-11'
            $record['departure'] = '2027-02-13'
            $record['createdNotification'] = [ordered]@{ id = [Guid]::NewGuid().ToString('D'); streamSequence = 41 }
            $record['releasedNotification'] = [ordered]@{ id = [Guid]::NewGuid().ToString('D'); streamSequence = 42 }
        }
        'reservations-inventory' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
        }
        'guests-stay-history' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            $record['workflow'] = [ordered]@{
                guestFinalStatus = 'archived'
                reservationFinalStatus = 'checked-out'
                participantRole = 'primary'
                stayFinalStatus = 'checked-out'
                stayCount = 1
                guestVersionAdvanced = $true
                reservationVersionsMonotonic = $true
            }
            $record['cleanup'] = [ordered]@{
                guestArchived = $true
                reservationDisposition = 'synthetic-checked-out-retained'
                inventoryReleased = $true
                roomDisposition = 'parent-rehearsal-owned'
            }
        }
        'staff-employment' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            $record['workflow'] = [ordered]@{
                finalStatus = 'departed'
                authSubjectLinked = $false
                profileVersionAdvanced = $true
                assignmentLifecycle = 'assigned-then-closed'
                currentAssignmentCount = 0
                historicalAssignmentCount = 1
                suspensionRetainedAssignment = $true
            }
            $record['cleanup'] = [ordered]@{
                staffDisposition = 'synthetic-departed-retained'
                currentAssignmentsClosed = $true
                propertyDisposition = 'parent-rehearsal-owned'
            }
        }
        'properties-topology' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            $record['workflow'] = [ordered]@{
                propertyFinalStatus = 'retired'
                propertyVersionAdvanced = $true
                processingFinalStatus = 'suspended-by-retirement'
                roomFinalStatus = 'retired'
                roomVersionAdvanced = $true
                bedCount = 2
                retiredBedCount = 2
                bedVersionsAdvanced = $true
                retirementLifecycle = 'bed-then-room-completed'
                directRetirementDenied = $true
            }
            $record['cleanup'] = [ordered]@{
                propertyDisposition = 'synthetic-retired-retained'
                roomDisposition = 'synthetic-retired-retained'
                activeBedCount = 0
                topologyRetirementsCompleted = $true
                parentCleanupRequired = $false
            }
        }
        'data-rights-access-export' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            $record['workflow'] = [ordered]@{
                caseType = 'guest-rights'
                requestedOperation = 'access-export'
                requesterRelationship = 'controller-initiated'
                finalStatus = 'completed'
                selectedSubjectCount = 1
            }
            $record['artifact'] = [ordered]@{
                finalStatus = 'available'
                formatVersion = 1
                subjectCount = 1
                recordCount = 2
                byteCount = 2048
                expiryHours = 24
            }
            $record['cleanup'] = [ordered]@{
                guestArchived = $true
                artifactDisposition = 'scheduled-expiry'
            }
        }
        'adapter-host' {
            $record['publicOrigin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['adapterHostOrigin'] = 'http://127.0.0.1:8091'
            $record['publicTransport'] = 'loopback-http-fixture'
            $record['adapterHostTransport'] = 'loopback-http'
            $record['result'] = 'passed'
            foreach ($name in @('workspaceId', 'propertyId', 'connectionId', 'workerId')) {
                $record[$name] = [Guid]::NewGuid().ToString('D')
            }
            $record['adapterType'] = 'fixture'
            $record['statusEndpointExposure'] = 'LoopbackOnly'
            $record['run'] = [ordered]@{ runId = [Guid]::NewGuid().ToString('D') }
            $record['receipt'] = [ordered]@{ receiptId = [Guid]::NewGuid().ToString('D') }
        }
        'retention' {
            $generatedAt = [DateTimeOffset]::Parse(
                [string]$record.generatedAtUtc,
                [Globalization.CultureInfo]::InvariantCulture)
            $baselineRunId = [Guid]::NewGuid()
            $rawRunId = [Guid]::NewGuid()
            $record['publicOrigin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            $record['workspaceId'] = [Guid]::NewGuid().ToString('D')
            $record['observedDataClassKey'] = 'raw-source-evidence'
            $record['catalogueCount'] = 2
            $record['observation'] = [ordered]@{
                mode = 'next-occurrence-after-baseline'
                baselineCapturedAtUtc = $generatedAt.AddMinutes(-1).ToString('O')
                completionNotBeforeUtc = $null
                baselineObservedRunId = $baselineRunId.ToString('D')
                baselineObservedRunning = $false
                clockSkewSeconds = 120
            }
            $record['schedules'] = @(
                [ordered]@{
                    ownerKey = 'ingestion'
                    dataClassKey = 'raw-source-evidence'
                    executionPolicyVersion = 1
                    lastRunId = $rawRunId.ToString('D')
                    lastStartedAtUtc = $generatedAt.AddSeconds(-32).ToString('O')
                    lastCompletedAtUtc = $generatedAt.AddSeconds(-31).ToString('O')
                    nextDueAtUtc = $generatedAt.AddMinutes(59).ToString('O')
                    scannedCount = 1
                    affectedCount = 1
                    remainingCount = 0
                    outcomeCode = 'ingestion.raw-payload.completed'
                },
                [ordered]@{
                    ownerKey = 'ingestion'
                    dataClassKey = 'sensitive-reservation-history'
                    executionPolicyVersion = 1
                    lastRunId = [Guid]::NewGuid().ToString('D')
                    lastStartedAtUtc = $generatedAt.AddMinutes(-3).ToString('O')
                    lastCompletedAtUtc = $generatedAt.AddMinutes(-2).ToString('O')
                    nextDueAtUtc = $generatedAt.AddHours(4).ToString('O')
                    scannedCount = 0
                    affectedCount = 0
                    remainingCount = 0
                    outcomeCode = 'ingestion.sensitive-history.completed'
                })
        }
    }
    $record['checks'] = @($spec.Checks | ForEach-Object {
            [ordered]@{ name = $_; status = 'passed' }
        })
    $record['limitations'] = $spec.Limitations
    Write-BunkFyCandidateJson -Path $Path -Value $record
}

function New-TestRollbackEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][Uri] $Origin,
        [Parameter(Mandatory = $true)][object] $CandidatePromotion,
        [Parameter(Mandatory = $true)][object] $RollbackPromotion
    )

    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $edgeSpecs = [ordered]@{
        'candidate-baseline-public-edge' = [pscustomobject]@{ File = 'candidate-baseline-public-edge.json'; ReleaseId = $CandidatePromotion.ReleaseId }
        'rollback-public-edge' = [pscustomobject]@{ File = 'rollback-public-edge.json'; ReleaseId = $RollbackPromotion.ReleaseId }
        'candidate-restored-public-edge' = [pscustomobject]@{ File = 'candidate-restored-public-edge.json'; ReleaseId = $CandidatePromotion.ReleaseId }
    }
    foreach ($entry in $edgeSpecs.GetEnumerator()) {
        New-TestProbeEvidence `
            -Path (Join-Path $Directory $entry.Value.File) `
            -SpecificationName 'public-edge' `
            -Origin $Origin `
            -ReleaseId $entry.Value.ReleaseId
    }
    $rehearsalId = [Guid]::NewGuid()
    $completed = [DateTimeOffset]::UtcNow.ToString('O')
    $record = [ordered]@{
        schemaVersion = 1
        evidenceKind = 'bunkfy-deployed-release-rollback-rehearsal'
        rehearsalId = $rehearsalId.ToString('D')
        rollbackEvidenceReference = "rollback:$($rehearsalId.ToString('N'))"
        generatedAtUtc = $completed
        result = 'passed'
        origin = $Origin.GetLeftPart([UriPartial]::Authority)
        candidate = ConvertTo-BunkFyProductionAdmissionPromotionSummary $CandidatePromotion
        rollback = ConvertTo-BunkFyProductionAdmissionPromotionSummary $RollbackPromotion
        timing = [ordered]@{
            startedAtUtc = $completed
            baselineVerifiedAtUtc = $completed
            rollbackObservedAtUtc = $completed
            rollbackVerifiedAtUtc = $completed
            candidateRestoredObservedAtUtc = $completed
            completedAtUtc = $completed
            rollbackConvergenceMilliseconds = 0
            restorationConvergenceMilliseconds = 0
            totalDurationMilliseconds = 0
        }
        checks = @($edgeSpecs.GetEnumerator() | ForEach-Object {
                $path = Join-Path $Directory $_.Value.File
                [ordered]@{
                    name = $_.Key
                    result = 'passed'
                    releaseId = $_.Value.ReleaseId
                    evidenceFile = $_.Value.File
                    evidenceSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            })
        limitations = @(
            'deployment-control-plane-and-commands-not-observed',
            'worker-and-admin-release-identities-not-observed',
            'public-smoke-does-not-prove-all-schema-and-domain-compatibility',
            'registry-availability-and-immutability-not-reverified',
            'hosted-approval-alerting-and-traffic-drain-not-observed')
    }
    Write-BunkFyCandidateJson -Path (Join-Path $Directory 'rollback-rehearsal.json') -Value $record
    $lines = @(Get-ChildItem -LiteralPath $Directory -File | Sort-Object Name | ForEach-Object {
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$hash  $($_.Name)"
        })
    [IO.File]::WriteAllText(
        (Join-Path $Directory 'checksums.sha256'),
        (($lines -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false))
}

function New-TestMigrationEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $SourceCommit,
        [Parameter(Mandatory = $true)][string] $BackendDigest
    )

    $record = [ordered]@{
        schemaVersion = 1
        evidenceKind = 'bunkfy-production-migration-rehearsal'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        runId = 'abcdef123456'
        sourceCommitSha = $SourceCommit
        images = [ordered]@{
            backend = [ordered]@{ reference = 'fixture/backend'; imageId = 'sha256:' + ('9' * 64); repositoryDigest = $BackendDigest }
            postgresql = [ordered]@{ reference = 'postgres:17.5-alpine'; imageId = 'sha256:' + ('a' * 64); repositoryDigest = 'sha256:' + ('b' * 64) }
        }
        isolation = [ordered]@{ internalNetwork = $true; publishedPorts = 0; persistentVolumes = 0; resourcesRemoved = $true }
        plan = [ordered]@{
            databaseTargetSha256 = 'c' * 64
            targetCatalogVersion = 1
            targetCatalogSha256 = 'd' * 64
            currentStateSha256 = 'e' * 64
            pendingPlanSha256 = 'f' * 64
            moduleCount = 8
            targetMigrationCount = 12
            appliedMigrationCount = 0
            pendingMigrationCount = 12
            schemaFingerprintBefore = '1' * 64
            noMutation = $true
        }
        admission = [ordered]@{ malformedSourceRejected = $true; malformedBackupReferenceRejected = $true; wrongDatabaseTargetRejected = $true }
        apply = [ordered]@{ appliedMigrationCount = 12; pendingMigrationCount = 0; resultingStateSha256 = '2' * 64; schemaFingerprintAfter = '3' * 64; idempotentRerun = $true }
    }
    Write-BunkFyCandidateJson -Path $Path -Value $record
}

function Assert-TestFailure {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Operation,
        [Parameter(Mandatory = $true)][string] $ExpectedMessage,
        [Parameter(Mandatory = $true)][string] $Context
    )

    try {
        & $Operation | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains($ExpectedMessage, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unexpected $Context rejection: $($_.Exception.Message)"
        }
        return
    }
    throw "$Context did not reject '$ExpectedMessage'."
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "bunkfy-production-admission-$([Guid]::NewGuid().ToString('N'))")
try {
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $origin = [Uri]'http://127.0.0.1:8080/'
    $candidateRelease = 'release-candidate-001'
    $rollbackRelease = 'release-rollback-001'
    $candidateSource = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $rollbackSource = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $admissionReference = "admission:$([Guid]::NewGuid().ToString('N'))"
    $candidatePromotionPath = Join-Path $temporaryRoot 'candidate-promotion'
    $rollbackPromotionPath = Join-Path $temporaryRoot 'rollback-promotion'
    New-TestPromotionEvidence -Directory $candidatePromotionPath -ReleaseId $candidateRelease -SourceCommit $candidateSource -DigestSeed '1'
    New-TestPromotionEvidence -Directory $rollbackPromotionPath -ReleaseId $rollbackRelease -SourceCommit $rollbackSource -DigestSeed '5'
    $candidatePromotion = Get-BunkFyVerifiedImagePromotion -PromotionDirectory $candidatePromotionPath -ExpectedReleaseId $candidateRelease -ExpectedSourceCommit $candidateSource -AllowFixtureEvidence
    $rollbackPromotion = Get-BunkFyVerifiedImagePromotion -PromotionDirectory $rollbackPromotionPath -ExpectedReleaseId $rollbackRelease -ExpectedSourceCommit $rollbackSource -AllowFixtureEvidence

    $rollbackRehearsalPath = Join-Path $temporaryRoot 'rollback-rehearsal'
    New-TestRollbackEvidence -Directory $rollbackRehearsalPath -Origin $origin -CandidatePromotion $candidatePromotion -RollbackPromotion $rollbackPromotion
    $migrationPath = Join-Path $temporaryRoot 'migration.json'
    $backend = @($candidatePromotion.Images | Where-Object Name -CEQ 'backend')[0]
    New-TestMigrationEvidence -Path $migrationPath -SourceCommit $candidateSource -BackendDigest $backend.ManifestDigest

    $adminSetId = [Guid]::NewGuid()
    $probePaths = [ordered]@{
        PublicEdge = Join-Path $temporaryRoot 'public-edge.json'
        AdminAllowed = Join-Path $temporaryRoot 'admin-allowed.json'
        AdminDenied = Join-Path $temporaryRoot 'admin-denied.json'
        Invitation = Join-Path $temporaryRoot 'invitation.json'
        Enrollment = Join-Path $temporaryRoot 'enrollment.json'
        Notifications = Join-Path $temporaryRoot 'notifications.json'
        ReservationsInventory = Join-Path $temporaryRoot 'reservations-inventory.json'
        GuestsStayHistory = Join-Path $temporaryRoot 'guests-stay-history.json'
        StaffEmployment = Join-Path $temporaryRoot 'staff-employment.json'
        PropertiesTopology = Join-Path $temporaryRoot 'properties-topology.json'
        DataRightsAccessExport = Join-Path $temporaryRoot 'data-rights-access-export.json'
        AdapterHost = Join-Path $temporaryRoot 'adapter-host.json'
        Retention = Join-Path $temporaryRoot 'retention.json'
    }
    New-TestProbeEvidence -Path $probePaths.PublicEdge -SpecificationName public-edge -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.AdminAllowed -SpecificationName admin-allowed -Origin $origin -ReleaseId $candidateRelease -EvidenceSetId $adminSetId
    New-TestProbeEvidence -Path $probePaths.AdminDenied -SpecificationName admin-denied -Origin $origin -ReleaseId $candidateRelease -EvidenceSetId $adminSetId
    New-TestProbeEvidence -Path $probePaths.Invitation -SpecificationName workspace-invitation -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.Enrollment -SpecificationName workspace-enrollment -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.Notifications -SpecificationName operations-notifications -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.ReservationsInventory -SpecificationName reservations-inventory -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.GuestsStayHistory -SpecificationName guests-stay-history -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.StaffEmployment -SpecificationName staff-employment -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.PropertiesTopology -SpecificationName properties-topology -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.DataRightsAccessExport -SpecificationName data-rights-access-export -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.AdapterHost -SpecificationName adapter-host -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.Retention -SpecificationName retention -Origin $origin -ReleaseId $candidateRelease

    $output = Join-Path $temporaryRoot 'admission'
    $arguments = @{
        PublicOrigin = $origin
        CandidatePromotionDirectory = $candidatePromotionPath
        CandidateReleaseId = $candidateRelease
        CandidateSourceCommit = $candidateSource
        AdmissionEvidenceReference = $admissionReference
        RollbackPromotionDirectory = $rollbackPromotionPath
        RollbackReleaseId = $rollbackRelease
        RollbackSourceCommit = $rollbackSource
        RollbackRehearsalDirectory = $rollbackRehearsalPath
        MigrationRehearsalPath = $migrationPath
        PublicEdgeEvidencePath = $probePaths.PublicEdge
        AdminAllowedEvidencePath = $probePaths.AdminAllowed
        AdminDeniedEvidencePath = $probePaths.AdminDenied
        WorkspaceInvitationEvidencePath = $probePaths.Invitation
        WorkspaceEnrollmentEvidencePath = $probePaths.Enrollment
        OperationsNotificationsEvidencePath = $probePaths.Notifications
        ReservationsInventoryEvidencePath = $probePaths.ReservationsInventory
        GuestsStayHistoryEvidencePath = $probePaths.GuestsStayHistory
        StaffEmploymentEvidencePath = $probePaths.StaffEmployment
        PropertiesTopologyEvidencePath = $probePaths.PropertiesTopology
        DataRightsAccessExportEvidencePath = $probePaths.DataRightsAccessExport
        AdapterHostEvidencePath = $probePaths.AdapterHost
        RetentionEvidencePath = $probePaths.Retention
        BrowserRehearsalReference = 'record:BROWSER-123'
        HostedRecoveryReference = 'record:RECOVERY-123'
        DeploymentControlReference = 'record:DEPLOY-123'
        RuntimeOperationsReference = 'record:RUNTIME-123'
        WorkspaceAccessEstateReference = 'record:ACCESS-123'
        OutputDirectory = $output
        AllowFixtureEvidence = $true
        PassThru = $true
    }
    $assembled = & $assembler @arguments
    $verificationArguments = @{
        AdmissionDirectory = $output
        ExpectedPublicOrigin = $origin
        ExpectedReleaseId = $candidateRelease
        ExpectedSourceCommit = $candidateSource
        ExpectedAdmissionEvidenceReference = $admissionReference
        AllowFixtureEvidence = $true
        PassThru = $true
    }
    $verified = & $verifier @verificationArguments
    $closed = Get-BunkFyClosedChecksumSet -Directory $output -MaximumPayloadBytes 2MB -Context 'production admission fixture'
    if ($closed.Files.Count -ne 1 -or
        $assembled.AdmissionEvidenceReference -cne $verified.AdmissionEvidenceReference -or
        $verified.AdmissionEvidenceReference -cne $admissionReference -or
        $verified.ReleaseId -cne $candidateRelease -or
        @($verified.Record.evidence).Count -ne 17 -or
        @($verified.Record.privateEvidence).Count -ne 5 -or
        @($verified.Record.checks).Count -ne 7) {
        throw 'Production admission fixture emitted invalid closed evidence.'
    }

    $hostedFixtureArguments = $arguments.Clone()
    $hostedFixtureArguments.PublicOrigin = [Uri]'https://candidate.example/'
    $hostedFixtureArguments.OutputDirectory =
        Join-Path $temporaryRoot 'hosted-fixture-promotion-admission'
    $hostedFixtureArguments.Remove('AllowFixtureEvidence')
    Assert-TestFailure `
        -Operation { & $assembler @hostedFixtureArguments } `
        -ExpectedMessage 'fixture or loopback registry' `
        -Context 'hosted admission with fixture promotion evidence'
    if ([IO.Directory]::Exists(
            [string]$hostedFixtureArguments.OutputDirectory)) {
        throw 'Rejected hosted fixture promotion left an admission bundle.'
    }

    $serialized = [IO.File]::ReadAllText((Join-Path $output 'production-admission.json'))
    foreach ($forbidden in @('workspaceId', 'propertyId', 'inventoryUnitId', 'guestId', 'caseId', 'artifactId', 'token', 'password', 'responseBody', 'rawHeaders')) {
        if ($serialized.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Production admission bundle retained forbidden source detail '$forbidden'."
        }
    }

    $tampered = Join-Path $temporaryRoot 'tampered-admission'
    Copy-Item -LiteralPath $output -Destination $tampered -Recurse
    [IO.File]::AppendAllText((Join-Path $tampered 'production-admission.json'), " ")
    $tamperedVerificationArguments = $verificationArguments.Clone()
    $tamperedVerificationArguments.AdmissionDirectory = $tampered
    Assert-TestFailure `
        -Operation { & $verifier @tamperedVerificationArguments } `
        -ExpectedMessage 'does not match checksums' `
        -Context 'tampered admission bundle'

    $wrongReleaseNotifications = Join-Path $temporaryRoot 'wrong-release-notifications.json'
    New-TestProbeEvidence -Path $wrongReleaseNotifications -SpecificationName operations-notifications -Origin $origin -ReleaseId $rollbackRelease
    $mismatchArguments = $arguments.Clone()
    $mismatchArguments.OperationsNotificationsEvidencePath = $wrongReleaseNotifications
    $mismatchArguments.OutputDirectory = Join-Path $temporaryRoot 'mismatch-admission'
    Assert-TestFailure `
        -Operation { & $assembler @mismatchArguments } `
        -ExpectedMessage 'does not match the candidate release' `
        -Context 'cross-release source evidence'
    if ([IO.Directory]::Exists([string]$mismatchArguments.OutputDirectory)) {
        throw 'Rejected cross-release evidence left an admission bundle.'
    }

    $invalidDataRightsPath = Join-Path $temporaryRoot 'invalid-data-rights-cleanup.json'
    $invalidDataRights = Get-Content -LiteralPath $probePaths.DataRightsAccessExport -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $invalidDataRights.cleanup.artifactDisposition = 'deleted-immediately'
    Write-BunkFyCandidateJson -Path $invalidDataRightsPath -Value $invalidDataRights
    Assert-TestFailure `
        -Operation {
            Get-BunkFyVerifiedProductionAdmissionProbe `
                -Path $invalidDataRightsPath `
                -SpecificationName data-rights-access-export `
                -ExpectedOrigin $origin `
                -ExpectedReleaseId $candidateRelease `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'invalid cleanup disposition' `
        -Context 'false immediate Data Rights artifact deletion claim'

    $invalidGuestsPath = Join-Path $temporaryRoot 'invalid-guests-cleanup.json'
    $invalidGuests = Get-Content -LiteralPath $probePaths.GuestsStayHistory -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $invalidGuests.cleanup.inventoryReleased = $false
    Write-BunkFyCandidateJson -Path $invalidGuestsPath -Value $invalidGuests
    Assert-TestFailure `
        -Operation {
            Get-BunkFyVerifiedProductionAdmissionProbe `
                -Path $invalidGuestsPath `
                -SpecificationName guests-stay-history `
                -ExpectedOrigin $origin `
                -ExpectedReleaseId $candidateRelease `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'invalid cleanup disposition' `
        -Context 'false Guests Inventory release claim'

    $invalidStaffPath = Join-Path $temporaryRoot 'invalid-staff-cleanup.json'
    $invalidStaff = Get-Content -LiteralPath $probePaths.StaffEmployment -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $invalidStaff.cleanup.currentAssignmentsClosed = $false
    Write-BunkFyCandidateJson -Path $invalidStaffPath -Value $invalidStaff
    Assert-TestFailure `
        -Operation {
            Get-BunkFyVerifiedProductionAdmissionProbe `
                -Path $invalidStaffPath `
                -SpecificationName staff-employment `
                -ExpectedOrigin $origin `
                -ExpectedReleaseId $candidateRelease `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'invalid cleanup disposition' `
        -Context 'false Staff assignment cleanup claim'

    $invalidPropertiesPath = Join-Path $temporaryRoot 'invalid-properties-cleanup.json'
    $invalidProperties = Get-Content -LiteralPath $probePaths.PropertiesTopology -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $invalidProperties.cleanup.topologyRetirementsCompleted = $false
    Write-BunkFyCandidateJson -Path $invalidPropertiesPath -Value $invalidProperties
    Assert-TestFailure `
        -Operation {
            Get-BunkFyVerifiedProductionAdmissionProbe `
                -Path $invalidPropertiesPath `
                -SpecificationName properties-topology `
                -ExpectedOrigin $origin `
                -ExpectedReleaseId $candidateRelease `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'invalid cleanup disposition' `
        -Context 'false Properties topology cleanup claim'

    $duplicatePrivateArguments = $arguments.Clone()
    $duplicatePrivateArguments.WorkspaceAccessEstateReference =
        $duplicatePrivateArguments.BrowserRehearsalReference
    $duplicatePrivateArguments.OutputDirectory =
        Join-Path $temporaryRoot 'duplicate-private-reference-admission'
    Assert-TestFailure `
        -Operation { & $assembler @duplicatePrivateArguments } `
        -ExpectedMessage 'distinct evidence reference' `
        -Context 'duplicate private estate evidence reference'
    if ([IO.Directory]::Exists(
            [string]$duplicatePrivateArguments.OutputDirectory)) {
        throw 'Rejected duplicate private reference left an admission bundle.'
    }

    $staleRetentionPath = Join-Path $temporaryRoot 'stale-retention.json'
    $staleRetention = Get-Content -LiteralPath $probePaths.Retention -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $staleRetention.observation.mode = 'completed-after-lower-bound'
    $staleRetention.observation.baselineCapturedAtUtc =
        ([DateTimeOffset]::Parse(
            [string]$staleRetention.generatedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture).AddSeconds(-5)).ToString('O')
    $staleRetention.observation.completionNotBeforeUtc =
        ([DateTimeOffset]::Parse(
            [string]$staleRetention.generatedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture).AddSeconds(-10)).ToString('O')
    $staleRetention.observation.clockSkewSeconds = 0
    Write-BunkFyCandidateJson -Path $staleRetentionPath -Value $staleRetention
    Assert-TestFailure `
        -Operation {
            Get-BunkFyVerifiedProductionAdmissionProbe `
                -Path $staleRetentionPath `
                -SpecificationName retention `
                -ExpectedOrigin $origin `
                -ExpectedReleaseId $candidateRelease `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'predates its completion lower bound' `
        -Context 'stale lower-bound Retention evidence'

    $wrongAdmissionReference = "admission:$([Guid]::NewGuid().ToString('N'))"
    $wrongAdmissionArguments = $verificationArguments.Clone()
    $wrongAdmissionArguments.ExpectedAdmissionEvidenceReference =
        $wrongAdmissionReference
    Assert-TestFailure `
        -Operation { & $verifier @wrongAdmissionArguments } `
        -ExpectedMessage 'does not match the expected admission evidence reference' `
        -Context 'different admission attempt identity'

    $emptyAdmissionArguments = $arguments.Clone()
    $emptyAdmissionArguments.AdmissionEvidenceReference =
        'admission:00000000000000000000000000000000'
    $emptyAdmissionArguments.OutputDirectory =
        Join-Path $temporaryRoot 'empty-admission-identity'
    Assert-TestFailure `
        -Operation { & $assembler @emptyAdmissionArguments } `
        -ExpectedMessage 'non-empty admission identity' `
        -Context 'empty admission attempt identity'

    $hostedVerificationArguments = $verificationArguments.Clone()
    $hostedVerificationArguments.AllowFixtureEvidence = $false
    Assert-TestFailure `
        -Operation { & $verifier @hostedVerificationArguments } `
        -ExpectedMessage 'HTTPS' `
        -Context 'fixture evidence without explicit admission'
}
finally {
    if ([IO.Directory]::Exists($temporaryRoot)) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}

Write-Host 'BunkFy production admission fixture passed.'
