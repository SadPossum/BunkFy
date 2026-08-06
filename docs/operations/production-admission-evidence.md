# Production Admission Evidence

Use this final repository boundary after the exact candidate has passed image
promotion, migration rehearsal, deployed rollback rehearsal, public/Admin edge
verification, and the release-bound domain probes. It assembles one small,
closed record for private release approval; it does not approve or deploy the
candidate.

## Required Evidence

Provide the exact retained files or directories for:

- candidate and compatible rollback [image promotions](image-candidate-promotion.md);
- the candidate-to-rollback-to-candidate [deployed rehearsal](deployed-release-rollback-rehearsal.md);
- the candidate [Production migration rehearsal](production-migration-rehearsal.md);
- one current [public-edge](deployed-public-edge-verification.md) result;
- the matched allowed and denied [Admin boundary](deployed-admin-boundary-verification.md) pair;
- workspace [invitation](deployed-workspace-invitation-verification.md) and
  [QR enrollment](deployed-workspace-enrollment-verification.md) results;
- [Operations Notifications](deployed-operations-notifications-verification.md),
  [AdapterHost](deployed-adapter-host-verification.md), and
  [Retention](deployed-retention-verification.md) results.

Every deployed proof must report the candidate release and public origin. The
migration rehearsal source commit and backend digest must match the promoted
candidate. The rollback rehearsal must bind both supplied promotion records.

Also provide four non-secret references from the private release system:

- completed browser workspace-onboarding and registration rehearsal;
- hosted backup and recovery rehearsal;
- deployment approval, alert ownership, traffic handling, and rollback control;
- runtime topology, restart, and credential-rotation rehearsal.

Use bounded references such as `record:OPS-123`; never pass a URL containing a
token, credentials, personal data, or raw logs. The repository validates the
reference shape, not the private record's content or authenticity.

## Assemble

```powershell
$admission = @{
  PublicOrigin = 'https://candidate.example'
  CandidatePromotionDirectory = '/evidence/promotions/candidate'
  CandidateReleaseId = 'release-20260806-02'
  CandidateSourceCommit = '<candidate-root-commit>'
  RollbackPromotionDirectory = '/evidence/promotions/rollback'
  RollbackReleaseId = 'release-20260801-01'
  RollbackSourceCommit = '<rollback-root-commit>'
  RollbackRehearsalDirectory = '/evidence/rollback/release-20260806-02'
  MigrationRehearsalPath = '/evidence/migrations/candidate.json'
  PublicEdgeEvidencePath = '/evidence/probes/public-edge.json'
  AdminAllowedEvidencePath = '/evidence/probes/admin-allowed.json'
  AdminDeniedEvidencePath = '/evidence/probes/admin-denied.json'
  WorkspaceInvitationEvidencePath = '/evidence/probes/workspace-invitation.json'
  WorkspaceEnrollmentEvidencePath = '/evidence/probes/workspace-enrollment.json'
  OperationsNotificationsEvidencePath = '/evidence/probes/notifications.json'
  AdapterHostEvidencePath = '/evidence/probes/adapter-host.json'
  RetentionEvidencePath = '/evidence/probes/retention.json'
  BrowserRehearsalReference = 'record:BROWSER-123'
  HostedRecoveryReference = 'record:RECOVERY-123'
  DeploymentControlReference = 'record:DEPLOY-123'
  RuntimeOperationsReference = 'record:RUNTIME-123'
  OutputDirectory = '/evidence/admission/release-20260806-02'
}

./eng/operations/assemble-production-admission.ps1 @admission
```

The command validates every input before creating output. It writes
`production-admission.json` plus `checksums.sha256` through a staging directory,
self-verifies the closed set, and then moves it into place atomically. Existing
output is never replaced.

The admission record contains release and image identities, evidence kinds,
timestamps, check counts, SHA-256 bindings, and the four private references. It
does not copy workspace, property, Staff, guest, notification, adapter, or
Retention coordinates from source evidence.

## Verify And Approve

Verify the retained bundle again before private approval:

```powershell
./eng/verify-production-admission.ps1 `
  -AdmissionDirectory /evidence/admission/release-20260806-02 `
  -ExpectedPublicOrigin https://candidate.example `
  -ExpectedReleaseId release-20260806-02 `
  -ExpectedSourceCommit <candidate-root-commit>
```

A passing record deliberately says `evidence-complete-awaiting-private-approval`.
Its local checksum is not a signature, and the script does not inspect private
records, registry policy after promotion, production traffic, or production
tenant data. Store or sign the closed directory through the approved private
release system, review those remaining controls, and make the release decision
there.

`-AllowFixtureEvidence` exists only for the deterministic loopback repository
test. It cannot admit HTTP, unattested, or fixture evidence for a hosted origin.
