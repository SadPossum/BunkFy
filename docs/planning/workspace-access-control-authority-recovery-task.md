# Workspace Access Control Authority Recovery Task

Status: implemented, repository verified, and published
Date: 2026-08-23

## Goal

Keep workspace roles, member access, invitations, enrollment links, and join
requests usable during partial source failure without creating grants from
missing or stale authority.

## Findings

- Role profiles and the actor-filtered permission catalogue are independent
  reads, but catalogue loading and failure are mixed into profile-list state.
- A stale profile or permission snapshot can still open grant-producing role,
  member-access, invitation, and enrollment controls.
- The shared property directory becomes an empty array when it has not loaded.
  In access forms, an empty property selection means all current and future
  properties, so unavailable topology can be mistaken for intentional
  workspace-wide access.
- Member-access controls can appear enabled while profile discovery has failed;
  clicking them then produces no editor.
- Issued-link lifecycle management is hidden whenever profile discovery fails
  or exceeds the bounded assignment picker, even though revoking or disabling
  a source does not require that directory.
- Failed background refreshes discard already loaded role, join-source, and
  join-request context. Grant and deny operations need different recovery
  treatment.

## Ownership

- GMA Access Control retains generic profile lifecycle, assignment history,
  exact-scope reconciliation, optimistic concurrency, and anti-escalation.
- GMA Organizations retains membership admission, join-source lifecycle, and
  owner governance.
- BunkFy Workspaces retains product permission dependencies, protected seeds,
  property-scoped plans, the single-role operator workflow, operational
  admission, and its product-facing facade.
- The BunkFy web application owns source composition, current-authority gates,
  stale-snapshot presentation, and fail-closed operator affordances.
- Existing backend and GMA contracts already revalidate actor authority,
  profile state, property identity, expected versions, and operational
  admission. No backend, migration, framework, module, or extension change is
  required for this slice.

## Decisions

- Preserve stale role, member, issued-source, and join-request snapshots as
  visibly delayed read-only context.
- Require current actor permissions, profile discovery, property discovery,
  and operation-specific records before creating or widening access.
- Never interpret an unavailable property directory as an authoritative empty
  directory or as a request for workspace-wide access.
- Keep revoking an invitation, disabling an enrollment link, and rejecting a
  join request available from a stale row because these are fail-closed
  actions protected by server-side authorization and expected versions.
- Require current source evidence before replacing a join source, approving or
  retrying onboarding, transferring ownership, or changing member access.
- Keep issued-link lifecycle and join-request recovery independent from the
  active-profile assignment picker.
- Retain the existing bounded 100-role assignment guard until the API supports
  a server-filtered role picker; do not silently truncate assignable roles.

## Delivery

- [x] Expose settled/current permission and property-directory evidence.
- [x] Decouple role-list recovery from permission-catalogue authority.
- [x] Gate member-access grants on current membership, role, property, and
  assignment evidence.
- [x] Keep issued-source and join-request deny paths usable independently.
- [x] Add focused authority and partial-source recovery tests.
- [x] Run one complete web gate.
- [x] Publish the coherent slice.

## Invariants

- No unavailable or stale directory is represented as authoritative emptiness.
- No grant-producing action is enabled from stale permission, profile,
  property, source, or application evidence.
- Revocation and rejection never become dependent on unrelated enrichment.
- Tenant scope, permission checks, expected versions, request identities,
  pagination, exact assignment replacement, and operational admission remain
  unchanged.
- Raw API errors, join tokens, subject identifiers, and response payloads are
  not copied into composite source notices.

## Verification Cadence

Use focused source-state and workspace-access wiring tests while editing, then
run one complete web typecheck, lint, test, build, and contract-drift gate.
This slice changes no backend, schema, provider, broker, container, GMA
framework, or GMA extension behavior, so no Docker or GMA gate is required.

Repository verification on 2026-08-23:

- Focused workspace authority, composite-source, permission, settings-access,
  and foundation tests: 5 files and 36 tests passed.
- `pnpm verify` passed, including typecheck, lint, 64 test files with 329 tests,
  and the production build.
- `pnpm contracts:check` passed; generated API contracts are current.
- `BunkFy.Workspace.slnx` parses and lists the workspace successfully.
- `git diff --check` passed for the slice.
- Published web commit:
  `e578b9d2f54d85fd2c2bf334fe0e1f42210199cb`.

## Deferred

- A server-filtered, paged active-role picker for workspaces with more than 100
  active profiles.
- Hosted production Workspace Access estate execution and private approval,
  which remain external release gates rather than repository implementation.
