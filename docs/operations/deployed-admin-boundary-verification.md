# Deployed Admin API Boundary Verification

Use this credential-free probe to prove that a deployed BunkFy Admin API is
absent from the public edge, reachable from an approved management network,
unreachable or explicitly denied from an external network, and still protected
by authentication after the network boundary admits a request.

The reusable private-network middleware remains owned by GMA. This verifier is
BunkFy deployment evidence because it observes the composed public edge,
management route, DNS, firewall, proxy, and TLS behavior of one candidate.

## Preconditions

Use the exact promoted candidate and one stable Admin origin. The public and
Admin origins must have distinct authorities and use trusted HTTPS. Plain HTTP
is accepted only by the repository's explicit loopback fixture mode.

Prepare two operator vantage points:

- an approved host on the management network that can reach the Admin API; and
- a host outside every approved management network.

Generate one correlation id and use it unchanged for both runs:

```powershell
$evidenceSetId = [Guid]::NewGuid()
```

The verifier accepts no access token and performs only `GET` requests. Do not
route the Admin origin through the public edge merely to make the check
reachable.

## Approved-Network Run

Run from the approved management host:

```powershell
./eng/operations/verify-deployed-admin-boundary.ps1 `
  -PublicOrigin https://candidate.example `
  -ExpectedReleaseId <promotion-record-release-id> `
  -AdminOrigin https://admin.candidate.internal `
  -ExpectedAdminReachability Allowed `
  -EvidenceSetId $evidenceSetId
```

This run requires Admin `/health` to return `200`, then requires an anonymous
request to `/api/admin/audit/` to return `401` or `403`. A private-network
denial on the supposedly approved path is rejected.

## External-Network Run

Run from the external host with the same candidate origins and correlation id:

```powershell
./eng/operations/verify-deployed-admin-boundary.ps1 `
  -PublicOrigin https://candidate.example `
  -ExpectedReleaseId <promotion-record-release-id> `
  -AdminOrigin https://admin.candidate.internal `
  -ExpectedAdminReachability Denied `
  -EvidenceSetId $evidenceSetId
```

The denied run accepts either:

- the exact bounded `403` Problem Details response produced by GMA's
  `Http.PrivateNetworkRequired` middleware; or
- DNS failure, connection refusal, or a bounded timeout caused by the private
  network boundary.

A TLS failure is rejected. An invalid or expired certificate is a broken
management endpoint, not proof that private reachability is correctly
isolated.

## Checks And Evidence

Every run requires public `/api/smoke` to report the expected release before and
after the boundary checks, public `/healthz` to return an empty `204`, and public
`/api/admin/audit/` to return `404`. Responses are never redirected, cookies are
disabled, and each body is capped at 64 KiB.

Passing JSON is written atomically under `.tmp/deployment-probes` by default.
It records the release identity, two origins, vantage mode, correlation id,
bounded observation classes, checks, and limitations. It excludes response
bodies, headers, trace ids, credentials, exception details, and authenticated
Admin data.

Promotion requires one passing `allowed` file and one passing `denied` file
with the same `evidenceSetId`, origins, and exact candidate release record. A
single file is only a vantage-point observation and is insufficient boundary
proof. Keep the paired files with the private deployment record; do not commit
environment-specific origins unless that is already approved policy.

The pair does not inspect firewall or proxy configuration and does not execute
an authenticated Admin operation. Use infrastructure review plus an approved
short-lived credential workflow for those separate facts.

## Repository Fixture

`eng/test-deployed-admin-boundary.ps1` exercises allowed access, exact
middleware denial, and an unreachable Admin origin. It also proves rejection
of anonymous Admin exposure, a reachable endpoint claimed as denied, malformed
Problem Details, shared public/Admin authority, evidence leakage, and insecure
non-loopback HTTP. It does not contact a deployed environment.
