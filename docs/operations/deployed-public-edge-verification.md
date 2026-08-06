# Deployed Public Edge Verification

Status: implemented and locally verified
Date: 2026-08-06

## Goal

Provide one deployment-neutral, externally runnable check for the behavior that
BunkFy's public HTTPS origin exposes. The check belongs to the composed product
root: it validates the web edge and public API together and does not add a
business-domain or GMA responsibility.

## Observable Contract

The probe will fail closed unless one origin:

- uses HTTPS with ordinary platform certificate validation, except for an
  explicit loopback-only fixture mode;
- serves the web application and the complete checked-in browser security
  header policy;
- exposes a healthy edge at `/healthz`;
- proxies `/api/smoke` to the BunkFy public API and returns the expected bounded
  service identity;
- returns `404` for a representative Admin API route on the public origin; and
- rejects an untrusted `Host` value instead of forwarding a successful public
  API response.

Redirects are not followed. Response bodies are bounded before parsing, and
the retained result contains statuses and check names rather than response
bodies or raw headers.

## Evidence Boundary

The result is one external observation at one time. It does not prove:

- which source commit or image digest is deployed;
- registry promotion, signatures, or private deployment approval;
- private network, IAM, secret-store, object-store, database, broker, or key
  protection;
- Admin API reachability from an authorized private network;
- shared rate limiting, replica behavior, alert delivery, backup, restore, or
  rollback; or
- authenticated multi-account onboarding, access, notification, and adapter
  workflows.

Those controls remain private deployment evidence. In particular, an operator
cannot turn a supplied commit or digest string into release proof through this
probe; release identity must come from the attested candidate and private
promotion record.

## Delivery

Run the probe from outside the deployment's private network so it observes the
same public route as a browser:

```powershell
./eng/operations/verify-deployed-public-edge.ps1 `
  -PublicOrigin https://bunkfy.example/
```

The origin must not contain a path, query, fragment, or credentials. Redirects
are rejected rather than followed. The default 15-second timeout is applied to
each bounded request. A custom output path may be supplied with `-OutputPath`;
otherwise the result is written below ignored `.tmp/deployment-probes`.

`-AllowLoopbackHttp` exists only for a loopback address and the deterministic
fixture. It cannot enable plain HTTP for a remote host. Do not treat a loopback
result as hosted edge evidence.

The versioned JSON output records the origin, transport class, five check names
and statuses, and three explicit limitations. It excludes response bodies, raw
headers, credentials, source commits, and image digests. The file is written
atomically only after all checks pass; an existing file requires `-Force` and a
reparse-point target is rejected.

Repository verification runs `eng/test-deployed-public-edge.ps1`. The fixture
proves the valid loopback path and rejection of a missing security header, a
publicly reachable Admin route, a successful untrusted-Host request, policy
directives outside the checked-in CSP or Permissions-Policy, and insecure
non-loopback HTTP. It does not contact a deployed environment.

## Deferred Deployment Proof

The [deployed workspace invitation verifier](deployed-workspace-invitation-verification.md)
and [deployed workspace enrollment verifier](deployed-workspace-enrollment-verification.md)
cover the API-level, two-account invitation, QR approval/rejection, and
least-privilege paths with separate short-lived credentials and explicit
test-data lifecycle. Browser rendering, registration, and email or OAuth
delivery remain deployment-owned checks. This public edge probe must not
accept credentials or mutate tenant data.
