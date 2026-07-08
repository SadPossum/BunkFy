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

## App Repositories

- Backend: https://github.com/SadPossum/BunkFy.Backend
- Web: https://github.com/SadPossum/BunkFy.Web

The backend app consumes GMA as editable source. In this root checkout, `eng/bootstrap.ps1` writes `apps/backend/Gma.SourceRoots.props` so backend project references resolve to the root-mounted `gma/` submodules.

## Planning

The staged setup and product workflow plan lives in [docs/planning/bunkfy-repository-stack-and-workflow-plan.md](docs/planning/bunkfy-repository-stack-and-workflow-plan.md).
