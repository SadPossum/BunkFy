# Preview Workspace Access Administration Proof Task

Status: complete
Date: 2026-08-12

## Goal

Retain one exact-release trusted-HTTPS browser rehearsal proving that a BunkFy
workspace owner can create, edit, assign, replace, and archive a custom
operational role without granting authority outside the selected property.

## Boundary

- GMA AccessControl retains generic profile lifecycle, assignment history,
  exact-scope reconciliation, optimistic concurrency, and anti-escalation.
- GMA Organizations retains membership admission and owner governance.
- BunkFy Workspaces retains product permission labels and dependencies,
  protected seeds, property plans, single-role operator workflow, and the
  owner-facing administration facade.
- The product root owns the opt-in browser rehearsal, exact-release checks,
  synthetic fixture cleanup, and minimized evidence.
- Use only visible browser behavior and public product contracts. Do not call
  raw GMA administration routes, private Admin APIs, or module storage.

## Proof

1. Extend the existing browser onboarding rehearsal behind an explicit opt-in
   switch so the default proof remains bounded.
2. After invitation onboarding, create a custom `Property observer` role in
   Workspace settings with only `properties.read`.
3. Assign the invited member to that role for one property. Prove the allowed
   property is readable, the second property is denied, Reservations remains
   denied, and profile or Staff administration cannot be self-granted.
4. Prove the member's visible navigation converges to the same authority as the
   API, then edit the role to add `reservations.read` and prove Reservations
   appears without create, Staff, or role-management authority.
5. Reassign the member to the built-in Front desk role at the same property,
   prove exact replacement, archive the now-unassigned custom role, and prove
   it is no longer assignable.
6. Preserve the existing invitation replay, QR enrollment, Worker restart,
   exact-release continuity, session revocation, property retirement,
   workspace archival, Mailpit purge, and browser-artifact cleanup checks.

## Evidence Rules

- Record whether custom-profile administration was requested and passed, plus
  the synthetic profile id and stable check outcomes.
- Never retain role request bodies, account identifiers, credentials, join
  tokens, verification codes, message contents, screenshots, traces, or video.
- A permission mismatch, release change, archive failure, or incomplete cleanup
  fails the proof.
- When the opt-in switch is absent, evidence must say that custom-profile
  administration was not exercised.

## Verification Cadence

Use syntax, contract, and static operation guards while editing. Run the full
operations suite once when the slice is coherent, then run one exact-release
trusted-HTTPS rehearsal. Do not run a Docker rehearsal after each edit.

## Deferred

- Deployment-by-deployment current seed version 4 status and bootstrap evidence.
- Exhaustive coverage of every permission and workspaces with more than 100
  active custom roles.
- Real SMTP or external identity-provider delivery and a hosted orchestrator.
- Changes to GMA; the existing generic contracts already cover this proof.

## Outcome

- Exact release `preview-workspace-access-0257a44` passed 22 trusted-HTTPS
  browser checks with custom-profile administration explicitly enabled.
- Separate owner and member accounts proved custom-role create/edit, one-property
  allow/deny, anti-escalation, permission-filtered navigation, exact Front desk
  replacement, archive, and exclusion from the active assignment picker.
- The rehearsal exposed and fixed basic select pickers propagating Escape into
  their containing modal. Web commit `48d290c` now contains Escape consistently
  for basic and searchable pickers.
- Evidence is retained locally at
  `.tmp/deployment-probes/preview-workspace-access-0257a44.json` with SHA-256
  `2e1d7e1aa087865f0de04999776df1d7ee721f6bfd4e932c872cab741249bc7a`.
  It contains fingerprints rather than account identifiers and no browser
  screenshots, traces, video, credentials, or join secrets.
- Cleanup removed both ordinary memberships, archived the custom role and both
  synthetic workspaces, retired both properties, revoked all sessions, restored
  the Worker, and left Mailpit empty with no operator network or browser
  artifacts.
