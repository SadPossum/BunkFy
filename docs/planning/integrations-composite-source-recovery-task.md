# Integrations Composite Source Recovery Task

Status: implemented and repository verified
Date: 2026-08-23

## Goal

Keep connection, review, and ingestion-activity workflows truthful and usable
when adapter capabilities or connection directories are delayed or unavailable.

## Findings

- Connections and adapter capabilities are independent reads, but either
  loading or failing currently replaces the complete connection list.
- A failed adapter-capability read is converted to an empty array. The create
  modal and capability catalogue can therefore falsely report that no adapter
  types are registered.
- Connection settings fall back to generic execution modes and polling limits
  when capability data is absent, which makes an unavailable control-plane read
  look like valid configuration authority.
- The paged connection list, all-connection filter directory, and adapter
  capability catalogue are fetched on every primary tab, including Review,
  where none of them are needed.

## Ownership

- Ingestion remains authoritative for connections, registered capabilities,
  settings validation, and activity.
- The BunkFy web application owns tab-aware query composition, partial-source
  presentation, and disabling actions that require current capability data.
- No API, aggregate, permission, generated contract, backend module, GMA
  framework, or GMA extension change is required.

## Decisions

- Load the paged connection directory only for the Connections tab, the full
  filter directory only for Activity, and capabilities only where they are
  displayed or required.
- Preserve stale snapshots for navigation and read-only context with an
  explicit warning and bounded retry.
- Require a current capability snapshot before creating a connection or
  editing capability-dependent connection settings and polling schedules.
- Keep connection health, credentials, runs, receipts, reprocessing, and
  proposal review available when unrelated source reads fail.
- Never convert a failed capability or directory read into an authoritative
  empty catalogue.

## Delivery

- [x] Make top-level Integrations sources independent and tab-aware.
- [x] Keep connection lists and activity panels available on partial failure.
- [x] Gate capability-dependent mutations on current capability evidence.
- [x] Add focused source-wiring tests.
- [x] Run one complete web gate and publish the coherent slice.

## Invariants

- Tenant, property, permission, pagination, and live-refresh behavior remains
  unchanged.
- Raw API errors and response payloads are not copied into source notices.
- A missing capability snapshot never expands the set of selectable modes or
  invents default limits for a mutation.
- Existing connection and activity identifiers remain valid recovery context.

## Verification Cadence

Use focused source-state and wiring tests while editing, followed by one full
web typecheck, lint, test, build, and contract-drift gate. No backend,
migration, Docker, provider, broker, or GMA test is required.

## Repository Evidence

- Focused composite and Integrations source-recovery tests: 9 passed.
- Complete web gate: 62 test files and 319 tests passed, with typecheck, lint,
  and production build succeeding.
- Generated web API contracts are current.
- Published web commit: `7a16b5acfcd7b1db726babde9b3292d60fa2e66f`.
- That exact commit passed repository validation and security-baseline
  workflows.
