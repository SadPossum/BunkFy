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
            $record['publicOrigin'] = $Origin.GetLeftPart([UriPartial]::Authority)
            $record['releaseId'] = $ReleaseId
            $record['transport'] = 'loopback-http-fixture'
            $record['result'] = 'passed'
            $record['workspaceId'] = [Guid]::NewGuid().ToString('D')
            $record['observedDataClassKey'] = 'raw-source-evidence'
            $record['catalogueCount'] = 2
            $record['schedules'] = @()
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
        AdapterHost = Join-Path $temporaryRoot 'adapter-host.json'
        Retention = Join-Path $temporaryRoot 'retention.json'
    }
    New-TestProbeEvidence -Path $probePaths.PublicEdge -SpecificationName public-edge -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.AdminAllowed -SpecificationName admin-allowed -Origin $origin -ReleaseId $candidateRelease -EvidenceSetId $adminSetId
    New-TestProbeEvidence -Path $probePaths.AdminDenied -SpecificationName admin-denied -Origin $origin -ReleaseId $candidateRelease -EvidenceSetId $adminSetId
    New-TestProbeEvidence -Path $probePaths.Invitation -SpecificationName workspace-invitation -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.Enrollment -SpecificationName workspace-enrollment -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.Notifications -SpecificationName operations-notifications -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.AdapterHost -SpecificationName adapter-host -Origin $origin -ReleaseId $candidateRelease
    New-TestProbeEvidence -Path $probePaths.Retention -SpecificationName retention -Origin $origin -ReleaseId $candidateRelease

    $output = Join-Path $temporaryRoot 'admission'
    $arguments = @{
        PublicOrigin = $origin
        CandidatePromotionDirectory = $candidatePromotionPath
        CandidateReleaseId = $candidateRelease
        CandidateSourceCommit = $candidateSource
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
        AdapterHostEvidencePath = $probePaths.AdapterHost
        RetentionEvidencePath = $probePaths.Retention
        BrowserRehearsalReference = 'record:BROWSER-123'
        HostedRecoveryReference = 'record:RECOVERY-123'
        DeploymentControlReference = 'record:DEPLOY-123'
        RuntimeOperationsReference = 'record:RUNTIME-123'
        OutputDirectory = $output
        AllowFixtureEvidence = $true
        PassThru = $true
    }
    $assembled = & $assembler @arguments
    $verified = & $verifier `
        -AdmissionDirectory $output `
        -ExpectedPublicOrigin $origin `
        -ExpectedReleaseId $candidateRelease `
        -ExpectedSourceCommit $candidateSource `
        -AllowFixtureEvidence `
        -PassThru
    $closed = Get-BunkFyClosedChecksumSet -Directory $output -MaximumPayloadBytes 2MB -Context 'production admission fixture'
    if ($closed.Files.Count -ne 1 -or
        $assembled.AdmissionEvidenceReference -cne $verified.AdmissionEvidenceReference -or
        $verified.ReleaseId -cne $candidateRelease -or
        @($verified.Record.evidence).Count -ne 12 -or
        @($verified.Record.privateEvidence).Count -ne 4 -or
        @($verified.Record.checks).Count -ne 7) {
        throw 'Production admission fixture emitted invalid closed evidence.'
    }
    $serialized = [IO.File]::ReadAllText((Join-Path $output 'production-admission.json'))
    foreach ($forbidden in @('workspaceId', 'propertyId', 'inventoryUnitId', 'token', 'password', 'responseBody', 'rawHeaders')) {
        if ($serialized.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Production admission bundle retained forbidden source detail '$forbidden'."
        }
    }

    $tampered = Join-Path $temporaryRoot 'tampered-admission'
    Copy-Item -LiteralPath $output -Destination $tampered -Recurse
    [IO.File]::AppendAllText((Join-Path $tampered 'production-admission.json'), " ")
    Assert-TestFailure `
        -Operation {
            & $verifier -AdmissionDirectory $tampered -ExpectedPublicOrigin $origin -ExpectedReleaseId $candidateRelease -ExpectedSourceCommit $candidateSource -AllowFixtureEvidence
        } `
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

    Assert-TestFailure `
        -Operation {
            & $verifier -AdmissionDirectory $output -ExpectedPublicOrigin $origin -ExpectedReleaseId $candidateRelease -ExpectedSourceCommit $candidateSource
        } `
        -ExpectedMessage 'HTTPS' `
        -Context 'fixture evidence without explicit admission'
}
finally {
    if ([IO.Directory]::Exists($temporaryRoot)) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}

Write-Host 'BunkFy production admission fixture passed.'
