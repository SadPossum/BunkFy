# Account Security Partial Data Recovery Task

Status: implemented and repository verified
Date: 2026-08-23

## Goal

Keep personal profile, session, sign-in-method, external-provider, and MFA
recovery independently usable and truthful when one account source is delayed
or unavailable.

## Findings

- Authentication-method loading or failure suppresses the independently loaded
  MFA panel.
- External-provider discovery failures are converted to an empty list, making
  unavailable provider data look like an authoritative absence.
- A staff-profile failure is silently presented as "Not ready" and removes the
  profile recovery surface.
- A failed provider-link redirect is stored in the session error state and
  displayed inside Active Sessions, which misidentifies the failed operation.
- Session refresh failures discard an already loaded session snapshot.

## Ownership

- GMA Auth and BunkFy Staff remain authoritative for their existing methods,
  provider, MFA, session, and profile contracts.
- The BunkFy web application owns source composition, failure placement,
  stale-snapshot presentation, and current-evidence UI gating.
- No API, aggregate, permission, generated contract, backend module, GMA
  framework, or GMA extension change is required.

## Decisions

- Keep MFA available independently from authentication methods.
- Preserve stale methods, providers, sessions, and staff profile data for
  read-only context with one bounded retry notice.
- Require a successful settled methods snapshot for password, email, and
  external-identity changes, and a successful settled provider snapshot before
  beginning a new provider link.
- Keep sign-out controls available when the session directory is unavailable;
  signing out is a fail-closed account action rather than a directory mutation.
- Load the workspace staff profile only when a workspace is selected and give
  it an explicit local loading or unavailable state.
- Show provider-link failures in External accounts and sign-out failures in
  Active sessions.

## Delivery

- [x] Model Account sources independently and retain stale snapshots.
- [x] Keep MFA and sign-out recovery available on unrelated failures.
- [x] Gate security mutations on current source evidence.
- [x] Place provider-link and sign-out failures with their owning actions.
- [x] Add focused source-wiring tests.
- [x] Run one complete web gate.
- [x] Publish the coherent slice.

## Invariants

- No failed source is rendered as an authoritative empty list or unconfigured
  security method.
- Existing logout, MFA, recent-authentication, and server-side authorization
  behavior remains unchanged.
- Raw API errors, account identifiers, and response payloads are not copied
  into composite source notices.
- Stale profile edits retain their existing expected-version concurrency guard.

## Verification Cadence

Use focused source-state and Account wiring tests while editing, followed by
one full web typecheck, lint, test, build, and contract-drift gate. No backend,
migration, Docker, provider, broker, or GMA test is required.

Repository verification on 2026-08-23:

- `pnpm verify` passed, including typecheck, lint, 63 test files with 323 tests,
  and the production build.
- `pnpm contracts:check` passed; generated contracts are current.
- `git diff --check` passed for the slice.
- Published web commit: `7e7634c436175a7277974506a08db293ebbfdc63`.
- That exact commit passed repository validation and security-baseline
  workflows.
