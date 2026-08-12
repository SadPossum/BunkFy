# Preview Trusted HTTPS Browser Onboarding Proof Task

Status: completed
Date: 2026-08-12

## Goal

Retain one exact-release browser rehearsal for Workspace Access and Staff
Onboarding through the trusted public Preview HTTPS edge. Close the gap between
the existing loopback browser proof and the new trusted-HTTPS API domain proof.

## Boundary

- GMA Auth, Organizations, and AccessControl retain generic identity,
  membership, join-source, and assignment mechanics.
- BunkFy Workspaces and Staff retain access-plan, profile, property-scope, and
  employment policy.
- The product root owns browser automation, private Mailpit access, guarded
  Preview Worker restart, synthetic cleanup, and minimized evidence.
- Use only public product contracts and visible browser behavior. Do not seed or
  repair module-owned storage and do not add test-only application behavior.

## Proof

1. Verify the exact release over trusted HTTPS before and after mutation.
2. Register and verify an invitation applicant through the browser, preserve
   join continuation, render the intended role/property plan, and prove scoped
   access plus terminal replay.
3. Render a one-use Team QR, submit a second account for approval, prove denial
   while pending and while the Worker is stopped, then prove one-time
   convergence after the guarded restart.
4. Verify one Staff record and one intended access assignment per applicant,
   with no denied-property or Staff-management authority.
5. Remove memberships and properties, archive synthetic workspaces, revoke
   sessions, restore the Worker, purge Mailpit, and retain no browser artifact or
   reusable credential.

## Evidence Rules

- Evidence is schema-versioned, checksumable, and operator-only.
- Retain fingerprints and stable outcomes, never emails, passwords, bearer
  tokens, verification codes, join tokens, QR payloads, storage state, traces,
  screenshots, videos, or captured message bodies.
- A cleanup failure or changed release blocks the proof.

## Outcome

- Release `preview-browser-https-1f3fd75` passed all 18 browser checks through
  `https://213.109.163.152` with trusted TLS and continuous release identity.
- Chromium `151.0.7922.34` completed password registration, captured email
  verification, invitation continuation and replay, Team QR rendering, pending
  denial, approval, and one-time convergence after a guarded Worker restart.
- The default Front desk plan allowed the intended property and denied the
  second property plus Staff management for both separate applicants.
- Worker restart convergence was 727 ms. Cleanup removed two non-owner
  memberships, retired two properties, archived both synthetic workspaces,
  revoked all three sessions, closed browser contexts without artifacts, and
  restored the Worker.
- Mailpit finished unpublished and empty. The evidence file is operator-only and
  contains no sensitive key or email value:
  `.tmp/deployment-probes/preview-browser-https-1f3fd75.json`, SHA-256
  `cd74bd932ea3fecb8ce7b7d93cb4e69dfec91811d4c9502d2b82c859637813da`.
- Password registration was enabled and passed through captured Preview mail;
  external identity providers were explicitly disabled. Real-provider and
  hosted-orchestrator evidence therefore remain open.

## Deferred

- Real SMTP delivery, domain authentication, suppression, and inbox placement.
- Every enabled external identity-provider callback and cancellation path.
- A hosted orchestrator restart outside this VPS Preview composition.
- Custom-profile administration and assignment changes after onboarding; that
  remains a separate Workspace Access proof slice.
