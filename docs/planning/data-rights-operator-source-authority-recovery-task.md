# Data Rights Operator Source Authority Recovery Task

Status: implemented and repository-verified
Date: 2026-08-23

## Goal

Keep privacy request queues and case evidence useful during independent read
failures while binding every discovery, decision, export, correction,
restriction, and removal command to current permissions, current case evidence,
and the exact signed-in workspace identity.

## Existing Foundation

- The backend already fences obsolete discovery, revalidates selected records
  and owner revisions, requires expected case versions, and exposes explicit
  conflict and retry semantics.
- Export, correction, restriction, and removal commands already use server-side
  authorization, recent-authentication checks where required, idempotency, and
  owner-module revalidation.
- This task preserves those controls and does not redesign the Data Rights
  domain or duplicate owner-module policy in the client.

## Findings

- Queue, case, evidence, execution, export, correction, and restriction-target
  cache keys omit the exact user-and-workspace identity. Session cache clearing
  helps, but does not fence late completions or future cache reuse by itself.
- One combined permission request couples the staff queue to unrelated property
  evaluations and the guest queue to unrelated tenant erasure authority.
- Retained queue and case snapshots are discarded after refresh errors, while
  retained evidence in child workflows is inconsistently treated as current.
- Raw cached capabilities can still open forms and issue commands while a
  permission refresh, case refresh, or supporting evidence refresh is pending
  or failed.
- Create, case action, discovery selection, restriction targeting, export, and
  correction callbacks do not consistently capture and re-check their source
  identity before updating a newly selected scope.
- Selected evidence and restriction-target responses compare case versions,
  but remain actionable while refetching.
- Pagination can navigate from a stale queue and page recovery can run from
  non-current data.

## Ownership

- GMA owns generic CQRS, authorization evaluation, authentication assurance,
  idempotency primitives, and transport/result semantics.
- BunkFy Data Rights owns privacy-case states, evidence, approvals, controller
  deadlines, export/correction/restriction/removal policy, and owner-module
  coordination.
- The web application owns identity-safe query keys, independent source
  composition, retained-snapshot presentation, current-evidence command gates,
  scope resets, and late-completion fencing.
- No GMA, backend, schema, database, broker, or container change is required for
  this slice.

## Decisions

- Preserve the established live-update key prefixes, then append a normalized
  user-and-workspace key so existing prefix invalidation remains compatible.
- Evaluate active-scope permissions independently from tenant erasure
  permission. A property failure cannot block staff work, and an erasure check
  cannot block unrelated guest rights work.
- Retain usable queue, case, and supporting evidence snapshots with explicit
  delayed-state notices, but permit no command from a source that is not
  current.
- Capture scope, path, case revision, and operation evidence in every mutation
  submission. Ignore late client-side completion when its identity no longer
  matches the active workflow.
- Keep server-side expected-version, idempotency, recent-authentication, and
  owner-module checks authoritative; client gates improve operator safety but
  never replace server controls.

## Delivery

- [x] Add canonical Data Rights operator scope and query-key helpers.
- [x] Separate active-scope and erasure permission sources.
- [x] Compose queue and case sources with retained-snapshot recovery and
  current-source command authority.
- [x] Fence create, case actions, discovery selection, and restriction-target
  mutations to exact current inputs.
- [x] Fence export generation/download and correction claim/edit workflows to
  current case, permission, artifact, claim, and owner-record evidence.
- [x] Reset deep links, paging, forms, confirmations, and local attempts across
  user, workspace, or request-scope boundaries.
- [x] Add focused source-authority, partial-failure, and late-completion tests.
- [x] Run one complete web gate and publish the coherent Data Rights slice.

## Invariants

- Retained privacy data may be inspected but cannot authorize a command.
- Staff-scope availability is independent from selected-property permission
  availability; destructive erasure authority is independent from ordinary
  privacy workflow authority.
- A late response from another user, workspace, property, case, or case version
  cannot update the active workflow.
- Discovery and selected evidence cannot be acted on during refresh or after
  their case revision changes.
- Export download, correction editing, restriction release, and removal remain
  fail-closed at both client and server boundaries.
- BunkFy privacy semantics do not leak into GMA.

## Verification Cadence

Use focused pure-helper and Data Rights workflow tests during each pass. At the
domain boundary, run one complete web typecheck, lint, test, build,
contract-drift, and root solution-membership gate. This web-only slice requires
no Docker or GMA gate.

## Completion Evidence

- The focused Data Rights and workspace authority suite passed 56 tests across
  9 files while the slice was being assembled.
- The complete web gate passed TypeScript, lint, all 71 test files and 358
  tests, and the production Vite build.
- The OpenAPI snapshot and generated TypeScript contracts are current.
- The backend and root workspace solution files match the current repository
  graph, including this task record, and all edited repositories pass
  `git diff --check`.
- The correction owner editor was extracted from the parent workflow so owner
  reads and mutations remain reviewable without changing module ownership.
- No backend, GMA, schema, broker, migration, or container behavior changed;
  consequently no Docker or backend-wide test run was required for this slice.

## Deferred

- Hosted multi-operator rehearsal, production legal decisions, retention
  schedules, processor/subprocessor inventory, support runbooks, and independent
  assurance evidence.
- Product policy changes to controller deadlines, approved-country handling,
  legal holds, or erasure eligibility.
