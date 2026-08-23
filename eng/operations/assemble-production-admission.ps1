[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][Uri] $PublicOrigin,
    [Parameter(Mandatory = $true)][string] $CandidatePromotionDirectory,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $CandidateReleaseId,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $CandidateSourceCommit,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^admission:[0-9a-f]{32}$')]
    [string] $AdmissionEvidenceReference,
    [Parameter(Mandatory = $true)][string] $RollbackPromotionDirectory,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{2,127}$')]
    [string] $RollbackReleaseId,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $RollbackSourceCommit,
    [Parameter(Mandatory = $true)][string] $RollbackRehearsalDirectory,
    [Parameter(Mandatory = $true)][string] $MigrationRehearsalPath,
    [Parameter(Mandatory = $true)][string] $PublicEdgeEvidencePath,
    [Parameter(Mandatory = $true)][string] $AdminAllowedEvidencePath,
    [Parameter(Mandatory = $true)][string] $AdminDeniedEvidencePath,
    [Parameter(Mandatory = $true)][string] $WorkspaceInvitationEvidencePath,
    [Parameter(Mandatory = $true)][string] $WorkspaceEnrollmentEvidencePath,
    [Parameter(Mandatory = $true)][string] $OperationsNotificationsEvidencePath,
    [Parameter(Mandatory = $true)][string] $ReservationsInventoryEvidencePath,
    [Parameter(Mandatory = $true)][string] $GuestsStayHistoryEvidencePath,
    [Parameter(Mandatory = $true)][string] $StaffEmploymentEvidencePath,
    [Parameter(Mandatory = $true)][string] $PropertiesTopologyEvidencePath,
    [Parameter(Mandatory = $true)][string] $IngestionConnectionLifecycleEvidencePath,
    [Parameter(Mandatory = $true)][string] $IngestionConflictProposalLifecycleEvidencePath,
    [Parameter(Mandatory = $true)][string] $DataRightsAccessExportEvidencePath,
    [Parameter(Mandatory = $true)][string] $AdapterHostEvidencePath,
    [Parameter(Mandatory = $true)][string] $RetentionEvidencePath,
    [Parameter(Mandatory = $true)][string] $BrowserRehearsalReference,
    [Parameter(Mandatory = $true)][string] $HostedRecoveryReference,
    [Parameter(Mandatory = $true)][string] $DeploymentControlReference,
    [Parameter(Mandatory = $true)][string] $RuntimeOperationsReference,
    [Parameter(Mandatory = $true)][string] $WorkspaceAccessEstateReference,
    [string] $OutputDirectory,
    [switch] $AllowFixtureEvidence,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common.ps1')
. (Join-Path $PSScriptRoot '..\production-admission.common.ps1')

$root = Get-BunkFyRepositoryRoot
$origin = Assert-BunkFyPublicEdgeOrigin `
    -Origin $PublicOrigin `
    -AllowLoopbackHttp:$AllowFixtureEvidence
if ($AllowFixtureEvidence -and -not (Test-BunkFyLoopbackHost -HostName $origin.Host)) {
    throw 'Fixture admission evidence is restricted to an explicit loopback origin.'
}
if ($CandidateReleaseId -ceq $RollbackReleaseId -or
    $CandidateSourceCommit -ceq $RollbackSourceCommit) {
    throw 'Candidate and rollback identities must be distinct.'
}
$admissionId = [Guid]::Empty
if (-not [Guid]::TryParseExact(
        $AdmissionEvidenceReference.Substring(10),
        'N',
        [ref]$admissionId) -or
    $admissionId -eq [Guid]::Empty) {
    throw 'AdmissionEvidenceReference must contain a non-empty admission identity.'
}

$candidatePromotion = Get-BunkFyVerifiedImagePromotion `
    -PromotionDirectory $CandidatePromotionDirectory `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedSourceCommit $CandidateSourceCommit `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$rollbackPromotion = Get-BunkFyVerifiedImagePromotion `
    -PromotionDirectory $RollbackPromotionDirectory `
    -ExpectedReleaseId $RollbackReleaseId `
    -ExpectedSourceCommit $RollbackSourceCommit `
    -AllowFixtureEvidence:$AllowFixtureEvidence
foreach ($name in @('backend', 'web')) {
    $candidateImage = @($candidatePromotion.Images | Where-Object Name -CEQ $name)
    $rollbackImage = @($rollbackPromotion.Images | Where-Object Name -CEQ $name)
    if ($candidateImage.Count -ne 1 -or
        $rollbackImage.Count -ne 1 -or
        $candidateImage[0].Repository -cne $rollbackImage[0].Repository) {
        throw "Candidate and rollback promotions must use the same '$name' repository."
    }
}

$rollbackRehearsal = Get-BunkFyVerifiedDeployedRollbackRehearsal `
    -Directory $RollbackRehearsalDirectory `
    -ExpectedOrigin $origin `
    -CandidatePromotion $candidatePromotion `
    -RollbackPromotion $rollbackPromotion `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$candidateBackend = @($candidatePromotion.Images | Where-Object Name -CEQ 'backend')
$migration = Get-BunkFyVerifiedProductionMigrationRehearsal `
    -Path $MigrationRehearsalPath `
    -ExpectedSourceCommit $CandidateSourceCommit `
    -ExpectedBackendDigest $candidateBackend[0].ManifestDigest

$publicEdge = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $PublicEdgeEvidencePath `
    -SpecificationName 'public-edge' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$adminAllowed = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $AdminAllowedEvidencePath `
    -SpecificationName 'admin-allowed' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$adminDenied = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $AdminDeniedEvidencePath `
    -SpecificationName 'admin-denied' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
if ($adminAllowed.Path -ceq $adminDenied.Path -or
    $adminAllowed.Record.evidenceSetId -cne $adminDenied.Record.evidenceSetId -or
    $adminAllowed.Record.adminOrigin -cne $adminDenied.Record.adminOrigin) {
    throw 'Allowed and denied Admin evidence must be a matched, distinct vantage-point pair.'
}

$invitation = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $WorkspaceInvitationEvidencePath `
    -SpecificationName 'workspace-invitation' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$enrollment = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $WorkspaceEnrollmentEvidencePath `
    -SpecificationName 'workspace-enrollment' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$notifications = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $OperationsNotificationsEvidencePath `
    -SpecificationName 'operations-notifications' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$reservationsInventory = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $ReservationsInventoryEvidencePath `
    -SpecificationName 'reservations-inventory' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$guestsStayHistory = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $GuestsStayHistoryEvidencePath `
    -SpecificationName 'guests-stay-history' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$staffEmployment = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $StaffEmploymentEvidencePath `
    -SpecificationName 'staff-employment' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$propertiesTopology = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $PropertiesTopologyEvidencePath `
    -SpecificationName 'properties-topology' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$ingestionConnectionLifecycle = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $IngestionConnectionLifecycleEvidencePath `
    -SpecificationName 'ingestion-connection-lifecycle' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$ingestionConflictProposalLifecycle = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $IngestionConflictProposalLifecycleEvidencePath `
    -SpecificationName 'ingestion-conflict-proposal-lifecycle' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$dataRightsAccessExport = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $DataRightsAccessExportEvidencePath `
    -SpecificationName 'data-rights-access-export' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$adapterHost = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $AdapterHostEvidencePath `
    -SpecificationName 'adapter-host' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
$retention = Get-BunkFyVerifiedProductionAdmissionProbe `
    -Path $RetentionEvidencePath `
    -SpecificationName 'retention' `
    -ExpectedOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence

$privateReferences = [ordered]@{
    'browser-workspace-onboarding' = Assert-BunkFyProductionAdmissionReference -Value $BrowserRehearsalReference -Name 'BrowserRehearsalReference'
    'deployment-approval-alerting-and-rollback' = Assert-BunkFyProductionAdmissionReference -Value $DeploymentControlReference -Name 'DeploymentControlReference'
    'hosted-backup-and-recovery' = Assert-BunkFyProductionAdmissionReference -Value $HostedRecoveryReference -Name 'HostedRecoveryReference'
    'runtime-topology-restart-and-credential-rotation' = Assert-BunkFyProductionAdmissionReference -Value $RuntimeOperationsReference -Name 'RuntimeOperationsReference'
    'workspace-access-seed-estate' = Assert-BunkFyProductionAdmissionReference -Value $WorkspaceAccessEstateReference -Name 'WorkspaceAccessEstateReference'
}
$_seenPrivateReferences = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($reference in $privateReferences.Values) {
    if (-not $_seenPrivateReferences.Add($reference)) {
        throw 'Each private production control must use a distinct evidence reference.'
    }
}
$systemEvidenceReferences = @(
    $AdmissionEvidenceReference,
    $candidatePromotion.PromotionEvidenceReference,
    $rollbackPromotion.PromotionEvidenceReference,
    $rollbackRehearsal.Reference,
    $migration.Reference)
foreach ($reference in $privateReferences.Values) {
    if ($systemEvidenceReferences -ccontains $reference) {
        throw 'Private production controls must not reuse a system evidence reference.'
    }
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $OutputDirectory = Join-BunkFyPath (
        ".tmp/production-admission/$stamp-$([Guid]::NewGuid().ToString('N'))")
}
$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory, $root)
if ([IO.Directory]::Exists($resolvedOutputDirectory) -or
    [IO.File]::Exists($resolvedOutputDirectory)) {
    throw "Production admission output already exists: '$resolvedOutputDirectory'."
}
foreach ($directory in @(
        $candidatePromotion.Directory,
        $rollbackPromotion.Directory,
        $rollbackRehearsal.Directory)) {
    Assert-BunkFyDisjointPromotionPaths `
        -LeftPath $directory `
        -LeftName 'source evidence' `
        -RightPath $resolvedOutputDirectory `
        -RightName 'production admission output'
}
$outputPrefix = $resolvedOutputDirectory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$sourceFiles = @(
    $migration.Path,
    $publicEdge.Path,
    $adminAllowed.Path,
    $adminDenied.Path,
    $invitation.Path,
    $enrollment.Path,
    $notifications.Path,
    $reservationsInventory.Path,
    $guestsStayHistory.Path,
    $staffEmployment.Path,
    $propertiesTopology.Path,
    $ingestionConnectionLifecycle.Path,
    $ingestionConflictProposalLifecycle.Path,
    $dataRightsAccessExport.Path,
    $adapterHost.Path,
    $retention.Path)
foreach ($path in $sourceFiles) {
    if ($path.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Production admission output must not contain source evidence.'
    }
}
if (@($sourceFiles | Sort-Object -Unique).Count -ne $sourceFiles.Count) {
    throw 'Each file-backed production proof must use a distinct evidence file.'
}

function New-BunkFyProductionAdmissionEvidenceSummary {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $EvidenceKind,
        [Parameter(Mandatory = $true)][string] $EvidenceReference,
        [Parameter(Mandatory = $true)][string] $BoundReleaseId,
        [Parameter(Mandatory = $true)][string] $SourceSha256,
        [Parameter(Mandatory = $true)][DateTimeOffset] $ObservedAtUtc,
        [Parameter(Mandatory = $true)][int] $ProofCount
    )

    return [ordered]@{
        name = $Name
        evidenceKind = $EvidenceKind
        evidenceReference = $EvidenceReference
        boundReleaseId = $BoundReleaseId
        sourceSha256 = $SourceSha256
        observedAtUtc = $ObservedAtUtc.ToUniversalTime().ToString('O')
        proofCount = $ProofCount
    }
}

$sourceEvidence = [Collections.Generic.List[object]]::new()
$sourceEvidence.Add((New-BunkFyProductionAdmissionEvidenceSummary `
            -Name 'candidate-image-promotion' `
            -EvidenceKind 'bunkfy-image-promotion' `
            -EvidenceReference $candidatePromotion.PromotionEvidenceReference `
            -BoundReleaseId $CandidateReleaseId `
            -SourceSha256 $candidatePromotion.ChecksumsSha256 `
            -ObservedAtUtc $candidatePromotion.GeneratedAtUtc `
            -ProofCount 2))
$sourceEvidence.Add((New-BunkFyProductionAdmissionEvidenceSummary `
            -Name 'rollback-image-promotion' `
            -EvidenceKind 'bunkfy-image-promotion' `
            -EvidenceReference $rollbackPromotion.PromotionEvidenceReference `
            -BoundReleaseId $RollbackReleaseId `
            -SourceSha256 $rollbackPromotion.ChecksumsSha256 `
            -ObservedAtUtc $rollbackPromotion.GeneratedAtUtc `
            -ProofCount 2))
$sourceEvidence.Add((New-BunkFyProductionAdmissionEvidenceSummary `
            -Name $rollbackRehearsal.Name `
            -EvidenceKind $rollbackRehearsal.EvidenceKind `
            -EvidenceReference $rollbackRehearsal.Reference `
            -BoundReleaseId $CandidateReleaseId `
            -SourceSha256 $rollbackRehearsal.SourceSha256 `
            -ObservedAtUtc $rollbackRehearsal.GeneratedAtUtc `
            -ProofCount $rollbackRehearsal.CheckCount))
$sourceEvidence.Add((New-BunkFyProductionAdmissionEvidenceSummary `
            -Name $migration.Name `
            -EvidenceKind $migration.EvidenceKind `
            -EvidenceReference $migration.Reference `
            -BoundReleaseId $CandidateReleaseId `
            -SourceSha256 $migration.SourceSha256 `
            -ObservedAtUtc $migration.GeneratedAtUtc `
            -ProofCount $migration.CheckCount))
foreach ($entry in @(
        [pscustomobject]@{ Name = 'deployed-public-edge'; Value = $publicEdge },
        [pscustomobject]@{ Name = 'deployed-admin-allowed'; Value = $adminAllowed },
        [pscustomobject]@{ Name = 'deployed-admin-denied'; Value = $adminDenied },
        [pscustomobject]@{ Name = 'deployed-workspace-invitation'; Value = $invitation },
        [pscustomobject]@{ Name = 'deployed-workspace-enrollment'; Value = $enrollment },
        [pscustomobject]@{ Name = 'deployed-operations-notifications'; Value = $notifications },
        [pscustomobject]@{ Name = 'deployed-reservations-inventory'; Value = $reservationsInventory },
        [pscustomobject]@{ Name = 'deployed-guests-stay-history'; Value = $guestsStayHistory },
        [pscustomobject]@{ Name = 'deployed-staff-employment'; Value = $staffEmployment },
        [pscustomobject]@{ Name = 'deployed-properties-topology'; Value = $propertiesTopology },
        [pscustomobject]@{ Name = 'deployed-ingestion-connection-lifecycle'; Value = $ingestionConnectionLifecycle },
        [pscustomobject]@{ Name = 'deployed-ingestion-conflict-proposal-lifecycle'; Value = $ingestionConflictProposalLifecycle },
        [pscustomobject]@{ Name = 'deployed-data-rights-access-export'; Value = $dataRightsAccessExport },
        [pscustomobject]@{ Name = 'deployed-adapter-host'; Value = $adapterHost },
        [pscustomobject]@{ Name = 'deployed-retention'; Value = $retention })) {
    $sourceEvidence.Add((New-BunkFyProductionAdmissionEvidenceSummary `
            -Name $entry.Name `
            -EvidenceKind $entry.Value.EvidenceKind `
            -EvidenceReference $entry.Value.Reference `
            -BoundReleaseId $CandidateReleaseId `
            -SourceSha256 $entry.Value.SourceSha256 `
            -ObservedAtUtc $entry.Value.GeneratedAtUtc `
            -ProofCount $entry.Value.CheckCount))
}

$generatedAtUtc = [DateTimeOffset]::UtcNow
$mutableEvidenceTimes = [Collections.Generic.List[DateTimeOffset]]::new()
foreach ($entry in @($sourceEvidence | Where-Object {
            $_.name.StartsWith('deployed-', [StringComparison]::Ordinal)
        })) {
    $observedAtUtc = ConvertTo-BunkFyProductionAdmissionTimestamp `
        -Value $entry.observedAtUtc `
        -Context "admission source '$($entry.name)' observation time"
    [void](Assert-BunkFyProductionAdmissionMutableEvidenceFreshness `
            -Timestamp $observedAtUtc `
            -EvaluationTimeUtc $generatedAtUtc `
            -Context "admission source '$($entry.name)'")
    $mutableEvidenceTimes.Add($observedAtUtc)
}
if ($mutableEvidenceTimes.Count -eq 0) {
    throw 'Production admission requires mutable runtime evidence.'
}
$orderedMutableEvidenceTimes = @($mutableEvidenceTimes | Sort-Object)
$oldestMutableEvidenceAtUtc = $orderedMutableEvidenceTimes[0]
$newestMutableEvidenceAtUtc = $orderedMutableEvidenceTimes[-1]
$expiresAtUtc = Get-BunkFyProductionAdmissionExpiry `
    -GeneratedAtUtc $generatedAtUtc `
    -OldestMutableEvidenceAtUtc $oldestMutableEvidenceAtUtc

$record = [ordered]@{
    schemaVersion = 2
    evidenceKind = 'bunkfy-production-admission-bundle'
    admissionId = $admissionId.ToString('D')
    admissionEvidenceReference = $AdmissionEvidenceReference
    generatedAtUtc = $generatedAtUtc.ToString('O')
    result = 'passed'
    decision = 'evidence-complete-awaiting-private-approval'
    repository = 'SadPossum/BunkFy'
    profile = if ($AllowFixtureEvidence) { 'loopback-fixture' } else { 'production' }
    candidate = ConvertTo-BunkFyProductionAdmissionPromotionSummary $candidatePromotion
    rollback = ConvertTo-BunkFyProductionAdmissionPromotionSummary $rollbackPromotion
    deployment = [ordered]@{
        publicOrigin = $origin.GetLeftPart([UriPartial]::Authority)
        rollbackEvidenceReference = $rollbackRehearsal.Reference
        rollbackEvidenceSha256 = $rollbackRehearsal.SourceSha256
        migrationEvidenceReference = $migration.Reference
        migrationEvidenceSha256 = $migration.SourceSha256
        adminEvidenceSetId = [string]$adminAllowed.Record.evidenceSetId
    }
    validity = [ordered]@{
        policy = $script:BunkFyProductionAdmissionFreshnessPolicy
        mutableEvidenceMaximumAgeMinutes = [int](
            $script:BunkFyProductionAdmissionMutableEvidenceMaximumAge.TotalMinutes)
        approvalWindowMinutes = [int](
            $script:BunkFyProductionAdmissionApprovalWindow.TotalMinutes)
        clockSkewSeconds = [int](
            $script:BunkFyProductionAdmissionClockSkew.TotalSeconds)
        oldestMutableEvidenceAtUtc =
            $oldestMutableEvidenceAtUtc.ToString('O')
        newestMutableEvidenceAtUtc =
            $newestMutableEvidenceAtUtc.ToString('O')
        expiresAtUtc = $expiresAtUtc.ToString('O')
    }
    evidence = @($sourceEvidence | Sort-Object { $_.name })
    privateEvidence = @($privateReferences.GetEnumerator() | Sort-Object Key | ForEach-Object {
            [ordered]@{
                control = $_.Key
                reference = $_.Value
            }
        })
    checks = @($script:BunkFyProductionAdmissionChecks | ForEach-Object {
            [ordered]@{ name = $_; status = 'passed' }
        })
    limitations = $script:BunkFyProductionAdmissionLimitations
}

$stagingDirectory = "$resolvedOutputDirectory.tmp-$([Guid]::NewGuid().ToString('N'))"
try {
    [IO.Directory]::CreateDirectory($stagingDirectory) | Out-Null
    $recordPath = Join-Path $stagingDirectory 'production-admission.json'
    Write-BunkFyCandidateJson -Path $recordPath -Value $record
    $recordHash = (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $stagingDirectory 'checksums.sha256'),
        "$recordHash  production-admission.json`n",
        [Text.UTF8Encoding]::new($false))
    [void](Get-BunkFyVerifiedProductionAdmission `
            -Directory $stagingDirectory `
            -ExpectedPublicOrigin $origin `
            -ExpectedReleaseId $CandidateReleaseId `
            -ExpectedSourceCommit $CandidateSourceCommit `
            -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
            -AllowFixtureEvidence:$AllowFixtureEvidence)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $resolvedOutputDirectory)) |
        Out-Null
    [IO.Directory]::Move($stagingDirectory, $resolvedOutputDirectory)
}
finally {
    if ([IO.Directory]::Exists($stagingDirectory)) {
        [IO.Directory]::Delete($stagingDirectory, $true)
    }
}

$verified = Get-BunkFyVerifiedProductionAdmission `
    -Directory $resolvedOutputDirectory `
    -ExpectedPublicOrigin $origin `
    -ExpectedReleaseId $CandidateReleaseId `
    -ExpectedSourceCommit $CandidateSourceCommit `
    -ExpectedAdmissionEvidenceReference $AdmissionEvidenceReference `
    -AllowFixtureEvidence:$AllowFixtureEvidence
if ($PassThru) {
    return $verified
}
Write-Host "BunkFy production admission evidence is complete for '$CandidateReleaseId'."
Write-Host "Evidence: $resolvedOutputDirectory"
Write-Host "Admission evidence reference: $($verified.AdmissionEvidenceReference)"
Write-Host "Approval evidence expires at $($verified.ExpiresAtUtc.ToString('O'))."
