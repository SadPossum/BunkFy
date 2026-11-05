# Deployed Reservations And Inventory Verification

Status: schema-v3 implementation and fixture verified; exact-release Preview pending
Date: 2026-08-13

Use this mutation-bearing probe to verify one deployed BunkFy release through
the direct staff reservation lifecycle. The probe uses a caller-selected smoke
workspace, property, sellable inventory unit, and future half-open stay range.

The operator token must belong to one active member of the target workspace and
must be allowed to read the property and Inventory and to create, read, cancel,
check in, and check out Reservations for that property. Supply it as a secure
parameter or through `BUNKFY_SMOKE_RESERVATION_OPERATOR_TOKEN`.
Before mutation, the verifier reuses that authenticated token under a fresh,
unrelated workspace scope and requires Inventory availability to return 403.

The target property must have an effective country-policy binding accepted by
the running API and Worker. Reservation creation retries only
`Reservations.CountryPolicyDenied.MissingBinding` with the same operation id,
because that denial can represent asynchronous Properties projection
convergence. Any other policy denial is treated as deployment or policy drift
and fails immediately.

For a self-contained Preview proof, let the onboarding rehearsal contribute a
dedicated property room and operator:

```powershell
./eng/operations/rehearse-preview-onboarding.ps1 `
  -PublicOrigin http://127.0.0.1:18080 `
  -ExpectedReleaseId <candidate-release-id> `
  -EnvironmentPath /secure/path/preview.env `
  -AllowLoopbackHttp `
  -IncludeReservationsInventory `
  -Confirm:$false
```

The contribution writes `*.reservations-inventory.json`, binds its SHA-256 into
the onboarding umbrella, and retires the temporary room after the checked-out
reservation has released its allocation. The retained Reservation is terminal
and synthetic; the parent then retires the properties, archives the workspace,
and revokes every synthetic session.
The parent uses Preview's digest-pinned engineering/example policy solely for
this synthetic proof; it does not provide production approval evidence.

```powershell
$token = Read-Host 'Reservation smoke operator access token' -AsSecureString

./eng/operations/verify-deployed-reservations-inventory.ps1 `
  -PublicOrigin 'https://preview.example.test' `
  -ExpectedReleaseId 'release-2026-08-06.1' `
  -WorkspaceId '11111111-1111-4111-8111-111111111111' `
  -PropertyId '22222222-2222-4222-8222-222222222222' `
  -InventoryUnitId '33333333-3333-4333-8333-333333333333' `
  -Arrival '2026-08-10' `
  -Departure '2026-08-12' `
  -OperatorAccessToken $token
```

The selected unit must be uniquely available for the range before the probe.
The probe then verifies:

1. the authenticated token cannot read Inventory under an unrelated workspace
   scope;
2. the token has one active workspace membership and can read the selected
   property;
3. the unit is available before creation;
4. asynchronous Inventory allocation converges to `Confirmed`;
5. an exact create retry resolves to the current stable reservation receipt;
6. availability reports the allocated unit as unavailable;
7. check-in is recorded for the arrival business date;
8. an exact check-in retry returns the current receipt without a second action;
9. checkout and allocation release converge to `CheckedOut`;
10. an exact checkout retry returns the current terminal receipt without a
   second release;
11. the unit becomes available again; and
12. the public API release identity does not change during the workflow.

The create request uses a generated operation id as the reservation id, and
each lifecycle action uses its own generated operation id. Retries preserve the
original action identity and payload. The probe uses only a fixed synthetic guest
label. It does not create or link a durable Guest Record,
and it sends no email, phone, notes, source reference, or real guest data. A
passing run leaves one terminal synthetic reservation for auditability and no
active allocation. If the run fails after creation, it best-effort cancels an
unoccupied reservation or checks out an occupied one.

Passing JSON is written atomically under `.tmp/deployment-probes` by default.
Schema v3 contains the origin, release identity, admission evidence reference,
transport, named checks,
explicit limitations, and closed workflow and cleanup summaries. It records a
direct booking that moved through confirmed, checked-in, and checked-out state;
stable create/check-in/checkout replay; available-confirmed-released allocation;
no durable Guest Record; one retained terminal synthetic Reservation; zero
active allocations; an available selected unit; and no topology mutation. It
does not retain workspace, property, room, inventory, allocation, reservation,
membership, subject, actor, operation, Guest, date, token, label, payload,
header, or raw-response values. The file is private and non-overwriting by
default.

Trusted HTTPS is the only production-admission transport. A real local Preview
run reports `loopback-http-preview`; the production-admission test fixture uses
`loopback-http-fixture`. Keep the release-bound child with the candidate's
other production-admission proofs.

The probe exercises API behavior and asynchronous module integration. It does
not exercise browser rendering, Guest Record creation, or concurrent
overbooking contention.

## Superseded VPS Preview Evidence

On 2026-08-11, the schema-v1 probe passed all eleven checks through the VPS Preview's
trusted HTTPS origin for release `preview-runtime-hardening-20260811`. The
production-admission parser independently accepted the child record with
SHA-256
`aa1933f5a7c64030b65977717359675a32ca547e1504ffc7f396a1438b361c77`.

The enclosing rehearsal retired the temporary room after allocation release,
removed both joined memberships, retired both synthetic properties, archived
the workspace, revoked all three sessions, and purged and closed the Mailpit
operator window. The terminal synthetic reservation remains inside the
archived smoke workspace as declared by the verifier. The evidence is retained
only in ignored VPS working state and does not admit the final `f27ce996`
candidate, satisfy the schema-v3 admission contract, prove browser behavior or
durable Guest creation, or exercise concurrent overbooking contention.
