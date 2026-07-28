# BunkFy Support Policy

## Release Channels

BunkFy has no supported production release yet. The `dev` branch is the
changing integration line, and workflow-dispatch runs create reviewable
composition evidence without enabling or publishing a production deployment.

| Channel | Status |
| --- | --- |
| `dev` | Pre-release integration |
| Composition candidate | Reviewable source and provenance evidence |
| Tagged production release | None yet |

## Compatibility

A candidate contains the owned repository archive plus a recursive source-set
manifest identifying the exact Backend, Web, and nested GMA commits. Validation
and release decisions apply to that complete composition.

No production compatibility promise exists before the first approved BunkFy
release. Component candidates do not create an independent product support
contract.

## End Of Life

There is no supported version to retire yet. A future production release must
declare its support and end-of-life terms in its release notes before
publication.

## Support

Security reports follow `SECURITY.md`. Pre-release maintenance is best effort
and has no contractual support SLA.
