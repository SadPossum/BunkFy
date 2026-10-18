# Preview Deployment Composition Safety Task

Status: implemented and verified on the VPS preview
Date: 2026-08-10

## Goal

Keep the production-shaped VPS preview on one repository-owned Compose
contract while allowing its protected environment file and prebuilt image
selection to live outside the checkout. Backup, restore, isolation, and normal
start commands must resolve the same service configuration.

## Finding

The VPS preview currently uses a private copy of `compose.yaml` to declare its
public host and avoid rebuilding images. Repository backup and restore commands
hardwire the tracked Compose file. A backup can therefore restart services from
a different HTTP configuration than the one that was running before the
backup.

## Boundary

- The tracked preview Compose file remains the only service-topology contract.
- The private environment file owns public origin, allowed hosts, ports,
  release identity, and secrets.
- Preview images may be built from the checkout or loaded as already-built
  candidate bytes; `preview.ps1` must make that choice explicit.
- This does not turn Preview into Production or claim registry, rollback,
  recovery, or hosted-admission evidence.

## Delivery

- [x] Make preview host filtering explicit, environment-driven, and fail
  closed without wildcard hosts.
- [x] Let `preview.ps1` accept an external environment file and an explicit
  no-build startup mode.
- [x] Guard the local and remote-preview configurations in the operations
  verification fixture.
- [x] Align the runbook and VPS environment and prove the tracked Compose
  configuration before candidate rollout.
- [x] Start the retained candidate through the tracked Compose contract and
  prove post-rollout health and management-plane isolation.

## Verification Evidence

- Retained source/image candidate
  `6fcbcc0694d0f6097740e749eb8ed5e0c5058335` was strictly verified and started
  through the tracked Compose contract with the protected external environment.
  API and Worker run backend image
  `sha256:3f9dfeb250f5d63436efe12aa09bf8c2763fbcfcdc601fa9bc0d5fc55b38223a`;
  Web runs
  `sha256:e53616330be70b4c38ce4ddc0421b62fd16a999c5ba920eff4bf7ee1753153da`.
- Pre-rollout backup is retained at
  `/home/artem/deployments/bunkfy-backups/preview-before-6fcbcc0-20260810T163550Z`.
- The isolated PostgreSQL migration rehearsal applied all 221 migrations,
  observed zero pending migrations after apply, passed an idempotent rerun, and
  removed its resources. Evidence is retained with the candidate under
  `migration-evidence/20260810T163828Z-41f5bef701c5.json`.
- The trusted-HTTPS public-edge probe passed all six checks for release
  `candidate-6fcbcc0694d0`, including browser policy, health, API composition,
  public Admin absence, and forged-Host rejection. Evidence is retained under
  `deployed-evidence/public-edge.json`.
- The preview isolation verifier passed with the Admin API bound only to the
  management plane and loopback. The temporary Admin session was closed and
  its container removed immediately after verification.
- Local and external-environment Compose resolution passes; wildcard hosts and
  incompatible `-NoBuild` use fail closed; the complete operations fixture
  passes.

The running image bytes still correspond to candidate `6fcbcc0`. Subsequent
repository changes in this slice affect deployment tooling and documentation,
not those images. A production promotion must nevertheless generate and admit
fresh exact-revision evidence rather than treating this preview proof as a
production release record.

## Done When

- local preview defaults accept only local hosts;
- a remote preview must name its public host explicitly;
- `up`, backup, restore, and isolation checks can consume the same protected
  environment and tracked Compose file; and
- a prebuilt candidate can start without an accidental source rebuild.
