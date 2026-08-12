# Preview Browser Onboarding Rehearsal Task

Status: completed
Date: 2026-08-12

## Goal

Add a deterministic browser rehearsal for the deployment-owned part of Staff
onboarding, then run it against one exact Preview release. The proof should
cover browser secret handling, password registration continuity, captured
email verification, invitation and Team QR rendering, approval, Worker restart
recovery, terminal replay, and explicit cleanup without weakening module
boundaries or retaining join credentials.

## Ownership

- Auth, Organizations, Workspaces, Staff, and AccessControl keep their existing
  product and framework ownership. The rehearsal uses only their public HTTP
  contracts and visible browser behavior.
- The web app owns accessible controls and redirect continuity, but no test-only
  API or authentication bypass is added.
- The product root owns Preview Mailpit access, Compose process control,
  evidence policy, and cleanup.
- GMA receives no BunkFy-specific browser, Staff, property, or deployment code.

## Invariants

1. The public origin and release identity are checked before and after every
   mutation-bearing run.
2. Passwords, bearer tokens, verification codes, invitation/enrollment tokens,
   QR payloads, browser storage state, and full email addresses remain in
   process memory and never enter retained evidence or command arguments.
3. Fixture setup and cleanup use public product APIs; module-owned tables,
   broker state, and outbox rows are not inspected or edited.
4. Automatic traces, video, screenshots, and HTML reports are disabled because
   onboarding pages can contain one-time credentials. Private opt-in debugging
   is a separate operator action and is not release evidence by default.
5. Worker stop/start is allowed only for the configured Preview project. The
   Worker is restored and its health verified in a `finally` path even when the
   browser proof fails.
6. A stopped Worker must not expose partial Staff or property access. Restart
   must converge once, and retry must not duplicate membership, Staff, or
   assignment state.
7. Mailpit proves captured Preview delivery only. External-provider callbacks,
   domain authentication, suppression behavior, and inbox placement remain
   private production gates.

## Delivery Slices

1. Add a pinned Playwright Chromium runtime and a root-owned browser driver
   with bounded navigation, response, mail-capture, and convergence timeouts.
2. Add a guarded PowerShell entry point that validates the Preview topology,
   opens loopback-only Mailpit access, invokes the driver through environment
   variables, and always closes the operator window.
3. Rehearse a recipient-bound invitation from signed-out link capture through
   registration, email verification, Staff submission, scoped access, consumed
   link replay, and sign-out.
4. Rehearse Team QR rendering and existing-account enrollment through pending
   approval, stopped-Worker denial, restart convergence, terminal retry, and
   one-use capacity behavior.
5. Write a scrubbed schema-versioned evidence record with hashed synthetic
   identity fingerprints, browser/runtime versions, bounded timestamps,
   check outcomes, cleanup outcomes, and honest limitations.
6. Add fast static/fixture guards, run focused web checks while editing, then
   execute one end-of-slice browser rehearsal and root operations gate.

## Done When

- the exact Preview release passes both browser journeys with no visible join
  secret after capture and no partial access while the Worker is stopped;
- the Worker, Mailpit operator window, synthetic memberships, properties,
  workspace, sessions, and join sources have explicit verified cleanup states;
- retained evidence contains no reusable credential or personal data; and
- the runbook distinguishes this proof from real-provider and hosted-network
  evidence that still must be captured privately before launch.

## Outcome

Release `preview-browser-onboarding-5741666` passed all 18 checks in both the
non-disruptive diagnostic and the guarded Worker-restart rehearsal. The retained
private proof is
`.tmp/deployment-probes/preview-browser-onboarding-5741666.json`; its cleanup
record confirms two non-owner memberships removed, two properties retired,
both synthetic workspaces archived, all three browser identities signed out,
the Worker restored, browser contexts closed without artifacts, and captured
mail purged before the loopback operator window closed.

The implementation also recovered a product failure exposed by the rehearsal:
an approved browser could remain on `/join` when the access-readiness request
was temporarily rate limited. BunkFy Web now preserves bounded `Retry-After`
guidance, retries only the known readiness responses, and offers an explicit
activation retry after either invitation or Team QR membership succeeds.

This is local Preview composition evidence. It does not prove real SMTP
delivery, an external OIDC callback, a remote HTTPS ingress, or a hosted
orchestrator restart. Before multi-tenant Production admission, review the
current IP-partitioned sensitive limit: read-only enrollment polling shares the
same 60-request window as mutations, so unrelated users behind one NAT can
delay onboarding even though the UI now recovers correctly.
