# Workspace Shell Catalogue Recovery Task

Status: implemented, repository verified, and published
Date: 2026-08-23

## Goal

Keep the workspace shell, workspace selection, onboarding routes, and owner
controls honest and recoverable when the current account's workspace catalogue
is loading, stale, or unavailable.

## Findings

- A failed initial catalogue read is currently treated as an authoritative
  empty list. The provider can clear the saved workspace and switch the session
  back to global scope even though no current membership evidence was loaded.
- A failed background refresh blocks the whole application despite React Query
  retaining a usable last-loaded workspace snapshot.
- The shell always reports `Live workspace`, including while workspace,
  property, or navigation-authority evidence is delayed.
- Workspace creation and invitation acceptance are independent global-scope
  workflows, but the gate currently blocks both behind catalogue availability.
- Owner status comes from the workspace catalogue. A stale owner snapshot can
  therefore keep grant-producing role, invite, member-access, ownership, and
  retention controls active unless current catalogue evidence participates in
  the authority gate.
- The catalogue failure screen renders transport error text directly instead
  of a bounded product recovery message.

## Ownership

- GMA Organizations retains membership truth, owner governance, invitation and
  enrollment admission, optimistic concurrency, and server-side authorization.
- BunkFy Workspaces retains product onboarding, operational admission, and the
  product-facing workspace facade.
- The web application owns catalogue source composition, local workspace
  selection, stale-snapshot presentation, route recovery, and fail-closed
  affordances.
- Existing backend and GMA endpoints remain authoritative and already validate
  membership, owner state, versions, and requested scope. No backend, schema,
  framework, module, or extension change is required for this slice.

## Decisions

- Reconcile or clear a selected workspace only after a settled successful
  catalogue read. Loading, failed, and stale reads preserve the last selection
  and tenant boundary.
- Keep a last-loaded catalogue usable as visibly delayed navigation context.
- Allow explicit workspace creation and invitation or enrollment routes to run
  independently from catalogue availability; surface the catalogue problem
  without hiding those workflows.
- Treat owner-derived authority as current only when the catalogue is settled
  and successful. Stale owner context stays visible but cannot create or widen
  access, transfer ownership, retry retention, or change workspace identity.
- Preserve known workspace and property choices during delayed refreshes while
  continuing to rely on server authorization for every read and command.
- Replace raw catalogue failures with bounded recovery copy and an explicit
  retry path.

## Delivery

- [x] Expose settled/current workspace-catalogue evidence from the provider.
- [x] Make selection reconciliation non-destructive on unavailable evidence.
- [x] Recover the shell from stale catalogue snapshots and report source state
  truthfully.
- [x] Decouple create and join routes from catalogue availability.
- [x] Include current catalogue evidence in owner-derived mutation authority.
- [x] Add focused selection, route, and authority recovery tests.
- [x] Run one complete web gate.
- [x] Publish the coherent slice.

## Invariants

- An unavailable catalogue is never represented as authoritative emptiness.
- A refresh failure never clears a valid stored workspace or changes tenant
  scope by itself.
- Stale membership data cannot authorize a grant-producing or owner-only
  command in the UI.
- Join tokens, raw API errors, subject identifiers, and response payloads are
  not copied into shell recovery notices.
- Tenant isolation, query-cache boundary clearing, server authorization,
  optimistic concurrency, and onboarding idempotency remain unchanged.

## Verification Cadence

Use focused provider-selection, gate, shell, and workspace-authority tests while
editing, then run one complete web typecheck, lint, test, build, and contract
drift gate. This slice changes no backend, database, provider, broker,
container, GMA framework, or GMA extension behavior, so no Docker or GMA gate
is required.

Repository verification on 2026-08-23:

- Focused catalogue, workspace-access authority, composite-source, foundation,
  and navigation tests: 5 files and 37 tests passed.
- `pnpm verify` passed, including typecheck, lint, 65 test files with 333 tests,
  and the production build.
- `pnpm contracts:check` passed; generated API contracts are current.
- `BunkFy.Workspace.slnx` parses and lists the workspace successfully.
- `git diff --check` passed for the slice.
- Published web commit:
  `621e5c63ee442d6bc5979ce805a615b3c5a4b2e1`.

## Deferred

- Domain-page recovery for stale property directories and permission reads
  beyond the shared shell and Workspace settings boundary.
- Hosted browser and production workspace-access estate evidence, which remain
  external release gates rather than repository implementation.
