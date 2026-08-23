# Production Admission Evidence

Preallocate one unique admission evidence identity before starting the exact
candidate, then use this final repository boundary after it has passed image
promotion, migration rehearsal, deployed rollback rehearsal, public/Admin edge
verification, and the release-bound domain probes. It assembles one small,
closed record under that same identity for private release approval; it does
not approve or deploy the candidate.

## Preallocate

Before candidate startup, create one fresh identity, retain it in the private
release record, and set `BunkFy:Deployment:AdmissionEvidenceReference` to it on
Public API, Admin API, and Worker:

```powershell
$admissionReference = "admission:$([Guid]::NewGuid().ToString('N'))"
```

Do not reuse an identity across admission attempts. The hosts validate and log
the identity but cannot prove that its final bundle will later be closed or
approved.

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
  [Reservations and Inventory lifecycle](deployed-reservations-inventory-verification.md),
  [Guests stay history](deployed-guests-stay-history-verification.md),
  [Staff employment](deployed-staff-employment-verification.md),
  [Properties topology](deployed-properties-topology-verification.md),
  [Ingestion connection lifecycle](deployed-ingestion-connection-lifecycle-verification.md),
  [Ingestion conflict and proposal lifecycle](deployed-ingestion-conflict-proposal-lifecycle-verification.md),
  [Data Rights Access Export](deployed-data-rights-access-export-verification.md),
  [AdapterHost](deployed-adapter-host-verification.md), and
  [Retention](deployed-retention-verification.md) results.

Every mutable deployed proof must report the candidate release, public origin,
and exact preallocated `admissionEvidenceReference`. The value must remain
stable throughout each workflow and match across every probe and the rollback
rehearsal; same-release evidence from another attempt is rejected. The
migration rehearsal source commit and backend digest must match the promoted
candidate. The rollback rehearsal must bind both supplied promotion records.
Every deployed probe and rollback rehearsal must be no more than 24 hours old
when assembled and whenever the closed bundle is verified. Promotion and
migration evidence are immutable candidate proof and do not expire only because
of age. This binding supersedes the earlier unbound schemas: public edge is v4;
Operations Notifications, Reservations and Inventory, and Retention are v3;
the rollback rehearsal and the other deployed probes are v2.
The Preview onboarding rehearsal's opt-in
`*.operations-notifications.json` child is a standalone Operations
Notifications proof. Schema v3 omits workspace, property, Inventory, block,
notification, date-range, and stream-sequence coordinates while retaining
closed delivery and cleanup semantics. A trusted-HTTPS child may be supplied
directly; use the child file, not the onboarding umbrella, for
`OperationsNotificationsEvidencePath`.
The matching opt-in `*.reservations-inventory.json` child is a standalone
Reservations and Inventory lifecycle proof. Schema v3 omits tenant and domain
coordinates, dates, identities, labels, and payloads while retaining closed
direct-booking, allocation, occupancy, replay, and terminal-cleanup semantics.
A trusted-HTTPS child may be supplied directly for
`ReservationsInventoryEvidencePath`.
The matching opt-in `*.guests-stay-history.json` child is a standalone durable
Guest, Reservation link, and Guests-owned stay-history proof and may be supplied
directly for `GuestsStayHistoryEvidencePath`.
The matching opt-in `*.staff-employment.json` child is a standalone unlinked
Staff profile, assignment, and lifecycle proof and may be supplied directly for
`StaffEmploymentEvidencePath`.
The matching opt-in `*.properties-topology.json` child is a standalone
Properties mutation, topology, and coordinated-retirement proof and may be
supplied directly for `PropertiesTopologyEvidencePath`. It does not prove a
country-policy choice or approval.
The matching opt-in `*.ingestion-connection-lifecycle.json` child is a
standalone Ingestion control-plane, one-time credential, independent adapter
authentication, revocation, and terminal-disable proof and may be supplied
directly for `IngestionConnectionLifecycleEvidencePath`. It requires an already
approved processing policy and does not prove that policy decision or a real
provider record.
The matching opt-in `*.ingestion-conflict-proposal-lifecycle.json` child is a
standalone Ingestion reservation-authority, proposal-supersession, decision,
and terminal-cleanup proof and may be supplied directly for
`IngestionConflictProposalLifecycleEvidencePath`. It does not prove provider
acquisition, parser correctness, or a production country-policy decision.
The matching opt-in `*.data-rights-access-export.json` child is a standalone
Data Rights proof and may be supplied directly for
`DataRightsAccessExportEvidencePath`. It proves deployed protected export
behavior but not browser privacy-request UX, independent object-store/key
custody, or immediate artifact deletion.
Loopback Preview output remains rehearsal evidence and is rejected by the
production parser unless its test-only fixture allowance is explicitly used;
it cannot satisfy the hosted admission input.
Its Preview engineering/example country-policy binding proves runtime contract
composition only. It cannot satisfy a production country approval, legal,
transfer, or retention-policy evidence requirement.

Also provide five non-secret references from the private release system:

- completed browser workspace-onboarding and registration rehearsal;
- hosted backup and recovery rehearsal;
- deployment approval, alert ownership, traffic handling, and rollback control;
- runtime topology, restart, and credential-rotation rehearsal; and
- the hosted Workspace Access seed estate for the exact candidate.

The Workspace Access estate record must bind the exact candidate/backend
artifact, complete authorized active-workspace enumeration, stable catalog
fingerprint, expected seed version and protected-profile count, final
convergence with zero legacy members, and any approved bootstrap outcome.
Tenant identity should be retained only as approved one-way fingerprints. The
Preview estate result explicitly marked `preview-deployment-only` cannot
satisfy this hosted control.

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
  AdmissionEvidenceReference = $admissionReference
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
  ReservationsInventoryEvidencePath = '/evidence/probes/reservations-inventory.json'
  GuestsStayHistoryEvidencePath = '/evidence/probes/guests-stay-history.json'
  StaffEmploymentEvidencePath = '/evidence/probes/staff-employment.json'
  PropertiesTopologyEvidencePath = '/evidence/probes/properties-topology.json'
  IngestionConnectionLifecycleEvidencePath = '/evidence/probes/ingestion-connection-lifecycle.json'
  IngestionConflictProposalLifecycleEvidencePath = '/evidence/probes/ingestion-conflict-proposal-lifecycle.json'
  DataRightsAccessExportEvidencePath = '/evidence/probes/data-rights-access-export.json'
  AdapterHostEvidencePath = '/evidence/probes/adapter-host.json'
  RetentionEvidencePath = '/evidence/probes/retention.json'
  BrowserRehearsalReference = 'record:BROWSER-123'
  HostedRecoveryReference = 'record:RECOVERY-123'
  DeploymentControlReference = 'record:DEPLOY-123'
  RuntimeOperationsReference = 'record:RUNTIME-123'
  WorkspaceAccessEstateReference = 'record:ACCESS-123'
  OutputDirectory = '/evidence/admission/release-20260806-02'
}

./eng/operations/assemble-production-admission.ps1 @admission
```

The command validates every input before creating output. It writes
`production-admission.json` plus `checksums.sha256` through a staging directory,
self-verifies the closed set, and then moves it into place atomically. Existing
output is never replaced. The assembler rejects an empty admission identity and
retains the caller-supplied identity exactly; it never substitutes a new one
after the candidate has been probed. It also rejects any mutable input whose
admission identity differs from that caller-supplied value.

The admission record contains release and image identities, evidence kinds,
timestamps, source references, check counts, SHA-256 bindings, bounded validity,
and the five private references. Admission schema v2 fixes the mutable-evidence
limit at 24 hours and the approval window at four hours. Its expiry is the
earlier of the approval-window end and the oldest mutable proof's 24-hour limit;
the record cannot enlarge those limits. Schema v1 admission bundles are
intentionally rejected and must be reassembled from current source evidence.
Private references must be distinct and
cannot reuse the admission, promotion, rollback, or migration identities. The
record does not copy workspace, property, Inventory, Reservation, Staff, guest,
Data Rights case/artifact, notification, adapter, or Retention coordinates from
source evidence.

## Verify And Approve

Verify the retained bundle again before private approval:

```powershell
./eng/verify-production-admission.ps1 `
  -AdmissionDirectory /evidence/admission/release-20260806-02 `
  -ExpectedPublicOrigin https://candidate.example `
  -ExpectedReleaseId release-20260806-02 `
  -ExpectedSourceCommit <candidate-root-commit> `
  -ExpectedAdmissionEvidenceReference $admissionReference
```

A passing record deliberately says `evidence-complete-awaiting-private-approval`.
The verifier independently recalculates repository parity, source checksum and
reference bindings, the mutable observation window, and expiry. If the bundle
expires before approval, abandon that attempt, allocate a new admission identity,
and rerun the mutable deployed probes and rollback rehearsal. The exact promotion
and migration evidence may be reused while their candidate identities still
match.

Its local checksum is not a signature, source clocks are not independently
attested, and the script does not inspect private records, registry policy after
promotion, production traffic, or production tenant data. Store or sign the
closed directory through the approved private release system, review those
remaining controls, and make the release decision there before `expiresAtUtc`.

`-AllowFixtureEvidence` exists only for the deterministic loopback repository
test. It cannot admit HTTP, unattested, or fixture evidence for a hosted origin.
