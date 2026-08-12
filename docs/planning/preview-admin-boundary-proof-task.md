# Preview Admin Boundary Proof Task

Status: planned
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

- [ ] Open the current Preview operations window without rebuilding images.
- [ ] Pass the static container-network and host-port isolation verifier.
- [ ] Pass the allowed deployed boundary observation from the VPS host.
- [ ] Pass the denied observation from a separate container network namespace.
- [ ] Bind both minimized records to one release and evidence-set ID.
- [ ] Close the operations window and verify its container and management
  network are absent.
- [ ] Record exact evidence hashes and limitations.

## Done When

Preview has one paired, credential-free management-boundary record for the
current release, the public edge reports no Admin route throughout, and the
temporary management surface is closed again. Hosted external-vantage evidence
remains a private deployment requirement.
