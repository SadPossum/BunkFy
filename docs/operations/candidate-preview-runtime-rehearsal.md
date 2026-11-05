# Candidate Preview Runtime Rehearsal

Use this rehearsal after an OCI candidate bundle has passed the image-evidence
gate. It runs the attested backend and web bytes together without building or
pulling images and leaves the long-lived Preview stack untouched.

```powershell
.\eng\operations\rehearse-candidate-preview-runtime.ps1 `
  -BundleDirectory .tmp/image-candidate-<run-id> `
  -ExpectedSourceCommit <40-character-candidate-commit>
```

The command:

- verifies the candidate checksum set and GitHub attestations;
- refuses to replace either deterministic local candidate tag;
- generates fresh private secrets plus unique Compose project, volume, release,
  and loopback-port identities;
- preflights every resolved image locally and starts with both build and pull
  disabled;
- binds the API, Worker, migration host, Admin API, and web containers to the
  attested image identities;
- reuses the deployed public-edge and Preview management-isolation verifiers;
  and
- removes the stack, volumes, networks, generated environment, child probe
  file, and imported candidate tags on success or failure.

The retained JSON is private, minimized local evidence. It records source,
bundle, manifest, image, release, service-binding, probe, and cleanup identity,
but no generated secret or connection string. Optional `-PublicPort` and
`-AdminPort` values must be distinct available loopback ports; zero selects
ephemeral ports.

Passing this rehearsal proves local Preview composition mechanics only. It does
not prove registry promotion, a hosted deployment, trusted TLS, authenticated
workflows, rollback, or Production approval.
