# Web Shell Failure Recovery Task

Status: implemented and repository-verified
Date: 2026-08-23

## Goal

Keep BunkFy's authenticated navigation and workspace context usable when a
lazy-loaded route or page render fails, and provide a bounded last-resort
recovery surface when the application shell itself cannot render.

## Finding

- Route modules are loaded through `React.lazy`, but the shared `Suspense`
  boundary handles only loading. A rejected chunk or render exception can
  replace the authenticated application with a blank page.
- Workspace, notification, session, or shell render failures have no final
  recovery surface.
- Query and mutation failures already use explicit local error states. This
  slice is for unexpected render and asset failures, not a replacement for
  those domain-specific recovery paths.

## Ownership

- The web application owns render containment, navigation recovery, and the
  presentation of non-sensitive fallback content.
- Feature modules continue to own expected query, mutation, validation, and
  workflow failures.
- GMA and backend modules remain unchanged. React render recovery is not a
  reusable backend framework concern.

## Decisions

- Place a route boundary inside `AppShell` so an individual page failure keeps
  workspace selection, navigation, account access, and sign-out available.
- Reset a failed route only after navigation changes the route identity. A
  rejected lazy import remains recoverable through a full reload rather than
  pretending the cached rejection was retried.
- Add one outer application boundary for provider or shell render failures.
- Show generic recovery copy and never render exception messages, stack traces,
  route parameters, tenant identifiers, or query contents.
- Offer familiar reload and overview actions. The outer boundary offers reload
  only because the router and authenticated shell may be unavailable.
- Do not add a dependency for this small React primitive.

## Delivery

- [x] Add reusable route and application error boundaries.
- [x] Wire route containment inside the authenticated shell and outer
  containment around the provider tree.
- [x] Add focused behavior/source guards and run one complete web gate.
- [x] Update workspace metadata and publish the coherent slice.

## Invariants

- Expected API failures remain local and actionable.
- A route render failure cannot remove navigation or workspace controls.
- Navigation away from a failed route can recover without a reload.
- Raw error details and current URL data are never displayed or persisted.
- Authentication, tenant selection, query-cache isolation, and permission
  checks remain unchanged.

## Verification Cadence

Use focused web checks while editing, then run TypeScript, lint, the complete
web test suite, and the production build once at the slice boundary. No
backend, migration, Docker, provider, broker, or GMA test is required.

## Completion Evidence

- Focused boundary behavior and source-containment coverage passed 3/3.
- The complete web gate passed TypeScript, lint, 60 test files with 310 tests,
  and the production Vite build with 3,014 transformed modules.
- The generated OpenAPI snapshot and TypeScript contracts remain current.
- No backend, migration, Docker, provider, broker, or GMA test was run because
  this slice changes only frontend render containment and recovery.
