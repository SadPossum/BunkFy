# Deployed Workspace Browser Rehearsal

Use this rehearsal for the browser- and delivery-owned part of workspace
onboarding. It complements, but does not repeat or replace, the automated
[workspace invitation](deployed-workspace-invitation-verification.md) and
[workspace QR enrollment](deployed-workspace-enrollment-verification.md)
verifiers.

Run it against the exact candidate origin after the public-edge and API-level
verifiers pass. A local screenshot or repository test is not deployment
evidence for mail delivery, an external identity provider, process restart, or
redirect behavior.

## Preconditions

Record these in the private release evidence before starting:

- public HTTPS origin, source commit, immutable image identities, and UTC start;
- one owner account and two clean applicant accounts controlled for the browser
  rehearsal; the API verifiers use separate dedicated applicants unless the
  smoke environment is reset between phases;
- one target workspace with two active properties and a low-privilege Staff
  profile that can be delegated to one property;
- the enabled registration methods and their exact deployment configuration;
- the mail-provider or identity-provider evidence surface; and
- the operator and approved way to stop and start the candidate Worker.

Each applicant may belong to another workspace, but must not already belong to
the target workspace. Use dedicated identities and offboard them afterward.
Never place passwords, bearer tokens, invitation or enrollment secrets, QR
images, confirmation links, or full provider payloads in release evidence.

## Automated Baseline

Keep the passing JSON evidence from all three probes with the same candidate:

```powershell
./eng/operations/verify-deployed-public-edge.ps1 `
  -PublicOrigin https://candidate.example `
  -ExpectedReleaseId <promotion-record-release-id>
./eng/operations/verify-deployed-workspace-invitation.ps1 `
  -Origin https://candidate.example `
  -WorkspaceId <workspace-id> `
  -AllowedPropertyId <allowed-property-id> `
  -DeniedPropertyId <denied-property-id> `
  -ApplicantEmail <verified-invitation-applicant-email>
./eng/operations/verify-deployed-workspace-enrollment.ps1 `
  -Origin https://candidate.example `
  -WorkspaceId <workspace-id> `
  -AllowedPropertyId <allowed-property-id> `
  -DeniedPropertyId <denied-property-id> `
  -ApplicantEmail <verified-enrollment-applicant-email>
```

Supply credentials through secure parameters, the documented environment
variables, or secure prompts. Do not put credentials on a command line.
Each mutation-bearing verifier needs an applicant that is not yet a member of
the target workspace; do not reuse the identity joined by the first probe.

## Recipient-Bound Invitation

1. In Workspace settings, issue an invitation for applicant A, the selected
   low-privilege profile, and only the allowed property. Confirm the link and QR
   are shown once and that copying the link does not expose it in logs.
2. Open the link in a clean browser profile while signed out. Confirm the join
   secret is removed from the visible URL after the app preserves it.
3. Register applicant A through every registration method enabled for launch.
   For password registration, use the real confirmation message and verify that
   the confirmation link returns to the same candidate origin. For each enabled
   external provider, verify state, callback origin, cancellation, and retry.
4. Confirm registration returns to the pending join journey, not the dashboard
   or an unrelated workspace. Complete the Staff form and accept the invitation.
5. Confirm the UI converges to one Staff profile and the intended role/property
   access. The applicant can open the allowed property and cannot open the
   denied property or Staff administration.
6. Sign out, reopen the consumed link, and sign in again. It must show the
   terminal outcome without duplicating membership, Staff, or access.

## Existing-Account QR Enrollment

1. Sign in as applicant B in another workspace, then open a new approval-required
   Team QR link. Confirm Back returns to the applicant's usable main page.
2. Reopen the link, review the sanitized role/property summary, complete the
   Staff form, and submit. The applicant must remain denied target-workspace
   access while approval is pending.
3. In the owner's browser, confirm exactly one pending request appears with the
   submitted Staff summary. Reject it and confirm applicant B sees the terminal
   rejection without target access.
4. Issue a fresh one-use Team QR link and submit it as applicant B. Stop the
   candidate Worker through the approved deployment control before approving.
5. Approve in the owner browser. While the Worker is stopped, no partial access
   may appear. Start the same candidate Worker and confirm the request converges
   once to the intended Staff profile and property-scoped access.
6. Refresh both browsers and retry the terminal action. The result must remain
   stable, the one-use source must be at capacity, and no duplicate membership,
   Staff profile, or assignment may appear.

## Evidence And Exit

The private release record must contain:

- exact candidate identity and probe evidence paths;
- registration-adapter matrix, including an explicit `disabled` result for
  adapters not offered by the UI;
- bounded mail/provider delivery event identifiers and UTC timestamps;
- browser name/version and pass/fail for every step above;
- Worker stop/start evidence and the observed convergence interval;
- source, application, membership, Staff, and assignment identifiers needed
  for audit and cleanup; and
- cleanup outcome for both applicants and every active join source.

Redact join secrets and personal data from screenshots. A missing provider
event, wrong-origin redirect, visible secret after capture, partial grant while
the Worker is stopped, duplicate projection, or ambiguous cleanup blocks the
release. Preserve state and investigate; do not repair module-owned tables
directly.
