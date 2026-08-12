# Production Migration Proof Refresh Task

Status: planned
Date: 2026-08-12

## Goal

Refresh the isolated Production migration rehearsal against the exact backend
image that packages AdapterHost and the current committed BunkFy product graph.

## Finding

The latest retained migration rehearsal predates backend commit `a269085` and
its exact image digest. No module migration changed in that commit, but the
current product candidate should still prove that its packaged migration host
can plan, apply, converge, and repeat idempotently without relying on older
image evidence.

## Boundary

- This is product deployment choreography, not domain or GMA behavior.
- Use the existing exact local image and digest-pinned PostgreSQL image. Do not
  build, pull, publish, or contact the live Preview database.
- Keep the random database password and generated Production keys in the
  script's private temporary files; retain only minimized evidence.
- Remove the disposable PostgreSQL container, internal network, and temporary
  directory on success or failure.
- Passing local mechanics do not approve a Production database migration,
  maintenance window, backup, rollback, or release.

## Delivery

- [ ] Bind the rehearsal to the current committed root and exact backend image.
- [ ] Prove Production Plan does not mutate an empty target.
- [ ] Prove malformed and mismatched approval inputs fail before mutation.
- [ ] Apply the exact planned catalogue and database-target hashes.
- [ ] Re-plan to zero pending migrations and repeat Apply idempotently.
- [ ] Remove all disposable resources and retain minimized evidence.

## Done When

One current evidence record binds the exact source and image identities to a
non-mutating plan, fail-closed admission checks, successful apply, zero-pending
convergence, and schema-equivalent repeat apply, with no rehearsal resources
left behind.
