# Preview Onboarding Rehearsal

Use `eng/operations/rehearse-preview-onboarding.ps1` to prove the composed
Preview registration, captured email verification, workspace invitation, and
QR enrollment paths against one exact release.

The rehearsal uses only:

- the public product API through the configured public origin; and
- Mailpit's short-lived loopback operator window.

Its default convergence polling cadence is two seconds so the combined
invitation and enrollment proof remains within the public sensitive-request
budget while still failing within the configured convergence timeout.

It does not read Auth tables, outbox or inbox rows, NATS messages, or module
internals. Mailpit capture proves the Preview composition, not real-provider
delivery, sender-domain authentication, suppression behavior, or inbox
placement.

Use the sibling
[Preview browser onboarding rehearsal](deployed-workspace-browser-rehearsal.md)
when the release gate also needs rendered QR, signed-out registration
continuity, existing-account Back behavior, browser redirect convergence, and
a guarded Worker restart. The API umbrella and browser rehearsal are separate
evidence records and should use fresh synthetic identities.

## Run

Deploy the exact candidate with `BUNKFY_EMAIL_CAPTURE_ENABLED=true`, then run:

```powershell
./eng/operations/rehearse-preview-onboarding.ps1 `
  -PublicOrigin http://127.0.0.1:8080 `
  -ExpectedReleaseId '<exact-release-id>' `
  -EnvironmentPath /protected/bunkfy-preview/.env `
  -AllowLoopbackHttp `
  -Confirm:$false
```

Add `-IncludeOperationsNotifications`, `-IncludeReservationsInventory`,
`-IncludeRetention`, or `-IncludeAdapterHost` to bind the corresponding
deployed child proof into the umbrella. Contributions may be selected together;
room-backed contributions own separate fixtures and coordinated cleanup.
The Reservations/Inventory contribution first discovers the single current
engineering/example country policy exposed by Preview, activates it through the
public Properties contract, and verifies the exact effective binding. This is a
synthetic processing prerequisite, not production country-policy approval.

The Retention contribution captures a UTC lower bound before workspace
creation, then uses only the public read contract to prove that both asserted
Ingestion first occurrences completed after that bound and that the full
catalogue is healthy. It does not enqueue a task, invoke Admin retry, inspect
owner records, or edit module state.

The AdapterHost contribution also requires an exact backend image reference and
the backend source commit admitted by that runtime:

```powershell
  -IncludeAdapterHost `
  -AdapterHostBackendImage '<registry>/bunkfy/backend@sha256:<digest>' `
  -AdapterHostBackendSourceCommitSha '<40-character-backend-commit>'
```

It creates one short-lived `json.file-drop` RemotePolling connection, starts one
hardened Production-mode container, and uses the read-only deployed AdapterHost
probe for an upsert and then a cancellation. Health is published only on a
random loopback port and `/status` remains disabled. The ingress token is
written to a Docker-managed material volume over standard input; it is never a
command argument or retained evidence value.
Before creating the connection, the child requires a credentialless lease
claim to return `401`; `503` identifies a disabled or misconfigured ingress
surface and fails without creating runtime state.

Remote origins must use trusted HTTPS. The environment and Compose files are
validated before mutation. The script creates its own random `.test`
identities and passwords; none are accepted as parameters or written to
evidence.

## Evidence And Cleanup

One umbrella evidence file and the selected child probe files are written under
`.tmp/deployment-probes` by default. The umbrella stores child file names and
SHA-256 digests, identity fingerprints, stable product identifiers, check
outcomes, and cleanup outcomes. It excludes email addresses, passwords, bearer
tokens, verification codes, invitation or QR secrets, and captured bodies.
All PowerShell probe files are written atomically with operator-only access
(`0600` on Unix or a protected current-operator ACL on Windows).

After proof, the rehearsal:

1. departs every synthetic non-owner Staff record through BunkFy's lifecycle
   policy, which removes the corresponding membership and access;
2. retires both empty synthetic properties;
3. suspends and then archives the workspace through its public lifecycle;
4. signs out every synthetic identity and confirms the old tokens are denied;
5. recreates Mailpit from the base topology, clearing its tmpfs mailbox and
   removing the loopback port.

When selected, the AdapterHost contribution additionally stops and removes its
container, disables its connection, revokes its credential, removes both
runtime volumes, cancels its synthetic reservation, and retires its room before
the parent property cleanup.

Join-source issuance retries only the explicit access-profile and property
projection readiness conflicts, preserving the same source id. Any other
conflict fails immediately instead of being hidden as convergence delay.

Auth currently has no public self-service identity deletion contract. The
random synthetic global identities therefore remain signed out, and that
limitation is explicit in evidence. A partial cleanup writes a non-passing
cleanup result and makes the command fail for operator follow-up.

A proof failure after mutation also writes the scrubbed umbrella record before
the command rethrows. It records only the bounded stage and stable problem code,
completed checks, created identifiers, child-evidence hashes that exist, and the
cleanup result; it never copies the exception message into evidence.
