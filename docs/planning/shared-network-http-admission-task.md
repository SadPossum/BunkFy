# Shared-Network HTTP Admission Task

Status: completed
Date: 2026-08-12

## Goal

Keep authentication and workspace-join mutations protected without allowing
read-only onboarding polling from several users behind one hotel network to
consume the same narrow budget and strand an approved user on `/join`.

## Ownership

- GMA provides generic named, method-aware HTTP rate-limit policies and atomic
  in-process/distributed enforcement.
- BunkFy owns the concrete authentication and workspace-onboarding path groups,
  permit counts, browser recovery, capacity assumptions, and Preview proof.
- Auth, Organizations, Workspaces, and AccessControl keep their API and domain
  ownership. Rate limiting does not move business rules or authorize a request.

## Policy

1. All public requests continue to consume the coarse global client budget.
2. Authentication writes consume a dedicated sensitive budget.
3. Invitation, enrollment, and staged Staff-onboarding writes consume a separate
   workspace-join budget.
4. Enrollment source lists, pending-request lists, and the applicant's current
   status use only the global budget. Authorization, no-store headers, tenant
   checks, and least-privilege rules remain unchanged.
5. `429` responses retain stable `Http.RateLimitExceeded` problem details and a
   bounded `Retry-After`; browser convergence retries only that known contract.
6. Preview may use in-process counters. Production remains fail-closed and must
   use the configured distributed atomic provider.

## Verification

- Architecture guards pin the BunkFy policy names, methods, and path ownership.
- Framework tests prove matching and atomic request construction.
- Focused host tests prove configuration startup.
- One end-of-slice Preview browser run proves that polling, approval, projection
  convergence, and cleanup complete against the exact deployed release.

## Outcome

- GMA Framework `fa1afd9` provides bounded named, method-aware policies with
  equivalent in-process chaining and atomic distributed admission. Its full
  test suite passed with 1,133 tests.
- GMA Skeleton `c99bc81` applies the policy model to generated hosts and passed
  its architecture and complete generated-selection verification.
- BunkFy Backend `c8d8b35` separates authentication writes from workspace-join
  writes while read-only enrollment polling consumes only the global budget.
  The 103-test host architecture suite passed.
- Root release checkpoint `40a84d8` was deployed as
  `preview-http-admission-40a84d8`. The non-disruptive Chromium rehearsal passed
  all 18 invitation, Team QR, authorization, convergence, replay, release, and
  cleanup checks without a `429` response. Scrubbed local evidence is retained
  at `.tmp/deployment-probes/preview-http-admission-40a84d8-attempt2.json` with
  mode `0600`.
- Post-run inspection found no cleanup failures, no published Mailpit port, no
  leftover management network, and a running Worker. The previous release's
  full guarded Worker-restart rehearsal remains the restart-specific proof;
  this policy-only slice did not repeat it.

## Deferred Capacity Evidence

The current global client budget remains IP-partitioned. Do not replace it with
an unvalidated token hash or silently raise it. Before a multi-property pilot,
measure realistic concurrent staff traffic behind one NAT and either tune the
coarse budget with evidence or design a separate authenticated-subject limiter
that runs after authentication while retaining an outer abuse boundary.
