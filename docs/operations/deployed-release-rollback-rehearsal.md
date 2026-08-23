# Deployed Release Rollback Rehearsal

Use this manual rehearsal against a staging or release-candidate origin before
Production admission. It proves that the public web and API can converge from
an admitted candidate to an admitted rollback release and back again without
rebuilding either image.

## Prerequisites

- retain verified promotion evidence for the candidate and rollback releases;
- preallocate the admission evidence reference and configure it on the
  candidate Public API, Admin API, and Worker;
- deploy only the digest-qualified backend and web references from those
  records;
- complete the [Production migration rehearsal](production-migration-rehearsal.md)
  for the candidate schema path; and
- arrange the normal deployment approval, traffic, alerting, and rollback
  controls outside this repository script.

Verify each promotion record independently before the rehearsal:

```powershell
./eng/verify-image-promotion.ps1 `
  -PromotionDirectory /evidence/promotions/candidate `
  -ExpectedReleaseId release-20260806-02 `
  -ExpectedSourceCommit <candidate-root-commit>

./eng/verify-image-promotion.ps1 `
  -PromotionDirectory /evidence/promotions/rollback `
  -ExpectedReleaseId release-20260801-01 `
  -ExpectedSourceCommit <rollback-root-commit>
```

## Rehearse

Start the observer in one terminal:

```powershell
./eng/operations/rehearse-deployed-release-rollback.ps1 `
  -PublicOrigin https://candidate.example.com/ `
  -CandidatePromotionDirectory /evidence/promotions/candidate `
  -CandidateReleaseId release-20260806-02 `
  -CandidateSourceCommit <candidate-root-commit> `
  -AdmissionEvidenceReference $admissionReference `
  -RollbackPromotionDirectory /evidence/promotions/rollback `
  -RollbackReleaseId release-20260801-01 `
  -RollbackSourceCommit <rollback-root-commit> `
  -OutputDirectory /evidence/rollback/release-20260806-02
```

The command first runs the complete public-edge probe against the candidate.
When prompted, use the approved deployment control plane to deploy the exact
rollback digest references. After web and API report the rollback release, the
command runs the complete probe again and asks you to restore the candidate
digest references. A final complete probe closes the rehearsal.

Polling is bounded and low frequency. It observes the release identifier
reported independently by web and API and requires the Public API admission
reference to remain equal to the preallocated value at the candidate baseline,
rollback, and restoration probes. It does not send credentials or execute
deployment commands. A timeout, partial convergence, or admission-identity
change emits no passing evidence.

## Evidence

A passing output directory contains three schema-v4 public-edge probe records,
the schema-v2 `rollback-rehearsal.json`, and `checksums.sha256`. The rehearsal
record binds both promotion records, their digest-qualified image references,
the preallocated admission evidence reference, observed transition timings, and
a separately generated `rollback:<id>` rehearsal reference.

The evidence does not prove Worker or Admin API release identity, deployment
approval, alert delivery, traffic draining, registry immutability after
promotion, or complete schema and domain compatibility. Retain the migration
rehearsal and relevant authenticated domain probes alongside it. Hosted
deployment-platform proof remains a private release-system responsibility.

`-AllowFixtureEvidence` is accepted only with explicit loopback HTTP and exists
for the deterministic repository test. It must not be used for hosted evidence.
