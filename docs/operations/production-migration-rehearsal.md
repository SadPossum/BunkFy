# Production Migration Rehearsal

BunkFy rehearses the existing `BunkFy.Host.Migrations` Production contract
before a release reaches a real database. This is product deployment
choreography: modules continue to own their migrations, the migration host owns
the fixed cross-module plan and lock, and GMA remains free of BunkFy release
policy.

## Run An Attested Candidate

The preferred release-candidate path consumes the retained Product Image
Evidence bundle directly:

```powershell
.\eng\operations\rehearse-candidate-production-migrations.ps1 `
  -BundleDirectory <downloaded-candidate-bundle> `
  -ExpectedSourceCommit <exact-product-source-commit>
```

The wrapper verifies the closed bundle and GitHub attestations, refuses to
replace a pre-existing candidate tag, loads the exact backend OCI archive, and
requires the resulting repository digest to equal the attested manifest. It
captures Docker's immutable image id and requires the migration evidence to
record that same executed image. It then delegates migration behavior to
`rehearse-production-migrations.ps1` and removes the imported candidate image
after success or failure. It does not build, pull, or publish an image.

## Run A Local Image

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
This lower-level entry point deliberately does not invent image-to-source
provenance; use the attested-candidate wrapper when candidate bytes are
available.

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

Passing either rehearsal proves the checked migration executable's mechanics.
does not approve a production change, validate a syntactically valid external
evidence reference, or replace target-specific backup/restore, artifact
signature, maintenance-window, compatibility, and post-deploy evidence. Those
remain deployment admission inputs owned by private operations.
