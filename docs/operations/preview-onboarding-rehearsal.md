# Preview Onboarding Rehearsal

Use `eng/operations/rehearse-preview-onboarding.ps1` to prove the composed
Preview registration, captured email verification, workspace invitation, and
QR enrollment paths against one exact release.

The rehearsal uses only:

- the public product API through the configured public origin; and
- Mailpit's short-lived loopback operator window.

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

Remote origins must use trusted HTTPS. The environment and Compose files are
validated before mutation. The script creates its own random `.test`
identities and passwords; none are accepted as parameters or written to
evidence.

## Evidence And Cleanup

One umbrella evidence file and two child probe files are written under
`.tmp/deployment-probes` by default. The umbrella stores child file names and
SHA-256 digests, identity fingerprints, stable product identifiers, check
outcomes, and cleanup outcomes. It excludes email addresses, passwords, bearer
tokens, verification codes, invitation or QR secrets, and captured bodies.

After proof, the rehearsal:

1. removes every non-owner membership from its dedicated workspace;
2. archives the workspace;
3. signs out every synthetic identity and confirms the old tokens are denied;
4. recreates Mailpit from the base topology, clearing its tmpfs mailbox and
   removing the loopback port.

Auth currently has no public self-service identity deletion contract. The
random synthetic global identities therefore remain signed out, and that
limitation is explicit in evidence. A partial cleanup writes a non-passing
cleanup result and makes the command fail for operator follow-up.
