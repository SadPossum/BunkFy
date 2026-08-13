# Deployed Properties Topology Verification

Status: implemented, fixture verified, and exact-release Preview verified
Date: 2026-08-13

Use `eng/operations/verify-deployed-properties-topology.ps1` to prove the
Properties-owned physical topology lifecycle against one exact deployed
release. The verifier creates and updates one synthetic property and room, adds
two beds atomically, updates one bed, coordinates safe retirement through
Inventory, and retires the empty property.

The operator token must belong to one active workspace member authorized for
Properties and Inventory operations. The denied token must belong to a distinct
authenticated nonmember. Supply both as `SecureString` values or through:

- `BUNKFY_SMOKE_PROPERTIES_OPERATOR_TOKEN`; and
- `BUNKFY_SMOKE_PROPERTIES_DENIED_TOKEN`.

For a self-contained Preview proof, use the onboarding umbrella. It runs the
child before invitation acceptance, so the applicant remains a real nonmember:

```powershell
./eng/operations/rehearse-preview-onboarding.ps1 `
  -PublicOrigin http://127.0.0.1:8080 `
  -ExpectedReleaseId '<exact-release-id>' `
  -EnvironmentPath /protected/bunkfy-preview/.env `
  -AllowLoopbackHttp `
  -IncludePropertiesTopology `
  -Confirm:$false
```

For an independently prepared deployment:

```powershell
$operator = Read-Host 'Properties workflow operator token' -AsSecureString
$denied = Read-Host 'Properties workflow nonmember token' -AsSecureString

./eng/operations/verify-deployed-properties-topology.ps1 `
  -PublicOrigin 'https://candidate.example' `
  -ExpectedReleaseId 'release-20260813-01' `
  -WorkspaceId '11111111-1111-4111-8111-111111111111' `
  -OperatorAccessToken $operator `
  -DeniedAccessToken $denied `
  -Confirm:$false
```

The 31-check proof covers:

1. exact release, active workspace membership, and fail-closed nonmember
   property-directory access;
2. property creation, exact replay, conflicting operation reuse, detail and
   paged-directory visibility;
3. optimistic property update, stable replay, conflicting reuse, and stale
   write rejection;
4. equivalent room creation and update guarantees;
5. atomic two-bed creation, stable replay, conflict rejection, and complete
   directory visibility;
6. optimistic bed update with stable replay and stale-write enforcement;
7. property-retirement blocking while a room is active and rejection of direct
   room or bed retirement outside Inventory;
8. Inventory-coordinated bed retirement followed by room retirement, including
   monotonic process replay and zero active impact at completion;
9. terminal property retirement with stable replay and conflict rejection;
10. coherent retired property, room, bed, and effective processing projections;
    and
11. release identity continuity across the workflow.

Only exact projection absence and the documented in-progress retirement state
are retried with the same operation id and a bounded deadline. Business
conflicts, stale versions, changed replay identity, rejection, and cancellation
fail immediately.

The child owns cleanup even after a later assertion fails. Its property and
room must finish retired, both beds must be inactive, and no parent cleanup may
remain. Retired synthetic records remain for auditability.

Passing evidence is written atomically with private permissions under
`.tmp/deployment-probes` by default. It contains only release and transport
identity, bounded status/version relationships, topology counts, 31 named
checks, cleanup disposition, and fixed limitations. It excludes credentials,
identifiers, names, codes, labels, reasons, time-zone and country-policy values,
response bodies, and workflow timestamps. Existing output is not replaced
without `-Force`.

This proof does not activate or rebind a country policy. It does not prove
browser Properties UX, approved country/region/transfer/retention decisions,
occupied or manually blocked topology drain, high-contention scale, tenant
termination, or hosted-production operation. Loopback Preview output is
composition evidence only.

## Preview Evidence

On 2026-08-13, all 31 child checks passed through the VPS Preview loopback edge
for exact release `preview-workspace-access-estate-651107f`. The synthetic
property, room, and both beds finished retired; direct topology retirement was
denied; Inventory completed the bed-then-room workflow; and the final property
processing state was suspended by retirement. The production-admission parser
independently accepted the minimized child with SHA-256
`d83da9843778138fdef851a52e99583455b230f7971190cf95e30c8ba7241b45`.

The enclosing 10-check rehearsal removed both non-owner memberships, retired
both parent properties, archived the workspace, revoked all three identities'
sessions, and purged the Mailpit operator window. Its SHA-256 is
`38b16660bfa54c03caee7dca1dd2b20cab04332a98fba954ce6ecadcf734dceb`.
All four evidence files use mode `0600`, and the Properties child contains no
GUID, workspace, property, room, bed, topology-change, operation, label, reason,
time-zone, or policy coordinates.

The complete root operations gate passed once in 189.3 seconds after the exact
Preview rehearsal. These ignored loopback files prove exact-release Preview
composition, not hosted production.
