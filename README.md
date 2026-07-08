# BunkFy

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
  gma/
    framework/               # submodule: SadPossum/GMA-Framework
    modules/
      administration/
      auth/
      files/
      notifications/
      task-runtime/
      tenancy/
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

The Aspire AppHost is currently a composition placeholder. Backend and web runtime resources will be added after those repositories move from foundation structure into runnable app shells.

Run the integrated validation pass:

```powershell
.\eng\verify.ps1
```

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

The backend app consumes GMA as editable source. In this root checkout, `eng/bootstrap.ps1` writes `apps/backend/Gma.SourceRoots.props` so backend project references resolve to the root-mounted `gma/` submodules.

## Planning

The staged setup and product workflow plan lives in [docs/planning/bunkfy-repository-stack-and-workflow-plan.md](docs/planning/bunkfy-repository-stack-and-workflow-plan.md).
