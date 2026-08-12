# Deployed Data Rights Access Export Verification

Status: implemented, fixture verified, and exact-release Preview verified
Date: 2026-08-12

Use `eng/operations/verify-deployed-data-rights-access-export.ps1` to prove one
small, complete Data Rights Access Export workflow against an exact deployed
release. The verifier creates one synthetic Guest, advances a
controller-initiated case through discovery, review, and approval, waits for
the Worker-generated export, downloads it through the protected API, and
archives the Guest.

The assured token must belong to one active member of the target workspace and
must be authorized for the selected property, Guests, and Data Rights. The
unassured token must represent the same operator in a session that does not
satisfy the destructive MFA/two-step requirement. The denied token must belong to an authenticated
nonmember. All three tokens must be distinct and are accepted as
`SecureString` parameters or through:

- `BUNKFY_SMOKE_DATA_RIGHTS_ASSURED_TOKEN`;
- `BUNKFY_SMOKE_DATA_RIGHTS_UNASSURED_TOKEN`; and
- `BUNKFY_SMOKE_DATA_RIGHTS_DENIED_TOKEN`.

For a self-contained Preview proof, use the onboarding umbrella. It creates
the three identities, activates Preview's engineering/example property policy,
keeps a fresh password session as the negative control, temporarily enrolls
TOTP for the assured session, and runs the child before either applicant joins
the workspace:

```powershell
./eng/operations/rehearse-preview-onboarding.ps1 `
  -PublicOrigin http://127.0.0.1:8080 `
  -ExpectedReleaseId '<exact-release-id>' `
  -EnvironmentPath /protected/bunkfy-preview/.env `
  -AllowLoopbackHttp `
  -IncludeDataRightsAccessExport `
  -Confirm:$false
```

For an independently prepared deployment:

```powershell
$assured = Read-Host 'Assured operator token' -AsSecureString
$unassured = Read-Host 'Unassured operator token' -AsSecureString
$denied = Read-Host 'Nonmember token' -AsSecureString

./eng/operations/verify-deployed-data-rights-access-export.ps1 `
  -PublicOrigin 'https://candidate.example' `
  -ExpectedReleaseId 'release-20260812-01' `
  -WorkspaceId '11111111-1111-4111-8111-111111111111' `
  -PropertyId '22222222-2222-4222-8222-222222222222' `
  -AssuredOperatorAccessToken $assured `
  -UnassuredOperatorAccessToken $unassured `
  -DeniedAccessToken $denied `
  -Confirm:$false
```

The verifier proves exact-subject discovery and selection, immutable approved
scope, idempotent export request replay, rejection of a second live artifact,
Worker convergence, `401 Security.InsufficientAuthentication` for the
unassured download, `403` for the nonmember, safe download headers, strict JSON
shape, bounded in-memory size, and stable bytes across two downloads. It
rechecks the release identity after the workflow.

Plaintext export bytes are never written to disk. The retained evidence has
only bounded counts, format and expiry summaries, named checks, cleanup state,
and fixed limitations. It excludes credentials, PII, response bodies, hashes,
and workspace, property, Guest, case, subject, and artifact identifiers. An
existing evidence file is rejected unless the operator explicitly supplies
`-Force`.

Guest archival is mandatory even after a later assertion fails. The encrypted
artifact and case history are not deleted immediately: the artifact remains
scheduled for configured expiry, and the case remains under the configured
lifecycle. This probe does not establish browser privacy-request behavior,
large or multi-subject export behavior, independent object-store/key custody,
or hosted-production approval.

## Preview Evidence

On 2026-08-12, all 18 child checks passed through the VPS Preview loopback edge
for exact release `preview-workspace-access-estate-651107f`. The artifact used
format version 1, contained one synthetic Guest record, was downloaded twice
with stable bytes, and retained a bounded 24-hour scheduled expiry. The child
evidence SHA-256 is
`5e03d355f26436960daa2fa4ab4f1a7bb4e3b815fd6f87f99cf3145c7e417f72`.

The enclosing 11-check rehearsal disabled temporary TOTP and revoked its
sessions, archived the Guest, removed both joined members, retired both
properties, archived the workspace, revoked remaining sessions, and purged the
Mailpit operator window. Its SHA-256 is
`987c87635a792b1f802133db23a525d9d5bcbe89a8ad79e63badeb61d69a7058`.

These ignored files are exact-release Preview composition evidence, not hosted
production evidence. Their loopback transport is accepted by the admission
parser only with the fixture allowance and cannot fill the final production
admission input.
