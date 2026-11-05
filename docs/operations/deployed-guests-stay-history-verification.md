# Deployed Guests Stay-History Verification

Status: schema-v2 implementation and fixture verified; prior Preview proof historical
Date: 2026-08-13

Use `eng/operations/verify-deployed-guests-stay-history.ps1` to prove the
smallest complete durable Guest workflow against one exact deployed release.
The verifier creates and versionedly updates one synthetic canonical Guest,
links it as the primary participant of one Reservation, observes the
Guests-owned stay-history projection through check-in and check-out, and then
archives the Guest.

The operator token must belong to one active member of the target workspace and
must be authorized for the selected property, Guests, Reservations, and
Inventory. The denied token must belong to a distinct authenticated nonmember.
Both are accepted as `SecureString` values or through:

- `BUNKFY_SMOKE_GUESTS_OPERATOR_TOKEN`; and
- `BUNKFY_SMOKE_GUESTS_DENIED_TOKEN`.

For a self-contained Preview proof, use the onboarding umbrella. It activates
Preview's engineering/example property policy, creates one dedicated sellable
room, and runs this child before the invitation applicant joins the workspace:

```powershell
./eng/operations/rehearse-preview-onboarding.ps1 `
  -PublicOrigin http://127.0.0.1:8080 `
  -ExpectedReleaseId '<exact-release-id>' `
  -EnvironmentPath /protected/bunkfy-preview/.env `
  -AllowLoopbackHttp `
  -IncludeGuestsStayHistory `
  -Confirm:$false
```

For an independently prepared deployment:

```powershell
$operator = Read-Host 'Guests workflow operator token' -AsSecureString
$denied = Read-Host 'Guests workflow nonmember token' -AsSecureString

./eng/operations/verify-deployed-guests-stay-history.ps1 `
  -PublicOrigin 'https://candidate.example' `
  -ExpectedReleaseId 'release-20260813-01' `
  -WorkspaceId '11111111-1111-4111-8111-111111111111' `
  -PropertyId '22222222-2222-4222-8222-222222222222' `
  -InventoryUnitId '33333333-3333-4333-8333-333333333333' `
  -Arrival '2026-10-26' `
  -Departure '2026-10-28' `
  -OperatorAccessToken $operator `
  -DeniedAccessToken $denied `
  -Confirm:$false
```

The selected unit must be uniquely available for the future stay range. The
verifier then proves:

1. exact release, membership, property, and Inventory preconditions;
2. fail-closed nonmember Guest-directory access;
3. minimal Guest creation, stable exact replay, and conflicting operation-id
   rejection;
4. active-directory visibility plus optimistic, idempotent update behavior,
   including conflicting replay and stale-version rejection;
5. Reservation allocation and stable primary-Guest link replay;
6. monotonic Guests-owned stay-history convergence through `Confirmed`,
   `CheckedIn`, and `CheckedOut`;
7. terminal Reservation retention and Inventory release;
8. stable Guest archive replay, active-directory removal, and archived history
   availability; and
9. release identity continuity across the complete workflow.

The child is authoritative for reaching its terminal cleanup state even when a
later assertion fails: the Guest must be archived, the Reservation must be
cancelled or checked out as appropriate, and Inventory must be released. The
Preview parent then retires the dedicated room and cleans up the surrounding
workspace.

Passing evidence is written atomically with private permissions under
`.tmp/deployment-probes` by default. Schema v2 contains only release, admission,
and transport identity, bounded workflow summaries, 19 named checks, cleanup disposition, and
fixed limitations. It excludes credentials, personal data, response bodies,
synthetic stay dates, and workspace, property, Inventory, Guest, or Reservation
identifiers. Existing evidence is never replaced without explicit `-Force`.

The proof does not exercise browser Guest workflows, deduplication, merging,
consent, concurrent participant replacement, or concurrent overbooking. It
retains one archived synthetic Guest and one checked-out synthetic Reservation
for auditability. Loopback Preview output is composition evidence only and
cannot satisfy hosted-production admission.

## Preview Evidence

On 2026-08-13, all 19 child checks passed through the VPS Preview loopback edge
for exact release `preview-workspace-access-estate-651107f`. The Guest finished
archived, the linked Reservation and stay projection finished checked out,
Reservation versions remained monotonic, and Inventory was released. The
production-admission parser independently accepted the minimized child with
SHA-256
`ddea07066941a2e54bc032028142dea2bb79baeb886cb073f1193504d142e18c`.

The enclosing 11-check rehearsal removed both non-owner memberships, retired
the dedicated room and both properties, archived the workspace, revoked all
three identities' sessions, and purged the Mailpit operator window. Its SHA-256
is `172a26c2ca37a0f374cdba8058c91ad286c75d3ea09ae9f3c1a523812a8ef0b9`.

The first live attempt exposed an expected projection interval that the shared
room fixture had treated as terminal: Inventory returned `404` immediately
after Properties accepted room creation. The helper now treats that absence as
a bounded convergence state and cleanup waits for projection before requesting
retirement. The focused partial-state fixture passed, and the failed rehearsal's
archived estate was separately reconciled through the exact candidate's
authorized Admin CLI, leaving zero active properties or room topology.

These ignored files prove exact-release Preview composition, not hosted
production. Their loopback transport is accepted by the admission parser only
with the fixture allowance and cannot fill the final production-admission input.
