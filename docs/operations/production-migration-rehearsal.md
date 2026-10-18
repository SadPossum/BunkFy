# Production Migration Rehearsal

BunkFy rehearses the existing `BunkFy.Host.Migrations` Production contract
before a release reaches a real database. This is product deployment
choreography: modules continue to own their migrations, the migration host owns
the fixed cross-module plan and lock, and GMA remains free of BunkFy release
policy.

## Run

The backend candidate and PostgreSQL image must already exist locally. The
script never builds, pulls, or publishes an image. Both images must expose one
immutable repository digest; the rehearsal resolves each tag once and runs the
resulting local image ids so a tag cannot move between phases. The declared
source commit must exist in the local product repository.

The default PostgreSQL reference is the same tag-and-digest pin used by the
Preview stack. An intentional database-image upgrade must update both defaults,
pass the repository operations guard, and complete a fresh recovery and
migration rehearsal. A caller may supply another local image explicitly, but
the retained evidence records the immutable bytes that actually ran.

```powershell
.\eng\operations\rehearse-production-migrations.ps1 `
  -BackendImage bunkfy/backend:preview `
  -SourceCommitSha <exact-product-source-commit>
```

When omitted, `SourceCommitSha` defaults to the root checkout's current commit.
Image-to-source provenance still comes from the product image evidence and the
approved release channel; this local rehearsal records the identities but does
not invent an attestation between them.

## Proof

The script creates a random, internal Docker network with no published ports and
a disposable PostgreSQL data directory. It then:

1. runs Production `Plan` and fingerprints a normalized schema-only database
   dump before and after to prove that planning did not mutate it;
2. proves malformed source identity, malformed backup reference, and an
   approved hash for a different database target all fail before mutation;
3. runs Production `Apply` with the exact database and migration-catalogue
   hashes emitted by the plan;
4. plans again and requires zero pending migrations;
5. reruns the same approved apply and requires the normalized schema to remain
   byte-for-byte equivalent;
6. removes every rehearsal container, temporary secret file, network, and
   temporary PostgreSQL filesystem.

Non-secret evidence is written under `.tmp/migration-rehearsals` by default. It
records source and image identities, plan hashes/counts, fail-closed checks, and
the idempotent result. It never records the connection string or generated
database password. Production-required data-protection keys are generated only
for the disposable migration process, stored in mode-restricted temporary
environment files, and removed with the rehearsal resources.

## Boundary

Passing this rehearsal proves the checked migration executable's mechanics. It
does not approve a production change, validate a syntactically valid external
evidence reference, or replace target-specific backup/restore, artifact
signature, maintenance-window, compatibility, and post-deploy evidence. Those
remain deployment admission inputs owned by private operations.
