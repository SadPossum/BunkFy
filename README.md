# BunkFy

[![Validate](https://github.com/SadPossum/BunkFy/actions/workflows/validate.yml/badge.svg?branch=dev)](https://github.com/SadPossum/BunkFy/actions/workflows/validate.yml)
[![Security Baseline](https://github.com/SadPossum/BunkFy/actions/workflows/security.yml/badge.svg?branch=dev)](https://github.com/SadPossum/BunkFy/actions/workflows/security.yml)
[![CodeQL](https://github.com/SadPossum/BunkFy/actions/workflows/codeql.yml/badge.svg?branch=dev)](https://github.com/SadPossum/BunkFy/actions/workflows/codeql.yml)

BunkFy is an open-source property management system for hostels.

This repository is the root superproject. It owns full-stack composition, local orchestration, scripts, documentation, and submodule pointers. Product implementation lives in app repositories mounted as submodules.

## Repository Shape

```text
BunkFy/
  src/
    BunkFy.AppHost/          # Aspire composition root
    BunkFy.ServiceDefaults/  # root-owned hosting defaults
  apps/
    backend/                 # submodule: SadPossum/BunkFy.Backend
    web/                     # submodule: SadPossum/BunkFy.Web
  docs/
  eng/
```

## First Run

```powershell
git clone --recursive https://github.com/SadPossum/BunkFy.git
cd BunkFy
.\eng\bootstrap.ps1
.\eng\verify.ps1
```

If the repository was cloned without submodules:

```powershell
git submodule update --init --recursive
.\eng\bootstrap.ps1
```

## Daily Workflow

The default development branch is `dev` across the root, backend, and web repositories. `main` can remain a stable baseline when the project starts cutting releases.

Start the full local graph:

```powershell
.\eng\run-aspire.ps1
```

For the single-node, production-shaped preview path, use the concise [preview deployment runbook](docs/operations/preview-deployment.md). Exact candidate bytes cross into an operator-selected registry through the [image candidate promotion boundary](docs/operations/image-candidate-promotion.md), while the [deployed rollback rehearsal](docs/operations/deployed-release-rollback-rehearsal.md) proves candidate-to-rollback-to-candidate convergence without rebuilding images. External release checks include the release-aware [public edge probe](docs/operations/deployed-public-edge-verification.md), the paired [Admin API boundary verifier](docs/operations/deployed-admin-boundary-verification.md), the mutation-bearing [workspace invitation verifier](docs/operations/deployed-workspace-invitation-verification.md), the [workspace QR enrollment verifier](docs/operations/deployed-workspace-enrollment-verification.md), the [workspace-access seed estate operator](docs/operations/preview-workspace-access-seed-estate.md), the [Operations Notifications verifier](docs/operations/deployed-operations-notifications-verification.md), the [Reservations and Inventory lifecycle verifier](docs/operations/deployed-reservations-inventory-verification.md), the [Guests stay-history verifier](docs/operations/deployed-guests-stay-history-verification.md), the [Staff employment verifier](docs/operations/deployed-staff-employment-verification.md), the [Data Rights Access Export verifier](docs/operations/deployed-data-rights-access-export-verification.md), the [deployed AdapterHost verifier](docs/operations/deployed-adapter-host-verification.md), the [deployed Retention verifier](docs/operations/deployed-retention-verification.md), and the final [browser onboarding rehearsal](docs/operations/deployed-workspace-browser-rehearsal.md). Bind the complete candidate evidence set for private approval with the [Production admission evidence boundary](docs/operations/production-admission-evidence.md).

Exercise the checked-in backup mechanics against a disposable clone with the [preview recovery rehearsal](docs/operations/preview-recovery-rehearsal.md); its evidence is intentionally narrower than a hosted provider restore drill.

The Aspire AppHost starts the shared backend graph (PostgreSQL, NATS JetStream, MinIO, a one-shot migration gate, API, and opt-in worker/admin resources) plus the web client at `http://localhost:5173`. API and background processes wait for successful migrations, and backend-only and full-stack AppHosts consume the same composition code so their infrastructure and worker settings cannot drift.

Run the integrated validation pass:

```powershell
.\eng\verify.ps1
```

The root verification checks backend and web builds/tests, solution drift, and the checked-in OpenAPI snapshot/generated TypeScript contract. After an intentional public API change, refresh those web artifacts with:

```powershell
.\eng\update-web-contracts.ps1
```

Repository security policy and private reporting are documented in [SECURITY.md](SECURITY.md). The aggregate security workflow scans the pinned product source set and retains SARIF plus a CycloneDX SBOM; CodeQL analyzes both C# and JavaScript/TypeScript.

Inspect root and submodule state:

```powershell
.\eng\submodule-status.ps1
```

Submodules are pinned by commit; Git does not update them automatically when upstream branches move. Sync all configured submodules to their `.gitmodules` branch tips:

```powershell
.\eng\sync-submodules.ps1
```

`.\eng\verify.ps1` runs `eng/guard-submodules-latest.ps1` by default, so stale submodule pointers fail validation. The compatibility alias `.\eng\sync-github-modules.ps1` runs the same sync command.

## App Repositories

- Backend: https://github.com/SadPossum/BunkFy.Backend
- Web: https://github.com/SadPossum/BunkFy.Web

The backend app consumes GMA as editable source through nested submodules under `apps/backend/gma/`. Root bootstrap initializes submodules recursively and delegates backend source-root generation to `apps/backend/eng/gma-bootstrap.ps1`.

## Planning

The staged setup and product workflow plan lives in [docs/planning/bunkfy-repository-stack-and-workflow-plan.md](docs/planning/bunkfy-repository-stack-and-workflow-plan.md).
