# Composite Operator Page Partial Data Recovery Task

Status: implemented and repository verified
Date: 2026-08-23

## Goal

Keep composite operator pages useful and truthful when one independent domain
read is delayed or unavailable.

## Finding

- The dashboard waits for all four reads and replaces the complete page with
  the first error.
- A temporary failure in one source therefore hides trustworthy data from the
  other three domains and removes their navigation context.
- A failed background refresh can coexist with previously loaded data. That
  snapshot should remain visible with an explicit delayed-data warning rather
  than being discarded or silently presented as current.
- Inventory applies the same all-or-nothing handling to its independently
  loaded sales setup and block history, so either failure hides the other
  section and the independently loaded availability check.

## Ownership

- Each domain remains authoritative for its own data and failure semantics.
- Dashboard and Inventory own only composition, source availability, and
  honest presentation of partial snapshots.
- The reusable source-state model and notice belong to the BunkFy web
  application layer. They do not change a domain or framework contract.
- No aggregate, API, permission, generated contract, backend module, or GMA
  behavior changes in this slice.

## Decisions

- Keep the existing all-domain permission gate; this slice does not broaden
  dashboard visibility.
- Show the full loading state only while every source is still waiting and no
  source has usable data.
- Preserve loaded source data even when a later refresh fails.
- Render unavailable values as unavailable, never as zero, and keep loading
  values visibly pending.
- Show one non-sensitive source-status notice naming only affected domains and
  whether their last loaded snapshot is being retained.
- Retry only affected sources through their existing bounded queries.
- Keep Reservations-dependent lists and attention indicators independent from
  Inventory, room, and block metrics.
- Keep Inventory availability, sales setup, and block history independently
  recoverable. Disable only actions whose required source is unavailable.
- Leave Integrations capability and activity composition for a separate audit;
  its adapter-type dependency affects action semantics and needs a bounded
  domain decision rather than a mechanical UI change.

## Delivery

- [x] Add a small source-availability model with focused tests.
- [x] Make dashboard metrics and sections independently recoverable.
- [x] Keep Inventory availability, sales setup, and block history independent.
- [x] Add one bounded affected-source retry path and stale-snapshot notice.
- [x] Run one complete web gate and publish the coherent slice.

## Invariants

- No failed or pending source is represented as an authoritative zero.
- Existing data remains visible after a background refresh failure.
- Raw API errors, tenant identifiers, and response payloads are not shown in
  the composite warning.
- Permission, tenant, selected-property, query-key, and live-refresh behavior
  remains unchanged.
- Domain pages remain the recovery destination for domain-specific actions.
- Loading or failed Inventory reads never create false empty sales or block
  states, and block creation remains unavailable without a usable topology.

## Verification Cadence

Use focused composite helper/source tests while editing, followed by one
complete web typecheck, lint, test, build, and contract-drift gate. No backend,
migration, Docker, provider, broker, or GMA test is required.

## Repository Evidence

- Focused composite source-state tests: 5 passed.
- Complete web gate: 61 test files and 315 tests passed, with typecheck, lint,
  and production build succeeding.
- Generated web API contracts are current.
- `BunkFy.Workspace.slnx` parses and lists the workspace successfully.
- Exact web commit `7a277abfee7df8e7dfa9ca502bd1c93cf86156cd`
  passed repository validation and security-baseline workflows.
