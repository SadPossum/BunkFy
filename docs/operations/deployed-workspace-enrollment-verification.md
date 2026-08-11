# Deployed Workspace Enrollment Verification

Status: implemented, fixture verified, and VPS-preview verified
Date: 2026-08-11

## Goal

Prove the deployment-facing behavior of BunkFy's reusable QR enrollment with
owner approval. The verifier exercises both rejection and approval through the
public API while preserving the established ownership boundaries: Organizations
owns claims and membership, Workspaces owns the Staff proposal and access plan,
Staff owns the durable profile, and AccessControl owns grants.

## Preconditions

Use a dedicated applicant account that does not belong to the target workspace.
Its requested email must be active and verified. The owner token must be able to
manage Staff access, and both supplied property IDs must identify active
properties in the workspace. The first property is assigned; the second proves
that property scope remains closed.

Provide short-lived bearer tokens through `BUNKFY_SMOKE_OWNER_TOKEN` and
`BUNKFY_SMOKE_APPLICANT_TOKEN`, or enter them through the secure prompts. Do not
put plaintext tokens on the command line.

## Run

This is a mutation-bearing operation. It creates two one-use enrollment sources,
rejects the first application, approves the second, and leaves the approved
membership and Staff profile for explicit review and offboarding:

```powershell
$env:BUNKFY_SMOKE_OWNER_TOKEN = '<short-lived-owner-token>'
$env:BUNKFY_SMOKE_APPLICANT_TOKEN = '<short-lived-applicant-token>'

./eng/operations/verify-deployed-workspace-enrollment.ps1 `
  -PublicOrigin https://bunkfy.example/ `
  -ExpectedReleaseId <promotion-record-release-id> `
  -WorkspaceId <workspace-id> `
  -AllowedPropertyId <assigned-property-id> `
  -DeniedPropertyId <unassigned-property-id> `
  -ApplicantEmail smoke-applicant@example.com

Remove-Item Env:BUNKFY_SMOKE_OWNER_TOKEN
Remove-Item Env:BUNKFY_SMOKE_APPLICANT_TOKEN
```

Use a dedicated smoke workspace or offboard the approved identity after the
result is retained. The verifier never silently disables an Auth account or
destroys tenant data.

## Observable Contract

The verifier fails closed unless it observes:

- public `/api/smoke` reports the expected release before and after the workflow;
- an approval-required, one-use source with the fixed `front-desk` profile and
  one-property plan;
- a pending claim with no membership and a `403` property read;
- owner queue visibility and a terminal rejection that remains denied on replay;
- explicit disablement of the rejected source;
- a second pending claim followed by owner approval;
- convergence to one correlated Staff profile and exactly one membership;
- allowed property and reservation operations only at the assigned property,
  with tenant-wide Staff management and the other property denied;
- an owner-visible access assignment matching the QR plan;
- stable application, claim, membership, and Staff identities on replay; and
- capacity closure of the approved one-use source.

Any still-active source is disabled best-effort when the operation fails. An
already approved membership is retained for explicit review and offboarding.

## Evidence Boundary

Passing evidence is written atomically below ignored
`.tmp/deployment-probes` by default. It contains the release identity, workflow
object IDs, nine named checks, and limitations. It excludes bearer tokens,
enrollment secrets, email addresses, Auth subject IDs, response bodies, and raw
headers.

The probe exercises API behavior, not QR rendering, browser redirects,
registration, email delivery, notifications, adapters, restart, or rollback.
Those remain separate deployment checks.

## VPS Preview Evidence

On 2026-08-11, the verifier passed all nine checks through the VPS Preview's
trusted HTTPS origin for release `preview-runtime-hardening-20260811`. The
production-admission parser independently accepted the child record with
SHA-256
`9feb999cb339dff0aff6e0a7e8aceb088728b73f89f13347d179d3632e4904b5`.

The enclosing onboarding rehearsal removed both joined memberships, retired
its two synthetic properties, archived the synthetic workspace, revoked all
three sessions, and purged and closed the loopback Mailpit operator window.
The evidence is retained only in the ignored VPS working state; it is not
committed release evidence and does not admit the final `f27ce996` candidate.
Browser QR rendering, registration redirects, and real-provider email delivery
remain separate proofs.

## Repository Verification

`eng/test-deployed-workspace-enrollment.ps1` runs the complete rejection and
approval sequence against a loopback fixture. It also proves that passing
evidence is not written if an applicant can read a property before owner
approval. The fixture uses no Docker and does not contact a deployment.
