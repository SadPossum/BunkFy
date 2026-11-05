# Staff Operator Source Authority Recovery Task

Status: complete
Date: 2026-08-23

## Goal

Keep the Staff directory, directory-safe detail, sensitive profile, property
assignments, and account context useful during partial read failure while
binding every employment command to current permission and exact Staff record
evidence.

## Findings

- Tenant-wide Staff permissions and the selected property's assignment
  permission are evaluated as one source, so a property-scoped failure can hide
  the entire workspace Staff directory.
- Retained permission decisions can leave create, profile, lifecycle, account,
  and assignment controls actionable after authority refresh fails.
- Directory and detail refresh errors replace usable last-loaded snapshots with
  page-level errors.
- The sensitive profile replaces directory-safe detail instead of composing as
  an independent optional source; a sensitive-profile failure therefore hides
  lifecycle and assignment context that remains available.
- Staff detail cache keys omit the tenant identity and can collide across a
  workspace switch.
- Profile, lifecycle, account-link, and property-assignment commands submit a
  captured Staff version without proving that it still matches a current detail
  source.
- The editable employee number is omitted from the profile-update operation
  fingerprint, so changing only that field can incorrectly reuse a previous
  operation identity.
- Property assignment uses the selected property without current property
  catalogue or property-scoped permission evidence.
- Account-link assurance failure has a generic error but no in-place recent
  authentication recovery.
- Staff page concerns are compressed into one dense component, obscuring source
  ownership and command invariants.

## Ownership

- Staff owns employment profiles, account-subject links, lifecycle state,
  optimistic versions, property assignments, operation identities, and its
  directory projections.
- Properties owns property lifecycle and the catalogue used as assignment
  target context. Staff consumes its own Properties projection and remains
  responsible for rejecting an unconverged or unavailable target.
- Workspaces and Organizations own workspace membership; Access Control owns
  tenant and property-scoped permission evaluation; Auth owns subjects,
  credentials, recent-authentication assurance, and sessions.
- The web application owns independent source composition, tenant-safe cache
  identity, stale-snapshot presentation, current-evidence gates, and bounded
  recovery affordances.
- Existing APIs already enforce tenant and resolved property scope, relevant
  permissions, expected versions, operation identity, lifecycle invariants, and
  account-link authentication assurance. No backend, schema, GMA framework, or
  GMA extension change is required here.

## Decisions

- Evaluate tenant Staff capabilities independently from the selected property's
  assignment capability.
- Preserve stale Staff lists, directory detail, sensitive profile, and property
  labels as visibly delayed read-only context.
- Query directory-safe detail independently from the optional sensitive profile
  so one source cannot erase the other.
- Require current tenant permission for create, profile update, lifecycle, and
  account-link commands; profile and account commands also require current
  sensitive-profile evidence.
- Require current property-scoped assignment permission, current selected
  property catalogue evidence, and an exact current Staff record for assignment
  and unassignment.
- Bind Staff detail caches, command state, and late mutation completion to the
  workspace that initiated them.
- Include every editable profile field in operation equivalence while retaining
  the existing minimized hashed fingerprint boundary.
- Recover account-link assurance in place through the shared recent-password
  prompt and retry the exact operation.
- Split directory, detail, profile-form, assignment, presentation, and mutation
  authority concerns into focused feature files.

## Delivery

- [x] Compose independent tenant permission, assignment permission, directory,
  directory-detail, sensitive-profile, and property-catalogue sources.
- [x] Preserve usable stale snapshots with local notices, fallbacks, and retry
  paths.
- [x] Gate create, profile, lifecycle, account, and assignment commands on their
  exact current evidence.
- [x] Scope cache and in-flight completion identity to the active workspace and
  reset command state across workspace, member, and property changes.
- [x] Correct profile operation equivalence and add recent-authentication
  recovery for account links.
- [x] Split the Staff page into focused, reviewable components.
- [x] Add focused source-state, mutation-authority, cache-identity, and
  operation-equivalence tests.
- [x] Run one complete web gate and publish the coherent slice.

## Verification

- Focused Staff authority, transition, and durable-operation verification passed
  with 7 test files and 21 tests.
- Complete web verification passed with 69 test files and 349 tests, followed
  by lint, typecheck, and a 3,028-module production build.
- Generated OpenAPI TypeScript contracts match the backend snapshot.
- Backend and root workspace solutions regenerate deterministically, pass their
  synchronization checks, and list successfully through `dotnet sln`.
- Backend remains at `67f11b52`; existing endpoint permission, authentication
  assurance, optimistic-version, operation-identity, and property-target
  enforcement required no backend or GMA change.

## Publication

- Web `dev`: `75fe487` (`Keep staff commands bound to current sources`).

## Invariants

- A property assignment permission failure cannot hide tenant-wide Staff reads.
- An unavailable directory or profile is never represented as authoritative
  empty data.
- Stale permission, Staff record, or selected-property evidence cannot enable a
  mutation.
- Sensitive profile data is not rendered after a current permission revocation.
- Expected versions and operation identities remain tied to the exact visible
  command intent, including employee number and assignment target.
- A workspace or property switch cannot reuse command state or late completion
  from the previous scope.
- Staff remains independently removable and does not gain a direct Properties,
  Workspaces, Auth, or Access Control implementation dependency.

## Verification Cadence

Use focused Staff authority, source-state, attempt-identity, and transition tests
while editing. At the slice boundary, run one complete web typecheck, lint, test,
build, contract-drift, and root solution-membership gate. This slice changes no
backend, database, provider, broker, container, GMA framework, or GMA extension
behavior, so no Docker or GMA gate is required.

## Deferred

- Hosted multi-actor browser rehearsal; deployed synthetic Staff lifecycle proof
  remains Preview evidence, not hosted-production approval.
- Large-directory virtualization beyond the current bounded server pagination.
- Employment governance and Staff data-hold operator UX, which belong to their
  own product and privacy-policy slices.
