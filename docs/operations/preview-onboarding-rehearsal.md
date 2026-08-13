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
`-IncludeGuestsStayHistory`, `-IncludeStaffEmployment`,
`-IncludePropertiesTopology`, `-IncludeIngestionConnectionLifecycle`,
`-IncludeIngestionConflictProposalLifecycle`,
`-IncludeDataRightsAccessExport`, `-IncludeRetention`, or
`-IncludeAdapterHost` to bind the corresponding deployed child proof into the
umbrella. Contributions may be selected together; room-backed contributions
own separate fixtures and coordinated cleanup. When Guests, Data Rights,
Reservations/Inventory, either Ingestion lifecycle, or AdapterHost is selected,
the umbrella first
discovers the single current engineering/example country policy exposed by
Preview, activates it once through the public Properties contract, and verifies
the exact effective binding. The contributors share this synthetic processing
prerequisite; it is not production country-policy approval.

The Data Rights contribution retains the generated owner password only as a
disposable `SecureString`, creates a fresh unassured login, completes password
authentication for the negative assurance control, temporarily enrolls TOTP
for the destructive-assurance session, and runs the protected Access Export
child before either applicant joins the workspace. The invitation applicant
therefore supplies a distinct authenticated nonmember session. Cleanup disables
the temporary TOTP factor with a one-use recovery code and verifies session
revocation. The child archives its synthetic Guest, but its encrypted artifact
remains scheduled for expiry and its case history remains under the configured
lifecycle.

The Guests stay-history contribution also runs before invitation acceptance, so
the invitation applicant supplies its authenticated nonmember denial control.
It creates one minimal canonical Guest and one Reservation against a dedicated
room, proves idempotent management and linking plus monotonic stay projection,
then retains the archived Guest and checked-out Reservation while the parent
retires the released room.

The Staff employment contribution also runs before invitation acceptance. It
creates one minimal unlinked profile, proves optimistic and idempotent profile
and assignment mutations, retains the assignment across suspension and resume,
then departs the profile and proves the current assignment closed. The child
owns that terminal Staff cleanup; the parent can then retire the property.

The Properties topology contribution runs immediately after workspace and
parent-property setup, while the owner session is fresh and the invitation
applicant is still a nonmember. It creates and retires a separate third
property, one room, and two beds. Inventory owns room and bed retirement; the
child owns terminal cleanup and does not modify either parent property or
activate a country policy.

The Ingestion connection lifecycle contribution runs after the shared Preview
engineering policy is active and before invitation acceptance. It discovers a
registered `RemotePolling` capability, creates and versionedly manages one
connection, issues and uses a one-time credential for an empty remote run,
revokes that credential, proves the retired token is denied, and leaves the
connection disabled. The applicant remains a genuine authenticated nonmember
for its tenant-denial assertion. Provider records, receipts, proposals, and
checkpoints remain in the separate AdapterHost contribution.

The Ingestion conflict and proposal lifecycle contribution provisions a
dedicated sellable room after the shared Preview engineering policy is active.
It proves automatic adapter authority, staff takeover, safe proposal creation,
newer-source supersession, replay-safe rejection and acceptance, Reservation
history provenance, and terminal cancellation. The child cancels its
reservation, revokes its credential, and disables its connection; the parent
then retires the room. Provider acquisition and parser correctness remain
outside this proof.

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

When selected, the Data Rights contribution additionally archives its
synthetic Guest before the parent retires the properties. It does not persist
the downloaded plaintext export, its hash, any credentials, or Data Rights
coordinates in either child or umbrella evidence.

When selected, the Guests stay-history contribution additionally reaches its
own terminal Guest, Reservation, and Inventory state before the parent retires
its dedicated room. Neither child nor umbrella evidence retains Guest,
Reservation, Inventory, or synthetic stay-date coordinates.

When selected, the Staff employment contribution additionally leaves its
synthetic unlinked profile departed with no current assignment before property
cleanup. Neither child nor umbrella evidence retains Staff, property,
operation, label, reason, or effective-date coordinates.

When selected, the Properties topology contribution leaves its own property,
room, and both beds retired before invitation acceptance. Neither child nor
umbrella evidence retains workspace, property, room, bed, topology-change,
operation, label, reason, time-zone, or policy coordinates.

When selected, the Ingestion connection lifecycle contribution leaves its
synthetic connection disabled, credential revoked, and zero-observation run
terminal before property cleanup. Neither child nor umbrella evidence retains
tenant or domain identifiers, adapter or source names, operation ids, labels,
opaque references, credentials, policy values, or checkpoints.

When selected, the Ingestion conflict and proposal lifecycle contribution
leaves its reservation cancelled, credential revoked, connection disabled, and
proposal history terminal before the parent retires its dedicated room. Neither
child nor umbrella evidence retains tenant or domain identifiers, guest data,
source records, adapter names, operation ids, credentials, or policy values.

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
