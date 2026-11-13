# Security policy

## Reporting a vulnerability

- **In this repository** (build scripts, signing, publishing, documentation): open a private
  security advisory at
  <https://github.com/elirnyk/coral-edgetpu-apt/security/advisories/new>.
- **In the packaged software** (`libedgetpu`, `gasket-driver`): report to the upstream projects:
  - <https://github.com/feranick/libedgetpu/issues>
  - <https://github.com/erikpendragon/gasket-driver/issues>

Do not open a public issue for a signing-key or CI compromise. See the key-compromise procedure
below.

## What this project controls

- The build pipeline and the signed repository metadata.
- The APT signing key and its publication.
- Pinned upstream commits and archived source tarballs.

It does not modify upstream source code or packaging logic. Package contents are therefore only as
trustworthy as the upstream projects and the pinned commits.

## Integrity controls

- Upstream sources are resolved to an exact commit SHA and archived as GitHub Release assets.
- Builds run only on pushes/dispatches in this repository, never on fork pull requests.
- Signing happens only in the protected `apt-signing` environment with required reviewers.
- Third-party GitHub Actions are pinned by commit SHA; Dependabot proposes updates.
- The published repository is verified after every publish by clean-container installs and an
  independent `gpgv` check; a wrong-key negative test is part of the verification.
- GitHub Actions artifacts and, when enabled, build provenance attestations provide a trail from
  source SHA to published `.deb`.

## Key compromise

If the signing key, the `GPG_PRIVATE_KEY`/`GPG_PASSPHRASE` secrets, or the GitHub account is
compromised:

1. Revoke the signing subkey using the offline revocation certificate.
2. Rotate the CI secrets and the `apt-signing` environment.
3. Publish a newly signed repository with a new key and announce the new fingerprint prominently.
4. Audit workflow runs and repository history for unauthorised changes.
5. Publish a security advisory with the exposure window.

Users should treat any repository metadata signed by a revoked or unknown key as untrusted.

## Supported versions

Only the latest published version of each package is supported. Older versions may remain in the
repository for rollback but do not receive fixes.
