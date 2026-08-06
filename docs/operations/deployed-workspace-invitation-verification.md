# Deployed Workspace Invitation Verification

Status: implemented with a deterministic local fixture; deployed evidence pending
Date: 2026-08-06

## Goal

Provide a deployment-neutral, externally runnable proof that two distinct
authenticated accounts can complete BunkFy's recipient-bound Staff invitation
workflow through the public API and its real asynchronous module boundaries.
This is a composed-product operations check. It does not move onboarding,
identity, Staff, or access policy into GMA or into deployment code.

## Preconditions

Use a dedicated smoke applicant that does not already belong to the target
workspace. The owner must be allowed to manage Staff access. Supply two active
properties in that workspace:

- `AllowedPropertyId` is assigned by the invitation;
- `DeniedPropertyId` remains outside the applicant's scope; and
- the applicant account exposes `ApplicantEmail` as its active, verified
  address.

The verifier requires short-lived owner and applicant bearer tokens. Put them
in `BUNKFY_SMOKE_OWNER_TOKEN` and `BUNKFY_SMOKE_APPLICANT_TOKEN`, or enter them
through the secure prompts. Do not pass plaintext tokens on the command line.

## Run

The operation creates a real membership, Staff profile, and access assignment.
Review the target and confirmation prompt before running it:

```powershell
$env:BUNKFY_SMOKE_OWNER_TOKEN = '<short-lived-owner-token>'
$env:BUNKFY_SMOKE_APPLICANT_TOKEN = '<short-lived-applicant-token>'

./eng/operations/verify-deployed-workspace-invitation.ps1 `
  -PublicOrigin https://bunkfy.example/ `
  -WorkspaceId <workspace-id> `
  -AllowedPropertyId <assigned-property-id> `
  -DeniedPropertyId <unassigned-property-id> `
  -ApplicantEmail smoke-applicant@example.com

Remove-Item Env:BUNKFY_SMOKE_OWNER_TOKEN
Remove-Item Env:BUNKFY_SMOKE_APPLICANT_TOKEN
```

Use a dedicated smoke workspace or offboard the joined applicant through the
reviewed Staff access operation after retaining the result. The verifier does
not silently disable an account or destroy tenant data.

## Observable Contract

The check fails closed unless it observes all of the following:

- the applicant token belongs to a distinct account with the requested active,
  verified email and no existing target membership;
- the owner can resolve both target properties before mutation;
- invitation issuance preserves the recipient, fixed `front-desk` profile, and
  one-property plan;
- the applicant can preview, submit, and accept the invitation;
- the asynchronous workflow converges to one correlated Staff profile;
- the assigned profile allows property reads and reservation creation only at
  the selected property, while tenant-wide Staff management remains denied;
- the public property route returns `200` for the assigned property and `403`
  for the unassigned property; and
- same-subject replay returns the same application, membership, and Staff IDs.

An incomplete active invitation is revoked best-effort when the verifier fails
before acceptance. Once accepted, the durable membership and Staff record are
left intact for explicit review and offboarding.

## Evidence Boundary

Passing evidence is written atomically below ignored
`.tmp/deployment-probes` by default. It records the origin, workspace and
workflow object IDs, named checks, and explicit limitations. It excludes bearer
tokens, invitation secrets, email addresses, Auth subject IDs, response bodies,
and raw headers.

This API-level probe does not exercise browser rendering, registration, email
delivery, QR approval/rejection, notification delivery, adapters, restart, or
rollback. Those remain separate deployment slices, and this result must not be
presented as proof of them.

## Repository Verification

`eng/test-deployed-workspace-invitation.ps1` runs against a loopback fixture. It
proves the successful contract, evidence minimization, distinct-account guard,
and rejection when an out-of-scope property route incorrectly returns success.
It uses no Docker and does not contact a deployment.
