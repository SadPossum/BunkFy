# Preview Admin Boundary Proof Task

Status: completed for Preview loopback composition
Date: 2026-08-12

## Goal

Prove the current Preview management window is reachable and authentication
gated only from the VPS loopback boundary, absent from the public edge, and
unreachable from a separate container network namespace while the Admin API is
running.

## Boundary

- The BunkFy deployment owns this proof; no domain or GMA behavior changes.
- Use the existing credential-free deployed Admin boundary verifier for both
  vantage points with one evidence-set ID.
- Run the allowed observation on the VPS host. Run the denied observation in a
  hardened disposable container that can reach the public HTTPS origin but
  cannot share the host loopback namespace.
- Mount the repository and host PowerShell runtime read-only. Mount only the
  ignored evidence directory writable; pass no token or Preview environment
  file into the denied runner.
- Close the operations window and remove its dedicated management network after
  the observations.
- This proves Preview loopback composition, not a hosted firewall, VPN, private
  DNS, TLS-protected management origin, or external operator vantage.

## Delivery

- [x] Open the current Preview operations window without rebuilding images.
- [x] Pass the static container-network and host-port isolation verifier.
- [x] Pass the allowed deployed boundary observation from the VPS host.
- [x] Pass the denied observation from a separate container network namespace.
- [x] Bind both minimized records to one release and evidence-set ID.
- [x] Close the operations window and verify its container and management
  network are absent.
- [x] Record exact evidence hashes and limitations.

## Verification Evidence

- `verify-preview-isolation.ps1` passed while the operations window was open,
  including exact service networks, loopback-only host bindings, no direct
  public API port, public-edge-to-Admin network denial, and public Admin `404`.
- Evidence set `d6bb74ec-d80b-4c62-9070-fc9a505f4780` binds both observations to
  release `preview-runtime-hardening-20260811`, public origin
  `https://213.109.163.152`, and Admin origin `http://127.0.0.1:5195`.
- The allowed host observation passed five checks: Admin health returned `200`,
  anonymous audit returned `401`, and the release remained continuous. Local
  evidence SHA-256 is
  `ee77420c557429912a473aa7cf49acbe5d2f9067f6bc9bd61b29656097ca7334`.
- The hardened denied runner used a separate Docker bridge namespace with the
  repository and host PowerShell runtime mounted read-only and no credentials
  or Preview environment. It passed four checks and classified Admin health as
  `connection-unreachable`. Local evidence SHA-256 is
  `8f8ece9ee70cccfeb50f8342606f289c008ec5ebdfa2fde69f0b6ce7b86b52e9`.
- Both records are retained under ignored `.tmp/deployment-probes`. The Admin
  container and dedicated management network were removed, and the public edge
  still returns `404` for `/api/admin/audit/`.
- This is paired Preview namespace evidence. Hosted promotion still needs an
  approved internal HTTPS Admin origin, real external vantage, infrastructure
  policy review, and an authenticated short-lived operator workflow.

## Done When

Preview has one paired, credential-free management-boundary record for the
current release, the public edge reports no Admin route throughout, and the
temporary management surface is closed again. Hosted external-vantage evidence
remains a private deployment requirement.
