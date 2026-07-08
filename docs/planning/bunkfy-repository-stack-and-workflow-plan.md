# BunkFy Repository, Stack, and Workflow Plan

Status: draft planning task
Date: 2026-07-08
Audience: future BunkFy development threads, maintainers, and contributors

## Current Checkpoint

The first implementation milestone should establish repositories, submodules, documentation structure, scripts, CI, and source-root wiring only. It should not implement the product frontend, product modules, or a full runnable app graph yet.

The root Aspire AppHost can exist as a placeholder composition project, but backend and frontend runtime resources should be added later, after the backend and web repositories graduate from foundations into runnable shells.

## Purpose

BunkFy is planned as a serious production-grade, open-source property management system for hostels. This document captures the intended repository setup, stack, development workflow, research points, and staged implementation plan based on the initial architecture discussion.

The main decision is to use a root BunkFy superproject as the composition and operations repo, while keeping the backend app, frontend app, and GMA framework/modules as separate Git repositories mounted as submodules.

The guiding idea is simple:

- The root repo owns composition, local orchestration, documentation, scripts, and dependency pointers.
- The backend repo owns PMS backend code, API hosts, domain modules, migrations, backend tests, and backend CI.
- The frontend repo owns the browser application, frontend tests, generated API client, and frontend CI.
- GMA repos remain mounted under `gma/` and are treated as editable source dependencies.

This gives BunkFy the benefits of separate app repositories while keeping day-to-day local development manageable through one root checkout and one Aspire graph.

## Current Known Decisions

### Product Direction

BunkFy is an open-source hostel PMS. It should be designed for real operators, not as a demo app. The UI should feel like an operational tool: dense, reliable, fast to scan, and efficient for repeated work.

Likely first-class product areas:

- Properties, buildings, rooms, beds, and bed inventory.
- Reservations, booking lifecycle, cancellations, no-shows, check-in, and check-out.
- Guests, identity documents, notes, stays, and communication history.
- Rates, restrictions, occupancy, availability, and simple revenue controls.
- Housekeeping and maintenance tasks.
- Staff roles, permissions, audit trail, and tenant/property access.
- Files for documents, guest attachments, invoices, and operational assets.
- Notifications for staff-facing events.
- Background tasks for scheduled work, imports, reconciliation, and reminders.

### Repository Direction

Use separate repositories for root composition, backend, and frontend:

```text
BunkFy/                    # root superproject and composition repo
BunkFy.Backend/            # backend app repo mounted at apps/backend
BunkFy.Web/                # frontend app repo mounted at apps/web
GMA-Framework/             # source dependency mounted at gma/framework
GMA-Module-*/              # source dependencies mounted at gma/modules/<alias>
```

The root repo should not become a hidden monorepo full of product implementation. Its job is to wire things together and make the full system easy to run.

### Backend Direction

Use the existing GMA framework and skeleton structure as the backend foundation.

Backend defaults:

- .NET 10, following the GMA skeleton baseline unless a newer stable project baseline is chosen during setup.
- ASP.NET Core API hosts using GMA module composition.
- Explicit module registration, no magic business-module auto-discovery.
- EF Core persistence.
- PostgreSQL as the preferred open-source default database unless there is a strong reason to keep SQL Server first.
- Keep SQL Server support only if the GMA modules require it or if multi-provider support is still valuable enough to maintain.
- GMA reusable modules mounted as source under root `gma/`.
- Application-owned PMS modules in `apps/backend/src/Modules`.

Expected backend repository shape:

```text
apps/backend/
  BunkFy.Backend.slnx
  Directory.Build.props
  Directory.Packages.props
  Gma.SourceRoots.props.example
  src/
    BunkFy.Host.Api/
    BunkFy.Host.AdminApi/
    BunkFy.Host.AdminCli/
    BunkFy.Host.Worker/
    BunkFy.SharedKernel/
    Modules/
      Properties/
      Inventory/
      Reservations/
      Guests/
      Billing/
      Housekeeping/
  tests/
    Architecture.Tests/
    Integration.Tests/
    Modules/
  eng/
  docs/
```

The exact module list will evolve, but early modules should be chosen by ownership boundaries, not by database tables.

### Frontend Direction

Use React + Vite + TypeScript for the browser app.

Proposed frontend stack:

- Vite for dev server and production build.
- React for UI.
- TypeScript with strict settings.
- pnpm for package management.
- TanStack Query for server state.
- TanStack Router or React Router for routing. Prefer TanStack Router if its type-safe route ergonomics feel worth it after a small spike.
- React Hook Form for complex forms.
- Zod or Valibot for input validation and API boundary parsing.
- Tailwind CSS plus Radix primitives, with local component ownership rather than a hard dependency on an opaque UI kit.
- Vitest and Testing Library for unit/component tests.
- Playwright for important workflow tests.
- OpenAPI-driven client generation, pending a short spike.

Do not start with Next.js unless SSR, server actions, or route-level backend logic becomes a real requirement. A hostel PMS is primarily an authenticated operational SPA, and Vite keeps the toolchain smaller.

### Aspire Direction

Use a C# Aspire AppHost owned by the root repo. This is the composition layer for local development and later deployment modeling.

Root-owned projects:

```text
src/
  BunkFy.AppHost/
  BunkFy.ServiceDefaults/
```

The AppHost should reference backend projects inside the backend submodule and the frontend app directory inside the web submodule:

```text
BunkFy/
  src/BunkFy.AppHost/
  src/BunkFy.ServiceDefaults/
  apps/backend/             # submodule
  apps/web/                 # submodule
  gma/framework/            # submodule
  gma/modules/auth/         # submodule
```

Use Aspire for local orchestration first:

- Backend API.
- Frontend Vite dev server.
- PostgreSQL.
- Optional SQL Server if still supported.
- NATS JetStream when messaging or outbox publishing is being exercised.
- Redis only when caching behavior is being exercised.
- Admin API and worker only when explicitly enabled.

Keep optional systems optional. AppHost flags should make the normal graph small by default.

## Target Root Repository Layout

```text
BunkFy/
  .github/
    workflows/
      validate.yml
  docs/
    planning/
      bunkfy-repository-stack-and-workflow-plan.md
    architecture/
    product/
    operations/
  eng/
    bootstrap.ps1
    verify.ps1
    run-aspire.ps1
    submodule-status.ps1
    sync-submodules.ps1
    guard-submodules-latest.ps1
    update-gma.ps1
  src/
    BunkFy.AppHost/
      BunkFy.AppHost.csproj
      Program.cs
      appsettings.json
      appsettings.Development.json
    BunkFy.ServiceDefaults/
      BunkFy.ServiceDefaults.csproj
      Extensions.cs
  apps/
    backend/                # submodule: BunkFy.Backend
    web/                    # submodule: BunkFy.Web
  gma/
    framework/              # submodule: GMA-Framework
    modules/
      administration/       # submodule: GMA-Module-Administration
      auth/                 # submodule: GMA-Module-Auth
      files/                # submodule: GMA-Module-Files
      notifications/        # submodule: GMA-Module-Notifications
      task-runtime/         # submodule: GMA-Module-Task-Runtime
      tenancy/              # submodule: GMA-Module-Tenancy
  BunkFy.slnx
  Directory.Build.props
  Directory.Packages.props
  global.json
  README.md
```

## Submodule Policy

### Root-Owned Submodules

The root repo should mount:

```text
apps/backend
apps/web
gma/framework
gma/modules/administration
gma/modules/auth
gma/modules/files
gma/modules/notifications
gma/modules/task-runtime
gma/modules/tenancy
```

Prefer public HTTPS submodule URLs if BunkFy is truly open source and the GMA repositories are public. If any GMA repository remains private, CI and contributors need a documented token path.

Example submodule setup commands:

```powershell
git submodule add https://github.com/SadPossum/BunkFy.Backend.git apps/backend
git submodule add https://github.com/SadPossum/BunkFy.Web.git apps/web

git submodule add https://github.com/SadPossum/GMA-Framework.git gma/framework
git submodule add https://github.com/SadPossum/GMA-Module-Administration.git gma/modules/administration
git submodule add https://github.com/SadPossum/GMA-Module-Auth.git gma/modules/auth
git submodule add https://github.com/SadPossum/GMA-Module-Files.git gma/modules/files
git submodule add https://github.com/SadPossum/GMA-Module-Notifications.git gma/modules/notifications
git submodule add https://github.com/SadPossum/GMA-Module-Task-Runtime.git gma/modules/task-runtime
git submodule add https://github.com/SadPossum/GMA-Module-Tenancy.git gma/modules/tenancy
```

If private SSH aliases are required locally, keep that as a contributor setup option rather than the only path for an open-source checkout.

### Avoid Nested GMA Duplication

Do not put another full set of GMA submodules inside `apps/backend` for normal root development. That creates duplicate source trees and confusing dependency pointers.

Instead:

- Root owns `gma/`.
- Root bootstrap writes `apps/backend/Gma.SourceRoots.props` so backend project references point back to root `gma/`.
- Backend standalone development can still use its own local `Gma.SourceRoots.props` to point at sibling or local GMA checkouts.

Example backend source-root file when mounted inside root:

```xml
<Project>
  <PropertyGroup>
    <GmaFrameworkRoot>$(MSBuildThisFileDirectory)..\..\gma\framework\src\</GmaFrameworkRoot>
    <GmaModulesRoot>$(MSBuildThisFileDirectory)..\..\gma\modules\</GmaModulesRoot>
    <GmaModuleAdministrationRoot>$(GmaModulesRoot)administration\src\</GmaModuleAdministrationRoot>
    <GmaModuleAuthRoot>$(GmaModulesRoot)auth\src\</GmaModuleAuthRoot>
    <GmaModuleFilesRoot>$(GmaModulesRoot)files\src\</GmaModuleFilesRoot>
    <GmaModuleNotificationsRoot>$(GmaModulesRoot)notifications\src\</GmaModuleNotificationsRoot>
    <GmaModuleTaskRuntimeRoot>$(GmaModulesRoot)task-runtime\src\</GmaModuleTaskRuntimeRoot>
    <GmaModuleTenancyRoot>$(GmaModulesRoot)tenancy\src\</GmaModuleTenancyRoot>
  </PropertyGroup>
</Project>
```

### Editing Submodules

Before editing any submodule, check that it is on a branch:

```powershell
git -C apps/backend status --short --branch
git -C apps/web status --short --branch
git -C gma/framework status --short --branch
```

If it is detached, switch to a branch first:

```powershell
git -C apps/backend switch -c feature/reservations-foundation
```

Submodule change workflow:

1. Create or switch to a branch inside the submodule.
2. Make the submodule change.
3. Run that submodule's focused validation.
4. Commit and push the submodule branch.
5. Return to the root repo.
6. Run root validation.
7. Commit the root submodule pointer update only after the submodule commit is pushed and intended.

Never commit a root submodule pointer that points to an unpushed local-only commit.

## Root Scripts

The root repo should provide small scripts that hide the boring setup details.

### `eng/bootstrap.ps1`

Purpose: make a fresh checkout usable.

Responsibilities:

- Run `git submodule sync --recursive`.
- Run `git submodule update --init --recursive`.
- Write root and backend `Gma.SourceRoots.props` files.
- Write `Gma.SourceRoots.props` files inside mounted GMA source repos when required for package-local builds.
- Enable Corepack if needed.
- Install frontend dependencies with `pnpm install --frozen-lockfile` when a lockfile exists.
- Restore the root solution.
- Print next commands.

Expected usage:

```powershell
.\eng\bootstrap.ps1
```

### `eng/verify.ps1`

Purpose: run the normal confidence pass.

Responsibilities:

- Check that submodules are pinned to their configured branch tips.
- Restore root solution.
- Build root solution.
- Run backend fast tests.
- Run frontend typecheck, lint, and tests.
- Optionally run Playwright smoke tests when requested.

Expected usage:

```powershell
.\eng\verify.ps1
.\eng\verify.ps1 -SkipSubmoduleFetch
```

### `eng/run-aspire.ps1`

Purpose: start the local full-stack graph.

Responsibilities:

- Run `dotnet run --project src/BunkFy.AppHost/BunkFy.AppHost.csproj`.
- Pass through additional dotnet arguments.

Expected usage:

```powershell
.\eng\run-aspire.ps1
```

### `eng/submodule-status.ps1`

Purpose: make submodule state obvious.

Responsibilities:

- Print root status.
- Print recursive submodule status.
- Flag uninitialized submodules.
- Flag dirty submodules.
- Flag detached submodule worktrees when edit mode is requested.

Expected usage:

```powershell
.\eng\submodule-status.ps1
```

### `eng/sync-submodules.ps1`

Purpose: move all mounted app and GMA submodules to the latest commit on their configured `.gitmodules` branch.

Responsibilities:

- Sync submodule URLs and metadata from `.gitmodules`.
- Initialize missing submodules.
- Refuse to overwrite dirty submodule worktrees.
- Fetch each configured branch.
- Switch each submodule to its configured branch.
- Pull with `--ff-only`.
- Run the latest-tip guard after syncing.
- Re-run root bootstrap.

Expected usage:

```powershell
.\eng\sync-submodules.ps1
.\eng\sync-github-modules.ps1
```

Submodules remain pinned by commit in the root repository. After this script moves a submodule forward, commit the root pointer update so other checkouts get the same composition.

### `eng/guard-submodules-latest.ps1`

Purpose: fail fast when any mounted submodule is behind the branch configured in `.gitmodules`.

Responsibilities:

- Fetch configured branch tips unless skipped.
- Compare each local submodule commit with `origin/<configured-branch>`.
- Explain which sync command fixes stale pointers.

Expected usage:

```powershell
.\eng\guard-submodules-latest.ps1
.\eng\guard-submodules-latest.ps1 -SkipFetch
```

### `eng/update-gma.ps1`

Purpose: update selected GMA source dependencies deliberately.

Responsibilities:

- Fetch selected GMA repos.
- Move them to configured branch tips only when requested.
- Re-run source-root bootstrap.
- Run backend and root validation.
- Leave root pointer changes easy to inspect before pushing.

Expected usage:

```powershell
.\eng\update-gma.ps1 -Module auth
.\eng\update-gma.ps1 -All
```

## Root AppHost Shape

Start with a small local graph. Add infrastructure only when needed.

Conceptual AppHost:

```csharp
using Aspire.Hosting.ApplicationModel;

var builder = DistributedApplication.CreateBuilder(args);

var postgres = builder.AddPostgres("postgres")
    .AddDatabase("bunkfy");

var nats = builder.AddNats("nats")
    .WithJetStream()
    .WithDataVolume(isReadOnly: false);

var api = builder.AddProject<Projects.BunkFy_Host_Api>("api")
    .WithReference(postgres)
    .WithReference(nats)
    .WaitFor(nats)
    .WithEnvironment("ASPNETCORE_ENVIRONMENT", "Development");

builder.AddViteApp("web", "../../apps/web")
    .WithPnpm()
    .WithReference(api)
    .WaitFor(api);

bool workerEnabled = bool.TryParse(
    builder.Configuration["AppHost:Worker:Enabled"],
    out bool configuredWorkerEnabled) && configuredWorkerEnabled;

if (workerEnabled)
{
    builder.AddProject<Projects.BunkFy_Host_Worker>("worker")
        .WithReference(postgres)
        .WithReference(nats)
        .WaitFor(nats)
        .WithEnvironment("DOTNET_ENVIRONMENT", "Development");
}

builder.Build().Run();
```

Notes:

- The actual path used by `AddViteApp` must be tested from the AppHost project working directory.
- Add `Aspire.Hosting.JavaScript` for Vite integration.
- Add `Aspire.Hosting.PostgreSQL`, `Aspire.Hosting.Nats`, and optionally `Aspire.Hosting.Redis`.
- Keep admin API and worker disabled by default.
- Use `WaitFor` for infrastructure-backed services to reduce noisy startup failures.
- Do not treat the Vite dev server as the production hosting model.

## Production Frontend Hosting Direction

Aspire can run and build JavaScript apps, but production still needs a clear serving model.

Candidate production shapes:

### Option A: API or Gateway Serves Static Files

The frontend is built by Aspire and copied into a backend/gateway container. The public HTTP surface is one service.

Pros:

- Simplest deployment and routing model.
- One public origin simplifies auth, cookies, CORS, and browser security.
- Good for self-hosted open-source installs.

Cons:

- Frontend and backend deploy together.
- Backend/gateway image includes static assets.

This should be the default research direction for the first production deployment.

### Option B: Separate Static Host and API

The frontend is deployed to a static hosting target and talks to the API separately.

Pros:

- Independent frontend deployment.
- Static host/CDN can scale cheaply.

Cons:

- More CORS, auth, callback URL, environment, and support complexity.
- Self-hosters have more moving pieces.

This can come later if hosted SaaS or CDN deployment becomes important.

### Option C: BFF/Gateway

A gateway or BFF owns public routing, static files, auth integration, and API proxying.

Pros:

- Clean public entrypoint.
- Good place for headers, route fallback, auth redirects, and API path shaping.

Cons:

- Another service to own.
- May be overkill for the earliest version.

This is a strong future option if the API host should remain API-only.

## Backend Module Strategy

The backend should stay a modular monolith, not split into microservices early.

Early product modules should be application-owned and live in the backend repo:

```text
src/Modules/Properties/
src/Modules/Inventory/
src/Modules/Reservations/
src/Modules/Guests/
src/Modules/Billing/
src/Modules/Housekeeping/
```

Possible module meanings:

- `Properties`: hostel organizations, physical properties, buildings, floors, rooms, beds, and operational settings.
- `Inventory`: bed/room inventory state, out-of-service periods, closures, and availability primitives.
- `Reservations`: booking lifecycle, reservation holds, cancellations, no-shows, check-in, check-out.
- `Guests`: guest profile, stay history, documents, consents, and notes.
- `Billing`: charges, payments, invoices, refunds, taxes, and accounting exports.
- `Housekeeping`: cleaning tasks, room/bed readiness, maintenance requests, assignment.

Reusable GMA modules should be composed explicitly:

- `Auth` for identity and member lifecycle.
- `Tenancy` if BunkFy supports multi-property/operator isolation through tenant context.
- `Administration` for RBAC, audit, and admin surfaces.
- `Files` for attachments and stored assets.
- `Notifications` for staff/user events.
- `TaskRuntime` for scheduled/background tasks.

Keep application-specific behavior out of GMA unless it is genuinely reusable across products.

## Tenancy and Property Model Research

This is one of the most important early design points.

Questions to answer before implementing too much:

- Is a tenant a hostel operator, a property, or a deployment?
- Can one tenant own multiple properties?
- Can staff work across multiple properties?
- Should tenant isolation be mandatory for BunkFy, or should a single-property install feel small and simple?
- Should `X-Tenant-Id` be visible to normal clients, or should tenant/property context be selected through auth and app state?
- Which modules need tenant-aware storage from day one?
- Which objects need property-level scoping in addition to tenant-level scoping?

Likely starting point:

- Tenant = operator/account boundary.
- Property = hostel/site within a tenant.
- Staff can have property-scoped roles.
- Keep tenant infrastructure composed explicitly, but make the normal BunkFy profile tenant-aware.
- Avoid leaking raw tenant mechanics through every product API unless required by GMA contracts.

## Data and Persistence Direction

Preferred default: PostgreSQL.

Reasons:

- Strong open-source default for self-hosted deployments.
- Good relational fit for reservations, inventory, and audit trails.
- Avoids making SQL Server a requirement for open-source hostel operators.

Research point:

- Decide whether BunkFy keeps GMA's dual SQL Server/PostgreSQL migration pattern or simplifies product modules to PostgreSQL-only.

If dual provider support remains:

- Every persistence module needs synchronized migration projects.
- CI must run migration drift checks.
- Architecture tests should prevent provider-specific leakage into domain/application code.

If PostgreSQL-only:

- Setup is simpler.
- CI is simpler.
- Self-hosting docs are simpler.
- Reusable GMA modules may still retain their own provider strategy.

## Frontend Application Structure

Expected frontend repo shape:

```text
apps/web/
  package.json
  pnpm-lock.yaml
  vite.config.ts
  tsconfig.json
  src/
    app/
      router/
      providers/
      queryClient.ts
    api/
      generated/
      client.ts
    features/
      reservations/
      inventory/
      guests/
      housekeeping/
      auth/
      administration/
    components/
      ui/
      layout/
      data-table/
      forms/
    styles/
    main.tsx
  tests/
  e2e/
```

UI principles:

- Operational screens first, not marketing pages.
- Dense but calm layouts.
- Tables, filters, quick actions, keyboard-friendly forms, and clear status states.
- Avoid decorative dashboards before core workflows exist.
- Prefer reusable local components for tables, forms, date ranges, status chips, and side panels.
- Keep design tokens boring and maintainable.

Frontend research points:

- TanStack Router vs React Router.
- Generated OpenAPI client shape.
- Authentication storage and refresh flow.
- Date/time handling for property-local time zones.
- Accessibility standard for tables, forms, dialogs, and keyboard navigation.
- Calendar/occupancy grid component strategy.

## API Contract Strategy

Start with OpenAPI from the backend.

Research points:

- Use `openapi-typescript` for types plus a small fetch client.
- Consider `orval` if generated React Query hooks are worth it.
- Decide whether clients are generated in the frontend repo or produced as an artifact by backend CI.
- Decide whether contract changes require frontend checks in root CI.

Preferred early approach:

- Backend publishes OpenAPI in development and CI artifact.
- Frontend has a script to generate types/client from a local or checked-in OpenAPI snapshot.
- Root validation can regenerate and fail on drift once the API stabilizes.

Avoid hand-maintaining TypeScript DTOs.

## CI Strategy

### Root CI

Root CI validates the integrated system:

- Checkout submodules recursively.
- Bootstrap source roots.
- Restore and build root solution.
- Run backend fast tests.
- Run frontend install, typecheck, lint, and tests.
- Optionally run smoke Playwright tests.
- Report submodule pointer changes clearly.

If GMA submodules are private, root CI needs a token that can read them. For an open-source project, this should be solved deliberately before public launch.

### Backend CI

Backend CI validates backend standalone:

- Restore/build backend solution.
- Bootstrap GMA source roots from configured paths.
- Run architecture tests.
- Run module tests.
- Run integration tests with Testcontainers where possible.
- Run migration drift checks.

### Frontend CI

Frontend CI validates frontend standalone:

- `pnpm install --frozen-lockfile`.
- Typecheck.
- Lint.
- Unit/component tests.
- Build.
- Playwright tests for critical flows when API mocks or test backend are available.

## Local Development Workflow

Fresh checkout:

```powershell
git clone --recursive https://github.com/SadPossum/BunkFy.git
cd BunkFy
.\eng\bootstrap.ps1
.\eng\verify.ps1
.\eng\run-aspire.ps1
```

If cloned without submodules:

```powershell
git submodule update --init --recursive
.\eng\bootstrap.ps1
```

Normal full-stack development:

```powershell
.\eng\run-aspire.ps1
```

Focused backend work:

```powershell
cd apps\backend
.\eng\verify.ps1
```

Focused frontend work:

```powershell
cd apps\web
pnpm install
pnpm dev
pnpm test
```

Before committing from root:

```powershell
.\eng\submodule-status.ps1
.\eng\verify.ps1
git status --short
```

## Solo Maintainer Branching and Merge Flow

BunkFy starts as a solo-maintainer project. Pull requests are optional, not a required part of the normal workflow. Use them only when they add value: public discussion, a larger risky change, or a release-sized checkpoint.

Default day-to-day development happens on `dev` in the root, backend, and web repositories. `main` is reserved as the later stable/release baseline once the project has meaningful releases.

Default feature flow touching both backend and frontend:

1. Work directly on the active repository branch, or create a short-lived local branch when isolation is useful.
2. Implement the backend contract and tests.
3. Generate or update the frontend API client when the frontend exists.
4. Implement the frontend UI when the slice includes UI work.
5. Commit and push backend/frontend changes.
6. Update root submodule pointers.
7. Run root validation.
8. Commit and push the root pointer update.

GitHub branch protection and rulesets should stay lightweight while the project is solo-maintained: no required pull request gate and no required third-party approval. CI can still run on pushes and optional PRs.

## Staged Development Plan

### Stage 0: Repository and Access Decisions

Goal: remove ambiguity before scaffolding.

Tasks:

- Confirm final repository names.
- Confirm whether GMA repos will be public or private.
- Confirm root submodule URLs.
- Confirm default database provider.
- Confirm whether SQL Server support is retained for product modules.
- Confirm frontend package manager.
- Confirm license compatibility across BunkFy and GMA.

Exit criteria:

- Root, backend, and web repositories exist.
- Access model is documented.
- Open-source contributor checkout story is realistic.

### Stage 1: Root Superproject Bootstrap

Goal: create the root composition shell.

Tasks:

- Add root `BunkFy.slnx`.
- Add `src/BunkFy.AppHost`.
- Add `src/BunkFy.ServiceDefaults`.
- Add submodules under `apps/` and `gma/`.
- Add root `eng/bootstrap.ps1`, `eng/verify.ps1`, and `eng/run-aspire.ps1`.
- Add root CI that checks out recursive submodules.
- Add initial docs index.

Exit criteria:

- Fresh clone plus bootstrap works.
- Root AppHost builds.
- Submodule status is readable.

### Stage 2: Backend App Shell

Goal: adapt the GMA generated app shell into `BunkFy.Backend`.

Tasks:

- Generate or hand-adapt a GMA source-first backend shell.
- Rename projects to `BunkFy.*`.
- Compose selected GMA modules explicitly.
- Add backend source-root support for root-mounted GMA.
- Add backend architecture tests.
- Add a minimal health/root endpoint.
- Add initial appsettings shape.

Exit criteria:

- Backend solution restores and builds.
- Backend can run standalone with local source roots.
- Root AppHost can reference backend API host.

### Stage 3: Frontend App Shell

Goal: create `BunkFy.Web` as a real operational app shell.

Tasks:

- Scaffold Vite + React + TypeScript.
- Configure pnpm and strict TypeScript.
- Add router, query client, form, validation, and UI primitives.
- Add API client generation spike.
- Add app shell layout: property selector placeholder, nav, account/auth placeholder, main content.
- Add frontend CI scripts.

Exit criteria:

- `pnpm build` passes.
- `pnpm test` passes.
- Root AppHost can run Vite app.

### Stage 4: Aspire Full-Stack Wiring

Goal: one command starts the useful development graph.

Tasks:

- Add PostgreSQL resource.
- Add backend API project.
- Add Vite frontend resource.
- Add GMA-required infrastructure resources.
- Gate optional worker/admin/Redis/NATS behavior behind config flags.
- Verify API can receive infrastructure connection strings from Aspire.
- Verify frontend can call API in dev.

Exit criteria:

- `.\eng\run-aspire.ps1` starts API, frontend, and database.
- Aspire dashboard shows useful names and health.
- Frontend can call a backend health or version endpoint.

### Stage 5: First Product Module - Properties and Inventory Foundation

Goal: model the physical hostel foundation before reservations.

Tasks:

- Define tenant/property relationship.
- Create `Properties` module or equivalent.
- Model property, building/floor if needed, room, bed, bed type.
- Add persistence and migrations.
- Add API endpoints for core CRUD/list flows.
- Add frontend screens for property setup and bed inventory.
- Add tests for domain rules and API behavior.

Exit criteria:

- A hostel can be configured with rooms and beds.
- UI can list and edit the core inventory.
- Architecture boundaries remain clean.

### Stage 6: Reservation Lifecycle Foundation

Goal: implement the first booking workflow.

Tasks:

- Research reservation states and hostel-specific lifecycle.
- Model reservation, stay, reserved bed/room allocation, guest assignment.
- Define cancellation and no-show states.
- Add basic availability check.
- Add booking create/list/detail API.
- Add frontend reservation list and reservation detail.
- Add check-in/check-out skeleton operations.

Exit criteria:

- Staff can create a basic reservation.
- Staff can view upcoming/current reservations.
- Domain tests cover state transitions.

### Stage 7: Availability, Rates, and Calendar UI

Goal: make BunkFy useful for daily hostel operations.

Tasks:

- Research occupancy grid UX.
- Define availability calculation rules.
- Add out-of-service inventory blocks.
- Add simple rate plan or nightly price model.
- Add calendar/grid UI for beds/rooms and reservations.
- Add conflict detection and tests.

Exit criteria:

- Staff can inspect occupancy by date.
- Staff can see conflicts and unavailable inventory.
- Availability behavior is covered by tests.

### Stage 8: Auth, Staff, Roles, and Admin

Goal: make the system safe for real multi-user work.

Tasks:

- Compose GMA Auth and Administration deliberately.
- Define BunkFy roles: owner, manager, front desk, housekeeping, maintenance, read-only/accountant.
- Decide property-scoped vs tenant-scoped permissions.
- Add bootstrap owner path.
- Add audit requirements.
- Add frontend login and role-aware navigation.

Exit criteria:

- Owner can bootstrap a deployment.
- Staff can log in.
- Basic permissions are enforced and tested.

### Stage 9: Files, Notifications, and Background Tasks

Goal: add supporting operational capabilities.

Tasks:

- Use GMA Files for guest documents and attachments.
- Use Notifications for staff-facing events.
- Use TaskRuntime for scheduled cleanup/reminders.
- Add worker host only when actual background work exists.
- Keep messaging and background loops disabled by default in small local mode.

Exit criteria:

- Attachments work in one product flow.
- At least one notification flow is implemented.
- Worker is justified by a real background task.

### Stage 10: Deployment and Open-Source Readiness

Goal: make the app installable and maintainable by others.

Tasks:

- Choose initial deployment target: Docker Compose first is likely best for open source.
- Decide production frontend serving shape.
- Add production configuration docs.
- Add secrets and environment variable docs.
- Add migration instructions.
- Add backup/restore guidance.
- Add security reporting policy.
- Add contributor setup docs.

Exit criteria:

- A contributor can clone, bootstrap, run, test, and understand the repo structure.
- A self-hoster can deploy a minimal BunkFy instance.
- CI is green across root/backend/web.

## Research Backlog

### Technical Research

- Current stable .NET, Aspire, and GMA baseline at implementation time.
- Aspire JavaScript/Vite integration details and production publish model.
- OpenAPI TypeScript client generation.
- PostgreSQL-only vs dual-provider support.
- Tenant/property/staff access model.
- Reservation availability algorithm.
- Calendar/occupancy grid implementation options.
- Time zone handling for property-local operations.
- File storage provider strategy for self-hosting.
- Email/SMS/WhatsApp notification provider strategy.
- Payment provider strategy, if payments are in scope.

### Product Research

- Hostel-specific PMS workflows.
- Difference between bed-level and room-level bookings.
- Group reservations and split payments.
- Walk-ins and overbooking policy.
- Deposits, taxes, city tax, and invoices.
- Check-in document requirements by country.
- Housekeeping workflow for dorm beds vs private rooms.
- Maintenance/out-of-service workflows.
- Channel manager integrations and iCal import/export.

### Open-Source Research

- License compatibility.
- Whether GMA must become public for BunkFy to be meaningfully open source.
- Contributor onboarding for recursive submodules.
- Docker Compose distribution model.
- Demo data and seed strategy.
- Security policy and responsible disclosure.

## Quality Gates

Initial root validation should eventually include:

```powershell
git submodule status --recursive
dotnet restore BunkFy.slnx
dotnet build BunkFy.slnx --no-restore -m:1
dotnet test apps\backend\BunkFy.Backend.slnx --no-build --logger "console;verbosity=minimal"
pnpm --dir apps\web install --frozen-lockfile
pnpm --dir apps\web typecheck
pnpm --dir apps\web lint
pnpm --dir apps\web test
pnpm --dir apps\web build
```

As the product matures, add:

- Backend architecture tests for module boundaries.
- Migration drift checks.
- Testcontainers integration tests.
- Playwright smoke tests through Aspire.
- Contract drift checks between backend OpenAPI and frontend generated client.
- Dependency and vulnerability scans.

## Risks and Mitigations

### Risk: Submodules Make Contributions Hard

Mitigation:

- Keep root scripts excellent.
- Document the workflow clearly.
- Prefer public submodule URLs where possible.
- Avoid nested duplicate GMA checkouts.
- Make submodule status visible in CI.

### Risk: Root Repo Accumulates Product Code

Mitigation:

- Root code is limited to AppHost, service defaults, scripts, docs, and integration tests.
- Backend product code goes to `apps/backend`.
- Frontend product code goes to `apps/web`.

### Risk: GMA Private Repos Conflict With Open Source

Mitigation:

- Decide early whether GMA will be public.
- If GMA remains private, document what parts of BunkFy are actually open source and what credentials are required.
- Prefer public dependency paths for an open-source PMS.

### Risk: Architecture Becomes Too Heavy

Mitigation:

- Keep the default Aspire graph small.
- Keep optional adapters optional.
- Add worker/admin/messaging complexity only when product behavior needs it.
- Keep modules explicit and understandable.

### Risk: Frontend and Backend Drift

Mitigation:

- Generate frontend API client from OpenAPI.
- Add contract drift checks once API stabilizes.
- Use root integration validation for cross-repo changes.

### Risk: Reservation Domain Gets Implemented Too Naively

Mitigation:

- Research hostel workflows before coding deep reservation logic.
- Build inventory and property model first.
- Add tests around edge cases: date boundaries, bed moves, cancellations, no-shows, overbooking, and out-of-service inventory.

## Initial Next Tasks

1. Create or confirm the `BunkFy.Backend` and `BunkFy.Web` repositories.
2. Decide whether GMA repositories will be public for open-source BunkFy.
3. Add root submodules under `apps/` and `gma/`.
4. Scaffold root `BunkFy.AppHost` and `BunkFy.ServiceDefaults`.
5. Adapt a GMA source-first backend shell into `apps/backend`.
6. Scaffold Vite React TypeScript frontend into `apps/web`.
7. Implement root bootstrap and verify scripts.
8. Wire Aspire to start backend, frontend, and PostgreSQL.
9. Add first cross-repo smoke endpoint and frontend call.
10. Start product research for tenancy/property/inventory boundaries.

## Reference Links

- GMA Skeleton: https://github.com/SadPossum/GMA-Skeleton
- GMA source-first app guidance: https://github.com/SadPossum/GMA-Skeleton/blob/main/docs/getting-started/source-first-apps.md
- GMA framework module system: https://github.com/SadPossum/GMA-Framework/blob/dev/docs/architecture/module-system.md
- Aspire AppHost docs: https://aspire.dev/get-started/app-host/
- Aspire JavaScript integration: https://aspire.dev/integrations/frameworks/javascript/
- Aspire JavaScript deployment patterns: https://aspire.dev/deployment/javascript-apps/
- Git submodule docs: https://git-scm.com/docs/git-submodule
- Vite guide: https://vite.dev/guide/
