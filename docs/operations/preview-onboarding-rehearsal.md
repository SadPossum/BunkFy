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

Add `-IncludeOperationsNotifications` or `-IncludeReservationsInventory` to
provision the corresponding temporary sellable-room fixture and bind that
deployed child proof into the umbrella. The two contributions may be selected
together; each owns a separate room and coordinated cleanup result.
The Reservations/Inventory contribution first discovers the single current
engineering/example country policy exposed by Preview, activates it through the
public Properties contract, and verifies the exact effective binding. This is a
synthetic processing prerequisite, not production country-policy approval.

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

After proof, the rehearsal:

1. departs every synthetic non-owner Staff record through BunkFy's lifecycle
   policy, which removes the corresponding membership and access;
2. retires both empty synthetic properties;
3. suspends and then archives the workspace through its public lifecycle;
4. signs out every synthetic identity and confirms the old tokens are denied;
5. recreates Mailpit from the base topology, clearing its tmpfs mailbox and
   removing the loopback port.

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
