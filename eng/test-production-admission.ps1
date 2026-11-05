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
        [Parameter(Mandatory = $true)][string] $AdmissionEvidenceReference,
        [Guid] $EvidenceSetId = [Guid]::Empty
    )

    $spec = Get-BunkFyProductionAdmissionProbeSpecification -Name $SpecificationName
    $record = [ordered]@{
        schemaVersion = $spec.SchemaVersion
        evidenceKind = $spec.EvidenceKind
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
    $record['admissionEvidenceReference'] = $AdmissionEvidenceReference
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
            $record['workflow'] = [ordered]@{
                sourceModule = 'inventory'
                createdNotificationName = 'manual-inventory-block-created'
                releasedNotificationName = 'manual-inventory-block-released'
                notificationVersion = 1
                deliveryTag = 'delivery:web'
                domainTag = 'domain:inventory'
            }
            $record['delivery'] = [ordered]@{
                liveNotificationCount = 2
                initiallyUnreadCount = 2
                durablyReadCount = 2
                observerHistoryCount = 2
                actorDeliveryCount = 0
                ordered = $true
            }
            $record['cleanup'] = [ordered]@{
                inventoryBlock = 'released'
                notificationHistory = 'retained-read'
            }
        }
        'reservations-inventory' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            $record['workflow'] = [ordered]@{
                bookingSource = 'direct'
                allocationLifecycle = 'available-confirmed-released'
                occupancyLifecycle = 'confirmed-checked-in-checked-out'
                createReplay = 'stable-current'
                checkInReplay = 'stable-current'
                checkOutReplay = 'stable-current'
                durableGuestRecordCreated = $false
            }
            $record['cleanup'] = [ordered]@{
                reservationDisposition = 'synthetic-checked-out-retained'
                selectedInventoryUnit = 'available'
                activeAllocationCount = 0
                topologyMutated = $false
            }
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
        'ingestion-connection-lifecycle' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            $record['workflow'] = [ordered]@{
                executionMode = 'remote-polling'
                protocolVersion = 7
                configurationSchemaVersion = 3
                connectionFinalStatus = 'disabled'
                connectionVersionAdvanced = $true
                secretReferenceLifecycle = 'set-then-cleared'
                credentialFinalStatus = 'revoked'
                credentialVersionAdvanced = $true
                credentialIssuance = 'one-time-nonredisclosing'
                independentAuthentication = 'issued-accepted-then-revoked-denied'
                runFinalStatus = 'succeeded'
                runObservedCount = 0
                activeLease = $false
            }
            $record['cleanup'] = [ordered]@{
                connectionDisposition = 'synthetic-disabled-retained'
                credentialDisposition = 'synthetic-revoked-retained'
                runDisposition = 'synthetic-succeeded-empty-retained'
                parentPropertyLifecycleOwnedByCaller = $true
            }
        }
        'ingestion-conflict-proposal-lifecycle' {
            $record['origin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            $record['adapterContract'] = [ordered]@{
                executionMode = 'push'
                protocolVersion = 7
                configurationSchemaVersion = 3
            }
            $record['authorityRevisions'] = [ordered]@{
                initialAdapter = 1
                automaticAdapter = 2
                staff = 3
                acceptedAdapter = 4
            }
            $record['proposalSummary'] = [ordered]@{
                total = 3
                superseded = 1
                rejected = 1
                applied = 1
                pending = 0
            }
            $record['cleanup'] = [ordered]@{
                reservation = 'cancelled'
                credential = 'revoked'
                connection = 'disabled'
                credentialVersion = 2
                connectionVersion = 2
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
        [Parameter(Mandatory = $true)][object] $RollbackPromotion,
        [Parameter(Mandatory = $true)][string] $AdmissionEvidenceReference
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
            -ReleaseId $entry.Value.ReleaseId `
            -AdmissionEvidenceReference $AdmissionEvidenceReference
    }
    $rehearsalId = [Guid]::NewGuid()
    $completed = [DateTimeOffset]::UtcNow.ToString('O')
    $record = [ordered]@{
        schemaVersion = 2
        evidenceKind = 'bunkfy-deployed-release-rollback-rehearsal'
        rehearsalId = $rehearsalId.ToString('D')
        rollbackEvidenceReference = "rollback:$($rehearsalId.ToString('N'))"
        admissionEvidenceReference = $AdmissionEvidenceReference
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

function New-TestPrivateControlIndex {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][object] $CandidatePromotion,
        [Parameter(Mandatory = $true)][string] $AdmissionEvidenceReference,
        [DateTimeOffset] $GeneratedAtUtc = [DateTimeOffset]::UtcNow
    )

    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $indexId = [Guid]::NewGuid()
    $references = [ordered]@{
        'browser-workspace-onboarding' = 'record:BROWSER-123'
        'deployment-approval-alerting-and-rollback' = 'record:DEPLOY-123'
        'hosted-backup-and-recovery' = 'record:RECOVERY-123'
        'runtime-topology-restart-and-credential-rotation' = 'record:RUNTIME-123'
        'workspace-access-seed-estate' = 'record:ACCESS-123'
    }
    $hashSeeds = [ordered]@{
        'browser-workspace-onboarding' = '1'
        'deployment-approval-alerting-and-rollback' = '2'
        'hosted-backup-and-recovery' = '3'
        'runtime-topology-restart-and-credential-rotation' = '4'
        'workspace-access-seed-estate' = '5'
    }
    $record = [ordered]@{
        schemaVersion = 1
        evidenceKind = 'bunkfy-private-production-control-index'
        indexId = $indexId.ToString('D')
        privateControlIndexReference =
            "private-controls:$($indexId.ToString('N'))"
        generatedAtUtc = $GeneratedAtUtc.ToUniversalTime().ToString('O')
        repository = 'SadPossum/BunkFy'
        profile = 'loopback-fixture'
        result = 'recorded-awaiting-private-approval'
        admissionEvidenceReference = $AdmissionEvidenceReference
        candidate = [ordered]@{
            releaseId = $CandidatePromotion.ReleaseId
            sourceCommit = $CandidatePromotion.SourceCommit
            images = @($CandidatePromotion.Images | Sort-Object Name | ForEach-Object {
                    [ordered]@{
                        name = $_.Name
                        digestReference = $_.DigestReference
                    }
                })
        }
        controls = @($script:BunkFyProductionAdmissionPrivateControls |
            Sort-Object |
            ForEach-Object {
                [ordered]@{
                    control = $_
                    reference = $references[$_]
                    recordSha256 = $hashSeeds[$_] * 64
                    observedAtUtc =
                        $GeneratedAtUtc.ToUniversalTime().ToString('O')
                }
            })
        limitations = $script:BunkFyPrivateProductionControlIndexLimitations
    }
    $recordPath = Join-Path $Directory 'private-control-index.json'
    Write-BunkFyCandidateJson -Path $recordPath -Value $record
    $hash = (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).
        Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $Directory 'checksums.sha256'),
        "$hash  private-control-index.json`n",
        [Text.UTF8Encoding]::new($false))
}

function New-TestTamperedPrivateControlIndex {
    param(
        [Parameter(Mandatory = $true)][string] $SourceDirectory,
        [Parameter(Mandatory = $true)][string] $DestinationDirectory,
        [Parameter(Mandatory = $true)][scriptblock] $Mutation
    )

    Copy-Item `
        -LiteralPath $SourceDirectory `
        -Destination $DestinationDirectory `
        -Recurse
    $recordPath = Join-Path $DestinationDirectory 'private-control-index.json'
    $record = [IO.File]::ReadAllText($recordPath) |
        ConvertFrom-Json -AsHashtable -DateKind String
    & $Mutation $record | Out-Null
    Write-BunkFyCandidateJson -Path $recordPath -Value $record
    $hash = (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).
        Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $DestinationDirectory 'checksums.sha256'),
        "$hash  private-control-index.json`n",
        [Text.UTF8Encoding]::new($false))
}

function Assert-TestPrivateControlIndexAssemblyFailure {
    param(
        [Parameter(Mandatory = $true)][string] $SourceDirectory,
        [Parameter(Mandatory = $true)][string] $DestinationDirectory,
        [Parameter(Mandatory = $true)][scriptblock] $Mutation,
        [Parameter(Mandatory = $true)][hashtable] $BaseArguments,
        [Parameter(Mandatory = $true)][string] $OutputDirectory,
        [Parameter(Mandatory = $true)][string] $ExpectedMessage,
        [Parameter(Mandatory = $true)][string] $Context
    )

    New-TestTamperedPrivateControlIndex `
        -SourceDirectory $SourceDirectory `
        -DestinationDirectory $DestinationDirectory `
        -Mutation $Mutation
    $failureArguments = $BaseArguments.Clone()
    $failureArguments.PrivateControlIndexDirectory = $DestinationDirectory
    $failureArguments.OutputDirectory = $OutputDirectory
    Assert-TestFailure `
        -Operation { & $assembler @failureArguments } `
        -ExpectedMessage $ExpectedMessage `
        -Context $Context
    if ([IO.Directory]::Exists($OutputDirectory)) {
        throw "Rejected $Context left an admission bundle."
    }
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

function New-TestTamperedAdmissionBundle {
    param(
        [Parameter(Mandatory = $true)][string] $SourceDirectory,
        [Parameter(Mandatory = $true)][string] $DestinationDirectory,
        [Parameter(Mandatory = $true)][scriptblock] $Mutation,
        [scriptblock] $PrivateIndexMutation
    )

    Copy-Item `
        -LiteralPath $SourceDirectory `
        -Destination $DestinationDirectory `
        -Recurse
    $privateIndexPath =
        Join-Path $DestinationDirectory 'private-control-index.json'
    $privateIndex = $null
    if ($null -ne $PrivateIndexMutation) {
        $privateIndex = [IO.File]::ReadAllText($privateIndexPath) |
            ConvertFrom-Json -AsHashtable -DateKind String
        & $PrivateIndexMutation $privateIndex | Out-Null
        Write-BunkFyCandidateJson `
            -Path $privateIndexPath `
            -Value $privateIndex
    }

    $recordPath = Join-Path $DestinationDirectory 'production-admission.json'
    $record = [IO.File]::ReadAllText($recordPath) |
        ConvertFrom-Json -AsHashtable -DateKind String
    if ($null -ne $PrivateIndexMutation) {
        $privateIndexHash = (
            Get-FileHash -LiteralPath $privateIndexPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $record.privateControlIndex.sourceSha256 = $privateIndexHash
        $record.privateControlIndex.checksumsSha256 =
            Get-BunkFyPrivateProductionControlIndexChecksumsSha256 `
                -RecordSha256 $privateIndexHash
        $record.privateControlIndex.generatedAtUtc =
            $privateIndex.generatedAtUtc
        $privateIndexGeneratedAtUtc = [DateTimeOffset]::ParseExact(
            [string]$privateIndex.generatedAtUtc,
            'O',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        $record.privateControlIndex.expiresAtUtc =
            $privateIndexGeneratedAtUtc.Add(
                $script:BunkFyPrivateProductionControlIndexMaximumAge).
                ToUniversalTime().ToString('O')
    }
    & $Mutation $record | Out-Null
    Write-BunkFyCandidateJson -Path $recordPath -Value $record
    $checksumLines = @(
        Get-ChildItem -LiteralPath $DestinationDirectory -File |
            Where-Object Name -CNE 'checksums.sha256' |
            Sort-Object Name |
            ForEach-Object {
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).
                    Hash.ToLowerInvariant()
                "$hash  $($_.Name)"
            })
    [IO.File]::WriteAllText(
        (Join-Path $DestinationDirectory 'checksums.sha256'),
        (($checksumLines -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false))
}

function New-TestTamperedRollbackEvidence {
    param(
        [Parameter(Mandatory = $true)][string] $SourceDirectory,
        [Parameter(Mandatory = $true)][string] $DestinationDirectory,
        [Parameter(Mandatory = $true)][scriptblock] $Mutation
    )

    Copy-Item `
        -LiteralPath $SourceDirectory `
        -Destination $DestinationDirectory `
        -Recurse
    $recordPath = Join-Path $DestinationDirectory 'rollback-rehearsal.json'
    $record = [IO.File]::ReadAllText($recordPath) |
        ConvertFrom-Json -AsHashtable -DateKind String
    & $Mutation $record | Out-Null
    Write-BunkFyCandidateJson -Path $recordPath -Value $record
    $checksumLines = @(
        Get-ChildItem -LiteralPath $DestinationDirectory -File |
            Where-Object Name -CNE 'checksums.sha256' |
            Sort-Object Name |
            ForEach-Object {
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).
                    Hash.ToLowerInvariant()
                "$hash  $($_.Name)"
            })
    [IO.File]::WriteAllText(
        (Join-Path $DestinationDirectory 'checksums.sha256'),
        (($checksumLines -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false))
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
    $privateControlIndexPath = Join-Path $temporaryRoot 'private-controls'
    New-TestPrivateControlIndex `
        -Directory $privateControlIndexPath `
        -CandidatePromotion $candidatePromotion `
        -AdmissionEvidenceReference $admissionReference

    $rollbackRehearsalPath = Join-Path $temporaryRoot 'rollback-rehearsal'
    New-TestRollbackEvidence -Directory $rollbackRehearsalPath -Origin $origin -CandidatePromotion $candidatePromotion -RollbackPromotion $rollbackPromotion -AdmissionEvidenceReference $admissionReference
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
        IngestionConnectionLifecycle = Join-Path $temporaryRoot 'ingestion-connection-lifecycle.json'
        IngestionConflictProposalLifecycle = Join-Path $temporaryRoot 'ingestion-conflict-proposal-lifecycle.json'
        DataRightsAccessExport = Join-Path $temporaryRoot 'data-rights-access-export.json'
        AdapterHost = Join-Path $temporaryRoot 'adapter-host.json'
        Retention = Join-Path $temporaryRoot 'retention.json'
    }
    New-TestProbeEvidence -Path $probePaths.PublicEdge -SpecificationName public-edge -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.AdminAllowed -SpecificationName admin-allowed -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference -EvidenceSetId $adminSetId
    New-TestProbeEvidence -Path $probePaths.AdminDenied -SpecificationName admin-denied -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference -EvidenceSetId $adminSetId
    New-TestProbeEvidence -Path $probePaths.Invitation -SpecificationName workspace-invitation -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.Enrollment -SpecificationName workspace-enrollment -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.Notifications -SpecificationName operations-notifications -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.ReservationsInventory -SpecificationName reservations-inventory -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.GuestsStayHistory -SpecificationName guests-stay-history -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.StaffEmployment -SpecificationName staff-employment -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.PropertiesTopology -SpecificationName properties-topology -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.IngestionConnectionLifecycle -SpecificationName ingestion-connection-lifecycle -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.IngestionConflictProposalLifecycle -SpecificationName ingestion-conflict-proposal-lifecycle -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.DataRightsAccessExport -SpecificationName data-rights-access-export -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.AdapterHost -SpecificationName adapter-host -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference
    New-TestProbeEvidence -Path $probePaths.Retention -SpecificationName retention -Origin $origin -ReleaseId $candidateRelease -AdmissionEvidenceReference $admissionReference

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
        IngestionConnectionLifecycleEvidencePath = $probePaths.IngestionConnectionLifecycle
        IngestionConflictProposalLifecycleEvidencePath = $probePaths.IngestionConflictProposalLifecycle
        DataRightsAccessExportEvidencePath = $probePaths.DataRightsAccessExport
        AdapterHostEvidencePath = $probePaths.AdapterHost
        RetentionEvidencePath = $probePaths.Retention
        PrivateControlIndexDirectory = $privateControlIndexPath
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
    if ($closed.Files.Count -ne 2 -or
        $assembled.AdmissionEvidenceReference -cne $verified.AdmissionEvidenceReference -or
        $verified.AdmissionEvidenceReference -cne $admissionReference -or
        $verified.ReleaseId -cne $candidateRelease -or
        $verified.Record.schemaVersion -ne 3 -or
        $verified.PrivateControlIndexReference -cne
            $verified.Record.privateControlIndex.evidenceReference -or
        $verified.ExpiresAtUtc -le [DateTimeOffset]::UtcNow -or
        @($verified.Record.evidence).Count -ne 19 -or
        @($verified.Record.privateEvidence).Count -ne 5 -or
        @($verified.Record.checks).Count -ne 9) {
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

    $serialized = @(
        [IO.File]::ReadAllText((Join-Path $output 'production-admission.json')),
        [IO.File]::ReadAllText((Join-Path $output 'private-control-index.json'))
    ) -join "`n"
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

    $tamperedPrivateIndexBundle =
        Join-Path $temporaryRoot 'tampered-retained-private-index'
    Copy-Item `
        -LiteralPath $output `
        -Destination $tamperedPrivateIndexBundle `
        -Recurse
    [IO.File]::AppendAllText(
        (Join-Path $tamperedPrivateIndexBundle 'private-control-index.json'),
        ' ')
    $tamperedPrivateIndexVerificationArguments =
        $verificationArguments.Clone()
    $tamperedPrivateIndexVerificationArguments.AdmissionDirectory =
        $tamperedPrivateIndexBundle
    Assert-TestFailure `
        -Operation {
            & $verifier @tamperedPrivateIndexVerificationArguments
        } `
        -ExpectedMessage 'does not match checksums' `
        -Context 'tampered retained private control index'

    $schemaV2Admission = Join-Path $temporaryRoot 'schema-v2-admission'
    New-TestTamperedAdmissionBundle `
        -SourceDirectory $output `
        -DestinationDirectory $schemaV2Admission `
        -Mutation {
            param($record)
            $record.schemaVersion = 2
        }
    $schemaV2VerificationArguments = $verificationArguments.Clone()
    $schemaV2VerificationArguments.AdmissionDirectory = $schemaV2Admission
    Assert-TestFailure `
        -Operation { & $verifier @schemaV2VerificationArguments } `
        -ExpectedMessage 'invalid identity or result' `
        -Context 'unbound schema-v2 admission bundle'

    Assert-TestPrivateControlIndexAssemblyFailure `
        -SourceDirectory $privateControlIndexPath `
        -DestinationDirectory (
            Join-Path $temporaryRoot 'missing-private-control-index') `
        -Mutation {
            param($record)
            $record.controls = @($record.controls | Select-Object -Skip 1)
        } `
        -BaseArguments $arguments `
        -OutputDirectory (
            Join-Path $temporaryRoot 'missing-private-control-admission') `
        -ExpectedMessage 'incomplete control set' `
        -Context 'missing private control'

    Assert-TestPrivateControlIndexAssemblyFailure `
        -SourceDirectory $privateControlIndexPath `
        -DestinationDirectory (
            Join-Path $temporaryRoot 'extra-private-control-index') `
        -Mutation {
            param($record)
            $record.controls += [ordered]@{
                control = 'unsupported-private-control'
                reference = 'record:EXTRA-123'
                recordSha256 = '6' * 64
                observedAtUtc = $record.generatedAtUtc
            }
        } `
        -BaseArguments $arguments `
        -OutputDirectory (
            Join-Path $temporaryRoot 'extra-private-control-admission') `
        -ExpectedMessage 'incomplete control set' `
        -Context 'extra private control'

    Assert-TestPrivateControlIndexAssemblyFailure `
        -SourceDirectory $privateControlIndexPath `
        -DestinationDirectory (
            Join-Path $temporaryRoot 'duplicate-private-hash-index') `
        -Mutation {
            param($record)
            $record.controls[1].recordSha256 =
                $record.controls[0].recordSha256
        } `
        -BaseArguments $arguments `
        -OutputDirectory (
            Join-Path $temporaryRoot 'duplicate-private-hash-admission') `
        -ExpectedMessage 'record checksums must be distinct' `
        -Context 'duplicate private control record checksum'

    Assert-TestPrivateControlIndexAssemblyFailure `
        -SourceDirectory $privateControlIndexPath `
        -DestinationDirectory (
            Join-Path $temporaryRoot 'cross-candidate-private-index') `
        -Mutation {
            param($record)
            $record.candidate.sourceCommit = $rollbackSource
        } `
        -BaseArguments $arguments `
        -OutputDirectory (
            Join-Path $temporaryRoot 'cross-candidate-private-admission') `
        -ExpectedMessage 'different candidate' `
        -Context 'cross-candidate private control index'

    Assert-TestPrivateControlIndexAssemblyFailure `
        -SourceDirectory $privateControlIndexPath `
        -DestinationDirectory (
            Join-Path $temporaryRoot 'cross-attempt-private-index') `
        -Mutation {
            param($record)
            $record.admissionEvidenceReference =
                "admission:$([Guid]::NewGuid().ToString('N'))"
        } `
        -BaseArguments $arguments `
        -OutputDirectory (
            Join-Path $temporaryRoot 'cross-attempt-private-admission') `
        -ExpectedMessage 'different admission attempt' `
        -Context 'cross-attempt private control index'

    Assert-TestPrivateControlIndexAssemblyFailure `
        -SourceDirectory $privateControlIndexPath `
        -DestinationDirectory (
            Join-Path $temporaryRoot 'stale-private-index') `
        -Mutation {
            param($record)
            $timestamp = [DateTimeOffset]::UtcNow.AddHours(-25).ToString('O')
            $record.generatedAtUtc = $timestamp
            foreach ($control in @($record.controls)) {
                $control.observedAtUtc = $timestamp
            }
        } `
        -BaseArguments $arguments `
        -OutputDirectory (
            Join-Path $temporaryRoot 'stale-private-index-admission') `
        -ExpectedMessage 'older than its 1440-minute freshness limit' `
        -Context 'stale private control index'

    Assert-TestPrivateControlIndexAssemblyFailure `
        -SourceDirectory $privateControlIndexPath `
        -DestinationDirectory (
            Join-Path $temporaryRoot 'stale-browser-control-index') `
        -Mutation {
            param($record)
            $browser = @($record.controls | Where-Object {
                    $_.control -ceq 'browser-workspace-onboarding'
                })[0]
            $browser.observedAtUtc =
                [DateTimeOffset]::UtcNow.AddHours(-25).ToString('O')
        } `
        -BaseArguments $arguments `
        -OutputDirectory (
            Join-Path $temporaryRoot 'stale-browser-control-admission') `
        -ExpectedMessage 'older than its 1440-minute freshness limit' `
        -Context 'stale browser workspace-onboarding control'

    Assert-TestPrivateControlIndexAssemblyFailure `
        -SourceDirectory $privateControlIndexPath `
        -DestinationDirectory (
            Join-Path $temporaryRoot 'future-private-index') `
        -Mutation {
            param($record)
            $timestamp = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('O')
            $record.generatedAtUtc = $timestamp
            foreach ($control in @($record.controls)) {
                $control.observedAtUtc = $timestamp
            }
        } `
        -BaseArguments $arguments `
        -OutputDirectory (
            Join-Path $temporaryRoot 'future-private-index-admission') `
        -ExpectedMessage 'valid non-future UTC round-trip timestamp' `
        -Context 'future private control index'

    Assert-TestPrivateControlIndexAssemblyFailure `
        -SourceDirectory $privateControlIndexPath `
        -DestinationDirectory (
            Join-Path $temporaryRoot 'future-private-control-index') `
        -Mutation {
            param($record)
            $record.controls[0].observedAtUtc =
                [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('O')
        } `
        -BaseArguments $arguments `
        -OutputDirectory (
            Join-Path $temporaryRoot 'future-private-control-admission') `
        -ExpectedMessage 'valid non-future UTC round-trip timestamp' `
        -Context 'future private control observation'

    $extraFilePrivateIndexPath =
        Join-Path $temporaryRoot 'extra-file-private-index'
    Copy-Item `
        -LiteralPath $privateControlIndexPath `
        -Destination $extraFilePrivateIndexPath `
        -Recurse
    [IO.File]::WriteAllText(
        (Join-Path $extraFilePrivateIndexPath 'private-details.json'),
        "{}`n",
        [Text.UTF8Encoding]::new($false))
    $extraFilePrivateIndexArguments = $arguments.Clone()
    $extraFilePrivateIndexArguments.PrivateControlIndexDirectory =
        $extraFilePrivateIndexPath
    $extraFilePrivateIndexArguments.OutputDirectory =
        Join-Path $temporaryRoot 'extra-file-private-admission'
    Assert-TestFailure `
        -Operation { & $assembler @extraFilePrivateIndexArguments } `
        -ExpectedMessage 'not a closed checksummed file set' `
        -Context 'private control index with unlisted private detail'

    $nonCanonicalPrivateIndexPath =
        Join-Path $temporaryRoot 'noncanonical-private-index'
    Copy-Item `
        -LiteralPath $privateControlIndexPath `
        -Destination $nonCanonicalPrivateIndexPath `
        -Recurse
    $privateRecordHash = (
        Get-FileHash `
            -LiteralPath (
                Join-Path $nonCanonicalPrivateIndexPath `
                    'private-control-index.json') `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $nonCanonicalPrivateIndexPath 'checksums.sha256'),
        "$privateRecordHash  private-control-index.json`r`n",
        [Text.UTF8Encoding]::new($false))
    $nonCanonicalPrivateIndexArguments = $arguments.Clone()
    $nonCanonicalPrivateIndexArguments.PrivateControlIndexDirectory =
        $nonCanonicalPrivateIndexPath
    $nonCanonicalPrivateIndexArguments.OutputDirectory =
        Join-Path $temporaryRoot 'noncanonical-private-admission'
    Assert-TestFailure `
        -Operation { & $assembler @nonCanonicalPrivateIndexArguments } `
        -ExpectedMessage 'canonical closed checksum' `
        -Context 'noncanonical private control index checksum set'

    $overlappingPrivateIndexArguments = $arguments.Clone()
    $overlappingPrivateIndexArguments.OutputDirectory =
        Join-Path $privateControlIndexPath 'nested-admission-output'
    Assert-TestFailure `
        -Operation { & $assembler @overlappingPrivateIndexArguments } `
        -ExpectedMessage 'must not overlap' `
        -Context 'private control index and admission output overlap'
    if ([IO.Directory]::Exists(
            [string]$overlappingPrivateIndexArguments.OutputDirectory)) {
        throw 'Rejected private control index overlap left an admission bundle.'
    }

    $privateHashDriftAdmission =
        Join-Path $temporaryRoot 'private-hash-drift-admission'
    New-TestTamperedAdmissionBundle `
        -SourceDirectory $output `
        -DestinationDirectory $privateHashDriftAdmission `
        -Mutation {
            param($record)
            $record.privateEvidence[0].recordSha256 = 'f' * 64
        }
    $privateHashDriftVerificationArguments =
        $verificationArguments.Clone()
    $privateHashDriftVerificationArguments.AdmissionDirectory =
        $privateHashDriftAdmission
    Assert-TestFailure `
        -Operation { & $verifier @privateHashDriftVerificationArguments } `
        -ExpectedMessage 'not cross-bound to the retained index' `
        -Context 'standalone private control hash drift'

    $stalePublicEdgePath = Join-Path $temporaryRoot 'stale-public-edge.json'
    $stalePublicEdge = [IO.File]::ReadAllText($probePaths.PublicEdge) |
        ConvertFrom-Json -AsHashtable -DateKind String
    $stalePublicEdge.generatedAtUtc =
        [DateTimeOffset]::UtcNow.AddHours(-25).ToString('O')
    Write-BunkFyCandidateJson -Path $stalePublicEdgePath -Value $stalePublicEdge
    Assert-TestFailure `
        -Operation {
            Get-BunkFyVerifiedProductionAdmissionProbe `
                -Path $stalePublicEdgePath `
                -SpecificationName public-edge `
                -ExpectedOrigin $origin `
                -ExpectedReleaseId $candidateRelease `
                -ExpectedAdmissionEvidenceReference $admissionReference `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'older than the 24-hour mutable evidence limit' `
        -Context 'stale mutable deployment evidence'

    $futurePublicEdgePath = Join-Path $temporaryRoot 'future-public-edge.json'
    $futurePublicEdge = [IO.File]::ReadAllText($probePaths.PublicEdge) |
        ConvertFrom-Json -AsHashtable -DateKind String
    $futurePublicEdge.generatedAtUtc =
        [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('O')
    Write-BunkFyCandidateJson `
        -Path $futurePublicEdgePath `
        -Value $futurePublicEdge
    Assert-TestFailure `
        -Operation {
            Get-BunkFyVerifiedProductionAdmissionProbe `
                -Path $futurePublicEdgePath `
                -SpecificationName public-edge `
                -ExpectedOrigin $origin `
                -ExpectedReleaseId $candidateRelease `
                -ExpectedAdmissionEvidenceReference $admissionReference `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'valid non-future UTC round-trip timestamp' `
        -Context 'future mutable deployment evidence'

    $misorderedRollbackPath = Join-Path $temporaryRoot 'misordered-rollback'
    New-TestTamperedRollbackEvidence `
        -SourceDirectory $rollbackRehearsalPath `
        -DestinationDirectory $misorderedRollbackPath `
        -Mutation {
            param($record)
            $baseline = [DateTimeOffset]::Parse(
                [string]$record.timing.baselineVerifiedAtUtc,
                [Globalization.CultureInfo]::InvariantCulture)
            $record.timing.rollbackObservedAtUtc =
                $baseline.AddSeconds(-1).ToString('O')
        }
    Assert-TestFailure `
        -Operation {
            Get-BunkFyVerifiedDeployedRollbackRehearsal `
                -Directory $misorderedRollbackPath `
                -ExpectedOrigin $origin `
                -CandidatePromotion $candidatePromotion `
                -RollbackPromotion $rollbackPromotion `
                -ExpectedAdmissionEvidenceReference $admissionReference `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'timing is inconsistent' `
        -Context 'misordered rollback evidence'

    $duplicateRollbackCheckPath =
        Join-Path $temporaryRoot 'duplicate-rollback-check'
    New-TestTamperedRollbackEvidence `
        -SourceDirectory $rollbackRehearsalPath `
        -DestinationDirectory $duplicateRollbackCheckPath `
        -Mutation {
            param($record)
            $record.checks[1] = $record.checks[0]
        }
    Assert-TestFailure `
        -Operation {
            Get-BunkFyVerifiedDeployedRollbackRehearsal `
                -Directory $duplicateRollbackCheckPath `
                -ExpectedOrigin $origin `
                -CandidatePromotion $candidatePromotion `
                -RollbackPromotion $rollbackPromotion `
                -ExpectedAdmissionEvidenceReference $admissionReference `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'unsupported release check' `
        -Context 'duplicate rollback evidence check'

    $expiredAdmission = Join-Path $temporaryRoot 'expired-admission'
    $expiredGeneratedAtUtc = [DateTimeOffset]::UtcNow.AddHours(-5)
    New-TestTamperedAdmissionBundle `
        -SourceDirectory $output `
        -DestinationDirectory $expiredAdmission `
        -Mutation {
            param($record)
            $timestamp = $expiredGeneratedAtUtc.ToString('O')
            $record.generatedAtUtc = $timestamp
            foreach ($entry in @($record.evidence)) {
                $entry.observedAtUtc = $timestamp
            }
            foreach ($entry in @($record.privateEvidence)) {
                $entry.observedAtUtc = $timestamp
            }
            $record.validity.oldestMutableEvidenceAtUtc = $timestamp
            $record.validity.newestMutableEvidenceAtUtc = $timestamp
            $privateExpiry =
                $expiredGeneratedAtUtc.AddHours(24).ToString('O')
            $record.validity.privateControlIndexExpiresAtUtc =
                $privateExpiry
            $record.validity.privateControlEvidenceExpiresAtUtc =
                $privateExpiry
            $record.validity.expiresAtUtc =
                $expiredGeneratedAtUtc.AddHours(4).ToString('O')
        } `
        -PrivateIndexMutation {
            param($record)
            $timestamp = $expiredGeneratedAtUtc.ToString('O')
            $record.generatedAtUtc = $timestamp
            foreach ($entry in @($record.controls)) {
                $entry.observedAtUtc = $timestamp
            }
        }
    $expiredVerificationArguments = $verificationArguments.Clone()
    $expiredVerificationArguments.AdmissionDirectory = $expiredAdmission
    Assert-TestFailure `
        -Operation { & $verifier @expiredVerificationArguments } `
        -ExpectedMessage 'has expired' `
        -Context 'expired production admission bundle'

    $expandedValidityAdmission =
        Join-Path $temporaryRoot 'expanded-validity-admission'
    New-TestTamperedAdmissionBundle `
        -SourceDirectory $output `
        -DestinationDirectory $expandedValidityAdmission `
        -Mutation {
            param($record)
            $record.validity.mutableEvidenceMaximumAgeMinutes = 525600
        }
    $expandedValidityArguments = $verificationArguments.Clone()
    $expandedValidityArguments.AdmissionDirectory = $expandedValidityAdmission
    Assert-TestFailure `
        -Operation { & $verifier @expandedValidityArguments } `
        -ExpectedMessage 'validity policy is invalid' `
        -Context 'self-expanded admission validity'

    $repositoryDriftAdmission =
        Join-Path $temporaryRoot 'repository-drift-admission'
    New-TestTamperedAdmissionBundle `
        -SourceDirectory $output `
        -DestinationDirectory $repositoryDriftAdmission `
        -Mutation {
            param($record)
            $backendImage = @($record.rollback.images | Where-Object {
                    $_.name -ceq 'backend'
                })[0]
            $separator = $backendImage.digestReference.IndexOf('@')
            $backendImage.digestReference =
                'registry.fixture.invalid/bunkfy/alternate-backend' +
                $backendImage.digestReference.Substring($separator)
        }
    $repositoryDriftArguments = $verificationArguments.Clone()
    $repositoryDriftArguments.AdmissionDirectory = $repositoryDriftAdmission
    Assert-TestFailure `
        -Operation { & $verifier @repositoryDriftArguments } `
        -ExpectedMessage 'promotion identities are inconsistent' `
        -Context 'candidate and rollback repository drift'

    $promotionChecksumDriftAdmission =
        Join-Path $temporaryRoot 'promotion-checksum-drift-admission'
    New-TestTamperedAdmissionBundle `
        -SourceDirectory $output `
        -DestinationDirectory $promotionChecksumDriftAdmission `
        -Mutation {
            param($record)
            $summary = @($record.evidence | Where-Object {
                    $_.name -ceq 'candidate-image-promotion'
                })[0]
            $summary.sourceSha256 = if (
                $summary.sourceSha256 -ceq ('4' * 64)) {
                '5' * 64
            }
            else {
                '4' * 64
            }
        }
    $promotionChecksumDriftArguments = $verificationArguments.Clone()
    $promotionChecksumDriftArguments.AdmissionDirectory =
        $promotionChecksumDriftAdmission
    Assert-TestFailure `
        -Operation { & $verifier @promotionChecksumDriftArguments } `
        -ExpectedMessage 'checksum is not cross-bound' `
        -Context 'promotion summary checksum drift'

    $sourceReferenceDriftAdmission =
        Join-Path $temporaryRoot 'source-reference-drift-admission'
    New-TestTamperedAdmissionBundle `
        -SourceDirectory $output `
        -DestinationDirectory $sourceReferenceDriftAdmission `
        -Mutation {
            param($record)
            $summary = @($record.evidence | Where-Object {
                    $_.name -ceq 'deployed-public-edge'
                })[0]
            $summary.evidenceReference =
                "admission:$([Guid]::NewGuid().ToString('N'))"
        }
    $sourceReferenceDriftArguments = $verificationArguments.Clone()
    $sourceReferenceDriftArguments.AdmissionDirectory =
        $sourceReferenceDriftAdmission
    Assert-TestFailure `
        -Operation { & $verifier @sourceReferenceDriftArguments } `
        -ExpectedMessage 'has an invalid binding' `
        -Context 'source evidence reference drift'

    $duplicatePrivateAdmission =
        Join-Path $temporaryRoot 'duplicate-private-standalone-admission'
    New-TestTamperedAdmissionBundle `
        -SourceDirectory $output `
        -DestinationDirectory $duplicatePrivateAdmission `
        -Mutation {
            param($record)
            $record.privateEvidence[1].reference =
                $record.privateEvidence[0].reference
        }
    $duplicatePrivateVerificationArguments = $verificationArguments.Clone()
    $duplicatePrivateVerificationArguments.AdmissionDirectory =
        $duplicatePrivateAdmission
    Assert-TestFailure `
        -Operation { & $verifier @duplicatePrivateVerificationArguments } `
        -ExpectedMessage 'private evidence references must be distinct' `
        -Context 'standalone duplicate private evidence reference'

    $systemReferenceReuseAdmission =
        Join-Path $temporaryRoot 'system-reference-reuse-admission'
    New-TestTamperedAdmissionBundle `
        -SourceDirectory $output `
        -DestinationDirectory $systemReferenceReuseAdmission `
        -Mutation {
            param($record)
            $record.privateEvidence[0].reference =
                $record.admissionEvidenceReference
        }
    $systemReferenceReuseVerificationArguments = $verificationArguments.Clone()
    $systemReferenceReuseVerificationArguments.AdmissionDirectory =
        $systemReferenceReuseAdmission
    Assert-TestFailure `
        -Operation { & $verifier @systemReferenceReuseVerificationArguments } `
        -ExpectedMessage 'must not reuse a system reference' `
        -Context 'standalone private and system evidence reference reuse'

    $wrongReleaseNotifications = Join-Path $temporaryRoot 'wrong-release-notifications.json'
    New-TestProbeEvidence -Path $wrongReleaseNotifications -SpecificationName operations-notifications -Origin $origin -ReleaseId $rollbackRelease -AdmissionEvidenceReference $admissionReference
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

    $differentAttemptNotifications =
        Join-Path $temporaryRoot 'different-attempt-notifications.json'
    $differentAdmissionReference =
        "admission:$([Guid]::NewGuid().ToString('N'))"
    New-TestProbeEvidence `
        -Path $differentAttemptNotifications `
        -SpecificationName operations-notifications `
        -Origin $origin `
        -ReleaseId $candidateRelease `
        -AdmissionEvidenceReference $differentAdmissionReference
    $differentAttemptArguments = $arguments.Clone()
    $differentAttemptArguments.OperationsNotificationsEvidencePath =
        $differentAttemptNotifications
    $differentAttemptArguments.OutputDirectory =
        Join-Path $temporaryRoot 'different-attempt-admission'
    Assert-TestFailure `
        -Operation { & $assembler @differentAttemptArguments } `
        -ExpectedMessage 'different admission attempt' `
        -Context 'cross-attempt source evidence'
    if ([IO.Directory]::Exists(
            [string]$differentAttemptArguments.OutputDirectory)) {
        throw 'Rejected cross-attempt evidence left an admission bundle.'
    }

    $invalidNotificationsPath = Join-Path $temporaryRoot 'invalid-notification-delivery.json'
    $invalidNotifications = Get-Content -LiteralPath $probePaths.Notifications -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $invalidNotifications.delivery.actorDeliveryCount = 1
    Write-BunkFyCandidateJson `
        -Path $invalidNotificationsPath `
        -Value $invalidNotifications
    $invalidNotificationsArguments = $arguments.Clone()
    $invalidNotificationsArguments.OperationsNotificationsEvidencePath =
        $invalidNotificationsPath
    $invalidNotificationsArguments.OutputDirectory =
        Join-Path $temporaryRoot 'invalid-notifications-admission'
    Assert-TestFailure `
        -Operation { & $assembler @invalidNotificationsArguments } `
        -ExpectedMessage 'invalid delivery summary' `
        -Context 'Operations Notifications actor-delivery drift'
    if ([IO.Directory]::Exists(
            [string]$invalidNotificationsArguments.OutputDirectory)) {
        throw 'Rejected Operations Notifications evidence left an admission bundle.'
    }

    $invalidReservationsInventoryPath = Join-Path $temporaryRoot 'invalid-reservations-inventory-cleanup.json'
    $invalidReservationsInventory = Get-Content `
        -LiteralPath $probePaths.ReservationsInventory `
        -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $invalidReservationsInventory.cleanup.activeAllocationCount = 1
    Write-BunkFyCandidateJson `
        -Path $invalidReservationsInventoryPath `
        -Value $invalidReservationsInventory
    $invalidReservationsInventoryArguments = $arguments.Clone()
    $invalidReservationsInventoryArguments.ReservationsInventoryEvidencePath =
        $invalidReservationsInventoryPath
    $invalidReservationsInventoryArguments.OutputDirectory =
        Join-Path $temporaryRoot 'invalid-reservations-inventory-admission'
    Assert-TestFailure `
        -Operation { & $assembler @invalidReservationsInventoryArguments } `
        -ExpectedMessage 'invalid cleanup disposition' `
        -Context 'Reservations and Inventory active-allocation drift'
    if ([IO.Directory]::Exists(
            [string]$invalidReservationsInventoryArguments.OutputDirectory)) {
        throw 'Rejected Reservations and Inventory evidence left an admission bundle.'
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
                -ExpectedAdmissionEvidenceReference $admissionReference `
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
                -ExpectedAdmissionEvidenceReference $admissionReference `
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
                -ExpectedAdmissionEvidenceReference $admissionReference `
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
                -ExpectedAdmissionEvidenceReference $admissionReference `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'invalid cleanup disposition' `
        -Context 'false Properties topology cleanup claim'

    $invalidIngestionPath = Join-Path $temporaryRoot 'invalid-ingestion-lifecycle-cleanup.json'
    $invalidIngestion = Get-Content -LiteralPath $probePaths.IngestionConnectionLifecycle -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $invalidIngestion.cleanup.credentialDisposition = 'synthetic-active-retained'
    Write-BunkFyCandidateJson -Path $invalidIngestionPath -Value $invalidIngestion
    Assert-TestFailure `
        -Operation {
            Get-BunkFyVerifiedProductionAdmissionProbe `
                -Path $invalidIngestionPath `
                -SpecificationName ingestion-connection-lifecycle `
                -ExpectedOrigin $origin `
                -ExpectedReleaseId $candidateRelease `
                -ExpectedAdmissionEvidenceReference $admissionReference `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'invalid cleanup disposition' `
        -Context 'false Ingestion credential cleanup claim'

    $invalidProposalPath = Join-Path $temporaryRoot 'invalid-ingestion-proposal-summary.json'
    $invalidProposal = Get-Content -LiteralPath $probePaths.IngestionConflictProposalLifecycle -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $invalidProposal.proposalSummary.pending = 1
    Write-BunkFyCandidateJson -Path $invalidProposalPath -Value $invalidProposal
    Assert-TestFailure `
        -Operation {
            Get-BunkFyVerifiedProductionAdmissionProbe `
                -Path $invalidProposalPath `
                -SpecificationName ingestion-conflict-proposal-lifecycle `
                -ExpectedOrigin $origin `
                -ExpectedReleaseId $candidateRelease `
                -ExpectedAdmissionEvidenceReference $admissionReference `
                -AllowFixtureEvidence | Out-Null
        } `
        -ExpectedMessage 'invalid terminal proposal summary' `
        -Context 'pending Ingestion proposal admitted as terminal evidence'

    $duplicatePrivateIndexPath =
        Join-Path $temporaryRoot 'duplicate-private-reference-index'
    New-TestTamperedPrivateControlIndex `
        -SourceDirectory $privateControlIndexPath `
        -DestinationDirectory $duplicatePrivateIndexPath `
        -Mutation {
            param($record)
            $record.controls[1].reference = $record.controls[0].reference
        }
    $duplicatePrivateArguments = $arguments.Clone()
    $duplicatePrivateArguments.PrivateControlIndexDirectory =
        $duplicatePrivateIndexPath
    $duplicatePrivateArguments.OutputDirectory =
        Join-Path $temporaryRoot 'duplicate-private-reference-admission'
    Assert-TestFailure `
        -Operation { & $assembler @duplicatePrivateArguments } `
        -ExpectedMessage 'references must be distinct' `
        -Context 'duplicate private estate evidence reference'
    if ([IO.Directory]::Exists(
            [string]$duplicatePrivateArguments.OutputDirectory)) {
        throw 'Rejected duplicate private reference left an admission bundle.'
    }

    $systemReferenceReuseIndexPath =
        Join-Path $temporaryRoot 'system-reference-reuse-index'
    New-TestTamperedPrivateControlIndex `
        -SourceDirectory $privateControlIndexPath `
        -DestinationDirectory $systemReferenceReuseIndexPath `
        -Mutation {
            param($record)
            $record.controls[0].reference = $admissionReference
        }
    $systemReferenceReuseArguments = $arguments.Clone()
    $systemReferenceReuseArguments.PrivateControlIndexDirectory =
        $systemReferenceReuseIndexPath
    $systemReferenceReuseArguments.OutputDirectory =
        Join-Path $temporaryRoot 'system-reference-reuse-assembly'
    Assert-TestFailure `
        -Operation { & $assembler @systemReferenceReuseArguments } `
        -ExpectedMessage 'must not reuse an index or admission reference' `
        -Context 'assembled private and system evidence reference reuse'
    if ([IO.Directory]::Exists(
            [string]$systemReferenceReuseArguments.OutputDirectory)) {
        throw 'Rejected system-reference reuse left an admission bundle.'
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
                -ExpectedAdmissionEvidenceReference $admissionReference `
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
