# Authentication Entry Source and Callback Recovery Task

Status: complete
Date: 2026-08-23

## Goal

Keep password sign-in available when optional registration or provider
discovery fails, while binding account creation and external sign-in to current
public configuration and removing callback credentials from browser-visible
history as soon as they are captured.

## Existing Foundation

- GMA Auth owns generic password registration, external-provider adapters,
  browser sessions, MFA challenges, one-time exchanges, attempt limiting, and
  no-store response policy for the complete `/api/auth` surface.
- BunkFy preserves invitation staff drafts separately from credentials and
  submits them only through the existing workspace-enrollment boundary after
  authentication.
- Browser refresh, sign-out, workspace switching, external completion, and MFA
  already use single-flight or browser-session locking where required.

## Findings

- A self-registration discovery failure is rendered as authoritative policy
  disablement, while a provider discovery failure is rendered as an
  authoritative empty provider list.
- Invitation registration is initially actionable before its public policy
  source settles, and account creation does not refresh that policy immediately
  before dispatch.
- Retained provider entries can begin a new redirect after their discovery
  source becomes stale; the current provider catalogue is not rechecked first.
- External callback authorization codes and provider error metadata remain in
  the address bar and browser history while completion or recovery is shown;
  the production edge also permits same-origin referrers and ordinary access
  logging for the callback URI.
- Pending external intent is not explicitly cleared when a callback is invalid,
  rejected, or abandoned, and callback intent is not cross-checked against the
  locally initiated operation.
- Raw API exception messages and the resolved backend URL can reach the public
  authentication screen.

## Ownership

- GMA Auth remains authoritative for registration policy, configured adapters,
  exchange state, MFA, credentials, cookies, throttling, and generic errors.
- The BunkFy web application owns independent source presentation, command-time
  refresh, safe public copy, callback metadata capture, URL scrubbing, and
  browser-local pending-intent cleanup.
- The BunkFy web image owns callback-route logging and browser referrer policy.
- Workspace and Staff continue to own invitation profile adoption after sign-in.
- No backend, GMA, extension, schema, migration, provider, or broker change is
  required. The web image edge configuration changes and must be validated once
  at the slice boundary.

## Decisions

- Treat registration policy and provider discovery as independent public
  sources; neither failure may suppress password sign-in or masquerade as an
  authoritative disabled or empty state.
- Retain stale discovery only as context. Recheck registration policy before
  account creation and recheck the provider catalogue before starting a new
  redirect.
- Keep registration controls disabled while policy evidence is loading,
  refreshing, stale, or unavailable. Switch to sign-in only after current policy
  explicitly disables password registration.
- Capture callback code, provider, intent, and provider error once, then replace
  the URL before rendering or waiting for session restoration.
- Use a no-referrer browser policy and suppress access logging for the exact
  callback route in the production web image.
- Prefer the locally initiated pending intent and require any callback intent to
  agree with it. Clear pending state on terminal callback failure or explicit
  cancellation.
- Present deliberate authentication guidance without copying API payloads,
  internal subject language, or infrastructure coordinates into the page.

## Delivery

- [x] Add pure registration, provider, callback, and public-error helpers.
- [x] Compose registration and external-provider discovery independently.
- [x] Revalidate public policy/catalogue evidence at command dispatch.
- [x] Capture and scrub callback metadata while preserving hardened-browser
  fallback behavior.
- [x] Clear abandoned external intent and sanitize authentication failures.
- [x] Add focused source, callback, and structural regression coverage.
- [x] Run one complete web gate and publish the coherent authentication slice.

## Verification

- Focused authentication source, callback, session-refresh, and web-foundation
  verification passed with 4 test files and 31 tests.
- Complete web verification passed with 73 test files and 371 tests, followed
  by lint, typecheck, and a 3,032-module production build.
- Generated OpenAPI TypeScript contracts match the backend snapshot.
- Backend and root workspace solutions regenerate deterministically from the
  current workspace graph.
- The production web image built successfully, its Nginx configuration passed
  syntax validation, and the exact callback route returned the SPA with a
  `no-referrer` policy while omitting a test authorization code from access
  logs. Ordinary route access remained logged.
- A browser callback rehearsal replaced the code-bearing URL before recovery
  rendered and exposed only deliberate public error copy when the API was
  unavailable.

## Publication

- Web `dev`: `60cfdab` (`Harden authentication source recovery`).

## Invariants

- Password sign-in remains usable when either optional discovery source fails.
- Unavailable registration or provider evidence never becomes an authoritative
  disabled or empty state and never authorizes a new operation.
- A callback cannot silently change a locally initiated sign-in into an account
  link, or an account link into a sign-in.
- Authorization codes do not remain in the address bar, browser history entry,
  recovery link, same-origin referrer, or BunkFy web callback access log after
  capture.
- Server-side exchange, registration policy, MFA, rate limiting, and cookie
  controls remain the authority boundary.
- BunkFy invitation and staff-profile policy does not leak into GMA Auth.

## Verification Cadence

Use focused pure-helper and authentication wiring tests during implementation.
At the domain boundary, run one complete web typecheck, lint, test, build,
contract-drift, and root solution-membership gate. This web-only slice requires
no backend-wide, GMA, or provider test run. Build and smoke the web image once
to validate its changed Nginx boundary; do not run the backend Docker suite.

## Deferred

- Real external-provider delivery and hosted callback proof, which remain
  deployment evidence for the exact enabled adapters.
- Password-recovery UI, passkeys, additional MFA adapters, and localized public
  authentication copy.
