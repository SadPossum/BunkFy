# Deployed Reservations And Inventory Verification

Use this mutation-bearing probe to verify one deployed BunkFy release through
the direct staff reservation lifecycle. The probe uses a caller-selected smoke
workspace, property, sellable inventory unit, and future half-open stay range.

The operator token must belong to one active member of the target workspace and
must be allowed to read the property and Inventory and to create, read, cancel,
check in, and check out Reservations for that property. Supply it as a secure
parameter or through `BUNKFY_SMOKE_RESERVATION_OPERATOR_TOKEN`.

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

1. the token has one active workspace membership and can read the selected
   property;
2. the unit is available before creation;
3. asynchronous Inventory allocation converges to `Confirmed`;
4. an exact create retry resolves to the current stable reservation receipt;
5. availability reports the allocated unit as unavailable;
6. check-in is recorded for the arrival business date;
7. an exact check-in retry returns the current receipt without a second action;
8. checkout and allocation release converge to `CheckedOut`;
9. an exact checkout retry returns the current terminal receipt without a
   second release;
10. the unit becomes available again; and
11. the public API release identity does not change during the workflow.

The create request uses a generated operation id as the reservation id, and
each lifecycle action uses its own generated operation id. Retries preserve the
original action identity and payload. The probe uses only a fixed synthetic guest
label. It does not create or link a durable Guest Record,
and it sends no email, phone, notes, source reference, or real guest data. A
passing run leaves one terminal synthetic reservation for auditability and no
active allocation. If the run fails after creation, it best-effort cancels an
unoccupied reservation or checks out an occupied one.

Passing JSON is written atomically under `.tmp/deployment-probes` by default.
It contains the origin, release identity, transport, named checks, and explicit
limitations only. It does not retain workspace, property, inventory,
reservation, staff, guest, date, token, or raw-response values. Keep this
release-bound evidence with the candidate's other production-admission proofs.

The probe exercises API behavior and asynchronous module integration. It does
not exercise browser rendering, Guest Record creation, or concurrent
overbooking contention.
