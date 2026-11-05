# Deployed Staff Employment Verification

Status: schema-v2 implementation and fixture verified; prior Preview proof historical
Date: 2026-08-13

Use `eng/operations/verify-deployed-staff-employment.ps1` to prove the
Staff-owned employment lifecycle against one exact deployed release. The
verifier creates one synthetic unlinked profile, updates it versionedly,
assigns one property, suspends and resumes it, and records terminal departure.
It then proves departure closed the current assignment while retaining its
history.

The operator token must belong to one active member of the target workspace and
must be authorized for the selected property and Staff operations. The denied
token must belong to a distinct authenticated nonmember. Both are accepted as
`SecureString` values or through:

- `BUNKFY_SMOKE_STAFF_OPERATOR_TOKEN`; and
- `BUNKFY_SMOKE_STAFF_DENIED_TOKEN`.

For a self-contained Preview proof, use the onboarding umbrella. It runs this
child before the invitation applicant joins the workspace, so that applicant
supplies the nonmember denial control:

```powershell
./eng/operations/rehearse-preview-onboarding.ps1 `
  -PublicOrigin http://127.0.0.1:8080 `
  -ExpectedReleaseId '<exact-release-id>' `
  -EnvironmentPath /protected/bunkfy-preview/.env `
  -AllowLoopbackHttp `
  -IncludeStaffEmployment `
  -Confirm:$false
```

For an independently prepared deployment:

```powershell
$operator = Read-Host 'Staff workflow operator token' -AsSecureString
$denied = Read-Host 'Staff workflow nonmember token' -AsSecureString

./eng/operations/verify-deployed-staff-employment.ps1 `
  -PublicOrigin 'https://candidate.example' `
  -ExpectedReleaseId 'release-20260813-01' `
  -WorkspaceId '11111111-1111-4111-8111-111111111111' `
  -PropertyId '22222222-2222-4222-8222-222222222222' `
  -OperatorAccessToken $operator `
  -DeniedAccessToken $denied `
  -Confirm:$false
```

The verifier proves:

1. exact release, active membership, and property preconditions;
2. fail-closed nonmember Staff-directory access;
3. minimal unlinked profile creation, stable replay, and conflicting
   operation-id rejection;
4. directory-safe and sensitive profile coherence without an Auth-subject
   link;
5. optimistic profile update, stable replay, conflicting reuse rejection, and
   stale-version rejection;
6. property assignment, stable replay, conflicting reuse rejection, and
   canonical/property-directory visibility;
7. suspension and resume with stable receipts while the assignment remains
   current;
8. terminal departure with stable replay and atomic assignment closure;
9. coherent active and departed directory filters; and
10. release identity continuity across the complete workflow.

The assignment call may briefly observe `Staff.PropertyUnavailable` while the
Staff-owned Properties projection converges. Only that exact condition is
retried, with the same operation id and bounded timeout. Every other failure is
terminal.

The child owns terminal cleanup even when a later assertion fails. Any created
synthetic profile must finish departed, with zero current assignments. The
Preview parent remains responsible for retiring the selected property and its
workspace.

Passing evidence is written atomically with private permissions under
`.tmp/deployment-probes` by default. Schema v2 contains release, admission, and
transport identity, bounded workflow summaries, 21 named checks, cleanup disposition, and fixed
limitations. It excludes credentials, personal data, response bodies,
identifiers, display labels, reasons, and effective dates. Existing evidence is
never replaced without explicit `-Force`.

The proof deliberately does not exercise browser Staff management, account
linking, membership or role lifecycle, governance, Data Rights, retention, or
contention at directory scale. One departed synthetic Staff record and its
closed assignment history remain for auditability. Loopback Preview output is
composition evidence only and cannot satisfy hosted-production admission.

## Preview Evidence

On 2026-08-13, all 21 child checks passed through the VPS Preview loopback edge
for exact release `preview-workspace-access-estate-651107f`. The synthetic Staff
profile finished departed, its one historical assignment was closed, no current
assignment remained, and suspension had preserved the assignment before resume.
The production-admission parser independently accepted the minimized child with
SHA-256
`1ddecd9a9e699855c554b7d72813dd4a8208aa0ee0dacfe3762f08954485c54a`.

The enclosing 10-check rehearsal removed both non-owner memberships, retired
both properties, archived the workspace, revoked all three identities' sessions,
and purged the Mailpit operator window. Its SHA-256 is
`fd776514b5d593b37609ccb33dc88f23471406aac8f7ee21b26f2ea29bb44a11`.
All four retained evidence files were written with mode `0600`, and the Staff
child contains no workspace, property, Staff, operation, label, reason, or date
coordinates.

These ignored files prove exact-release Preview composition, not hosted
production. Their loopback transport is accepted by the admission parser only
with the fixture allowance and cannot fill the final production-admission input.
