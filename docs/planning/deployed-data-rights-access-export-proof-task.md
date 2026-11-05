# Deployed Data Rights Access Export Proof Task

Status: implemented and exact-release Preview verified
Date: 2026-08-12

## Goal

Add one bounded exact-release deployment proof for the smallest complete Data
Rights workflow: create a synthetic Guest, approve a controller-initiated
Access Export case, let the Worker produce the encrypted artifact in MinIO,
download it through the protected API, and clean up the mutable Guest fixture.

## Finding

The repository has extensive module and integration coverage for Data Rights,
authentication assurance, export encryption, task dispatch, and artifact
expiry. Production admission does not yet require evidence that those parts
work together in a deployed candidate.

The proof must not overstate cleanup. The public API schedules encrypted export
artifacts for deletion at their expiry, which defaults to 24 hours; it does not
offer immediate artifact deletion. The synthetic Guest can be archived during
the rehearsal, while the case history and encrypted artifact remain under the
configured lifecycle policy.

## Ownership

- GMA Auth, Security, Access Control, and Tasks retain their generic contracts.
  They already provide password and TOTP authentication, assurance metadata,
  scoped policy evaluation, and durable task execution. GMA remains unchanged.
- BunkFy Guests owns the synthetic subject lifecycle.
- BunkFy Data Rights owns case progression, immutable selected scope, export
  generation, protected download, and artifact expiry.
- The BunkFy Host composition owns the concrete freshness and ACR requirements.
- The root operations layer owns exact-release rehearsal, minimized evidence,
  Preview composition, and final production-admission policy.

## Proof Contract

The deployed verifier will:

1. Bind an assured operator and one property to the expected release.
2. Prove a nonmember cannot read the property's Data Rights cases.
3. Create one synthetic Guest and a controller-initiated Access Export case.
4. Discover and select only that exact Guest coordinate.
5. Complete review and an approved decision before requesting the export.
6. Prove same-key request replay is stable and a second artifact request is
   rejected.
7. Poll boundedly until the Worker makes the artifact available and the case is
   completed.
8. Prove an otherwise authorized but unassured session receives `401` with
   `Security.InsufficientAuthentication`, while a nonmember receives `403`.
9. Download twice with an assured session and verify no-store headers, JSON
   attachment metadata, strict export shape, bounded size, and stable bytes in
   memory without persisting plaintext.
10. Archive the synthetic Guest even when a later assertion fails, and fail the
    proof if that cleanup does not converge.
11. Recheck release identity and emit only bounded, non-identifying evidence.

## Evidence Boundary

The evidence kind will be
`bunkfy-deployed-data-rights-access-export-probe`, schema version 1. It may retain
release, origin, transport, workflow status, export format/version, aggregate
subject and record counts, byte count, bounded expiry information, cleanup
disposition, checks, and fixed limitations.

It must not retain credentials, refresh tokens, PII, plaintext export content,
plaintext hashes, or workspace, property, Guest, case, subject, and artifact
identifiers. Files are written atomically with private permissions and cannot
overwrite an existing result without explicit `-Force` approval.

The fixed limitations will state that the proof does not exercise the browser
privacy workflow, multi-subject or large exports, or independent object-store
and key custody; and that case history plus the encrypted artifact remain until
their configured lifecycle completes.

## Preview Composition

`rehearse-preview-onboarding.ps1` will expose an opt-in Data Rights switch. Only
for that switch, it will retain the generated owner password in a `SecureString`,
create a fresh password session for the negative assurance control, temporarily
enroll TOTP for the destructive-assurance session, and pass both tokens to the
child verifier as `SecureString` values. The parent disables the synthetic TOTP
factor with a one-use recovery code during cleanup, which also revokes the
owner's sessions. No password, TOTP secret, recovery code, or refresh token will
cross the command line or evidence boundary.

The Data Rights proof will run before invitation acceptance so the invitation
applicant can serve as the nonmember identity. Property processing will be
activated once before the first child workflow that requires it.

## Delivery

1. Add the deployed verifier and deterministic fixture test.
2. Add the opt-in Preview onboarding composition and secure step-up lifecycle.
3. Add the new closed evidence specification to production admission and make
   its source result mandatory.
4. Wire static guards, the focused fixture, documentation, and the operations
   gate.
5. Run one exact-release Preview rehearsal after the implementation is coherent
   and record that result separately from hosted-production evidence.

## Verification Cadence

Use the new verifier fixture and production-admission fixture while editing.
Run the complete operations gate once at the end of the coherent slice. Do not
run Docker suites for root-script iterations; the final exact-release Preview
rehearsal is the integration proof across API, Worker, PostgreSQL, NATS, and
MinIO.

## Deferred

- Browser self-service privacy request and identity-verification UX.
- Multi-subject, large-export, expiry-worker, and restore scenarios.
- Independent object-store access, key custody, and recovery assurance.
- The first hosted-production execution and private approval decision.
- Generalizing any BunkFy-specific orchestration into GMA without a second
  demonstrated project use case.

## Acceptance

- The focused verifier and admission fixtures pass.
- The complete operations gate passes once for the finished slice.
- An exact candidate Preview run produces passing minimized evidence.
- Production admission requires the new exact-release evidence but does not
  present Preview evidence as hosted-production proof.

## Outcome

The focused TOTP, deployed-verifier, and production-admission fixtures pass.
The complete root operations gate also passes with the new verifier and the
14-source admission bundle.

Exact release `preview-workspace-access-estate-651107f` passed the opt-in
Preview rehearsal on 2026-08-12. The child passed all 18 checks with one Guest,
one exported record, a 1,400-byte format-v1 artifact, and a 24-hour scheduled
expiry. Its SHA-256 is
`5e03d355f26436960daa2fa4ab4f1a7bb4e3b815fd6f87f99cf3145c7e417f72`.
The 11-check umbrella SHA-256 is
`987c87635a792b1f802133db23a525d9d5bcbe89a8ad79e63badeb61d69a7058`.

Cleanup archived the Guest, disabled the temporary TOTP factor and revoked its
sessions, removed both joined members, retired both properties, archived the
workspace, revoked all remaining sessions, and purged the Mailpit window. The
encrypted artifact remains scheduled for expiry and the case remains under its
configured lifecycle, as declared before implementation.

The retained files are ignored local Preview evidence with operator-only
permissions. Their `loopback-http-fixture` transport is accepted only under the
admission parser's explicit fixture allowance and cannot satisfy the mandatory
hosted-production evidence input.
