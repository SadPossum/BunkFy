# Preview Deployment Composition Safety Task

Status: implemented; live candidate rollout verification pending
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
- [ ] Start the retained candidate through the tracked Compose contract and
  prove post-rollout health and management-plane isolation.

## Local Evidence

- The protected VPS environment now declares its current `preview-local`
  release identity and exact public plus loopback hosts without changing the
  running containers.
- Local and remote-preview Compose resolution passes, wildcard-host and
  incompatible `-NoBuild` fixtures fail closed, and the complete operations
  verification fixture passes.

## Done When

- local preview defaults accept only local hosts;
- a remote preview must name its public host explicitly;
- `up`, backup, restore, and isolation checks can consume the same protected
  environment and tracked Compose file; and
- a prebuilt candidate can start without an accidental source rebuild.
