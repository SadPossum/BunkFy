# Current Candidate Publication Refresh Task

Status: in progress
Date: 2026-08-14

## Goal

Publish one exact, reviewable source candidate after the current product-domain
production milestones, then retain the scanned backend and web OCI bytes needed
for a later approved registry promotion. Do not substitute old candidate
evidence or present local Preview proof as hosted deployment evidence.

## Boundary

- The BunkFy root commit owns the recursive source identity and exact backend,
  web, and GMA pins.
- GitHub validation owns the clean-checkout repository gate for that commit.
- Product Image Evidence owns one build of unpublished backend and web OCI
  archives, SBOMs, vulnerability scans, checksums, and GitHub attestations.
- Preview evidence remains runtime rehearsal evidence. It does not attest the
  GitHub-built OCI bytes.
- Hosted registry authentication, immutable-tag policy, promotion, deployment,
  rollback, private approvals, and production data remain deployment-owned.

## Delivery

1. Commit this ledger so every workflow binds the final candidate source set.
2. Dispatch `validate` once for the exact branch head.
3. Dispatch Product Image Evidence once with retained candidate bytes and
   bounded retention.
4. Verify both run conclusions, exact head SHA, artifact identities, and
   candidate attestations before recording completion.
5. Keep the bundle unpublished until an approved non-local registry and
   private release record exist.

## Acceptance

- the root, backend, web, and recursive GMA source graph is clean and published;
- exact-head validation passes from a clean GitHub checkout;
- exact-head image evidence builds and scans both OCI candidates, closes and
  attests evidence, and retains the exact candidate bundle;
- failures are investigated at the same commit rather than bypassed or hidden;
  and
- completion names the remaining hosted promotion, rollback, migration,
  recovery, operational, legal, and private-approval gates without claiming
  they are done.
