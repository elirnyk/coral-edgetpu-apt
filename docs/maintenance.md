# Maintenance

Operational runbooks for the repository. All commands assume the `gh` CLI is authenticated and run
from the repository root.

## Routine checks

| Cadence | Check |
|---|---|
| Daily | `poll-upstream` ran; build failures notify by email |
| Weekly | `verify` workflow is green; `apt update` works on trixie and resolute |
| Monthly | `meta/manifest.json` matches the upstream default branches |
| Yearly | `du -sh` on a `gh-pages` checkout (Pages limit: 1 GB); key/fingerprint review |

```sh
gh run list --limit 20
curl -fsS https://elirnyk.github.io/coral-edgetpu-apt/meta/manifest.json | jq .
```

## Rebuild a specific upstream commit

Useful for reproducing a release or retrying after an infrastructure failure:

```sh
gh workflow run build-libedgetpu.yml \
  -f sha=<full-sha> \
  -f version=<upstream changelog version> \
  -f suites=trixie,resolute \
  -f rebuild=1
```

`rebuild=1` appends `+rebuildN` to the version so APT clients see an upgrade. Then publish the run:

```sh
gh workflow run publish.yml -f run_id=<run-id>
```

If the source SHA is no longer reachable upstream, restore it from the archived source release
(tag `<component>-<sha>`, asset `sources-<component>-<sha>.tar.gz`) instead of cloning.

## Publish a build whose publish step failed

The build artifacts are retained for 90 days. Re-run publish against the build run:

```sh
gh run list --workflow=build-libedgetpu.yml --limit 5
gh workflow run publish.yml -f run_id=<build-run-id>
```

Publishing is idempotent: `reprepro include` ignores packages already present with identical
checksums and fails loudly on a checksum mismatch (which means a version was reused incorrectly).

## Hold upstream changes

If a new upstream commit breaks the build, stop automatic publishing without changing the
repository:

```yaml
# config/repo.yml
upstreams:
  libedgetpu:
    repo: feranick/libedgetpu
    ref: master
    hold: <last-good-sha>
```

With `hold` set, `poll-upstream` keeps building that SHA or skips entirely, and the published repo
stays on the last good version. File the issue upstream; do not patch upstream code here.

## Add a suite

1. Add an entry to `config/repo.yml`:
   ```yaml
   suites:
     forky:
       family: debian
       image: debian:forky
       description: Debian 14 (forky)
       arches: [amd64, arm64, armhf]
       headers: linux-headers-amd64
       kernel_image: linux-image-amd64
   ```
   Build matrices, the reprepro distribution and pruning all follow from this.
2. Add the suite to the `verify.yml` matrix (suites are listed there explicitly because the runner
   and platform differ per architecture).
3. Run both build workflows, then publish.
4. Update the README table and `docs/installation.md`.

The signing key is unchanged: all suites share the same `Signed-By` keyring.

## Retire a suite

1. Remove the suite from `config/repo.yml`, the workflow matrices, and the README.
2. Stop publishing it. Existing metadata can be left in place for a deprecation window.
3. After the window, delete `dists/<suite>` and run `reprepro deleteunreferenced` to drop its
   packages. Announce the removal in a pinned issue.

Do not delete `dists/<suite>` while clients still have the source configured: `apt update` would
fail with a 404.

## Prune old versions

Default retention is the last three versions per package and suite:

```sh
scripts/prune-repo.sh --keep 3 --dry-run
scripts/prune-repo.sh --keep 3
```

Under the hood:

```sh
reprepro -b "$REPO" --list-format '${package}|${version}\n' list trixie
reprepro -b "$REPO" removefilter trixie '$Package (== libedgetpu1-std), $Version (== <old-version>)'
reprepro -b "$REPO" deleteunreferenced
reprepro -b "$REPO" export trixie
```

`removefilter` with an explicit `$Version` condition is used because reprepro's plain `remove`
deletes every version of a package, which retention must not do.

Versions are suite-suffixed, so removing a version from one suite never deletes files used by
another.

## Rotate the signing key

1. **Offline:** generate a new primary (certify only) and signing subkey. Keep the primary secret
   and the revocation certificate offline.
2. **CI:** export only the new secret subkeys and store them:
   ```sh
   gpg --export-secret-subkeys --armor <new-fpr> > /tmp/ci-signing.asc
   gh secret set GPG_PRIVATE_KEY --env apt-signing < /tmp/ci-signing.asc
   gh secret set GPG_PASSPHRASE --env apt-signing
   ```
3. **Overlap:** add the new public key next to the old one in `coral-edgetpu.gpg` and configure
   reprepro to sign with both (`SignWith: <old-fpr> <new-fpr>`, no `!`). Publish and verify.
4. **Docs:** update the fingerprint in `README.md`,
   `docs/signing-and-verification.md`, and `meta/manifest.json`.
5. **Retire:** after the overlap window, sign with the new key only, remove the old key from the
   keyring, delete the old CI secret, and publish the old key's revocation certificate.

## Disaster recovery

### `gh-pages` branch lost or corrupted

1. Create a new orphan branch with `.nojekyll`.
2. Restore `conf/` from the repository (it is committed) or from the previous deployment.
3. Re-import every `.deb` still available in `pool/` (or from build artifacts):
   ```sh
   for d in pool/main/*/*/*.deb; do reprepro -b "$REPO" includedeb <suite> "$d"; done
   ```
4. Re-export, re-sign, push. If `db/` was lost, the version list must be reconstructed from the
   `.deb` filenames; `scripts/publish-repo.sh --rebuild-db` does this.

### Signing key lost

The repository cannot be updated safely. Revoke the old key with the offline revocation certificate,
generate a new key, and follow the rotation procedure. Announce the new fingerprint; users must
re-fetch the keyring.

### Pages deployment quota or outage

The package set is small (well under the 1 GB limit). If Pages is unavailable, builds still succeed;
re-run `publish.yml` after the outage. A mirror on another static host can be added later without
changing package versions.

## Upstream updates

- Bazel and TensorFlow versions come from upstream (`docker/Dockerfile`, `WORKSPACE`). Do not bump
  them locally; wait for upstream or pin the last good SHA with `hold`.
- New Debian/Ubuntu releases often need a sources fix in the build environment. Add a patch under
  `buildenv/` and record it in the build manifest.
- Dependabot keeps GitHub Actions pinned versions current. Review those PRs; they require a
  successful `verify` run before merging.

## Reproduce a build locally

```sh
git clone https://github.com/feranick/libedgetpu src
cd src && git checkout <sha>

docker build -t libedgetpu-build --build-arg IMAGE=debian:trixie docker/
docker run --rm -v "$PWD:/workspace" -w /workspace libedgetpu-build \
  bash -c 'for cpu in k8 armv7a aarch64; do make CPU=$cpu libedgetpu; done'

# Package (run inside a matching distro container with debhelper, dpkg-dev, fakeroot)
dch --newversion "$(dpkg-parsechangelog -SVersion)+trixie" --distribution trixie --force-distribution
dpkg-buildpackage -b -us -uc -a amd64 -d
```

Compare the resulting package version, file list, and `libedgetpu.so.1` hash with the published
artifact. Bazel builds are not byte-for-byte reproducible across environments, so compare behavior
and metadata rather than the `.deb` checksum.

## Monitoring and alerting

- GitHub sends failure notifications for scheduled workflows to repository admins.
- The `verify` workflow is the canary for the published repository; keep its weekly schedule.
- A stale `meta/manifest.json` (older than ~30 days) is expected when upstream is idle; it is not an
  error by itself.
