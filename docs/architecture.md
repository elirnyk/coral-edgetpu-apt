# Architecture

## Overview

```text
              ┌──────────────────────────── GitHub Actions ────────────────────────────┐
cron/manual ─►│ poll-upstream                                                          │
              │   reads meta/manifest.json, resolves upstream HEAD SHAs                 │
              │        │                                                               │
              │        ├──► build-libedgetpu (matrix: trixie, resolute)                 │
              │        │       Docker (upstream) + Bazel + dpkg-buildpackage            │
              │        │       artifact: deb/changes/build.json per suite               │
              │        │                                                               │
              │        └──► build-gasket (matrix: trixie, resolute)                     │
              │                dpkg-buildpackage + DKMS compile smoke test              │
              │                artifact: deb/changes/build.json per suite               │
              │                          │                                             │
              │                          ▼                                             │
              │                    publish (protected env)                             │
              │                      reprepro import → prune → sign → push gh-pages    │
              │                          │                                             │
              └──────────────────────────┼─────────────────────────────────────────────┘
                                         ▼
                                   verify (containers)
```

The `gh-pages` branch is the only persistent state (APT indexes, pool, key, `meta/manifest.json`).
Nothing is committed to `main` by automation, so branch protection is straightforward.

## Upstream pinning

Each build resolves a concrete commit:

```sh
git clone --branch <ref> --single-branch https://github.com/<owner>/<repo>.git src
git -C src checkout --detach <sha>   # or fetch <sha> if not reachable from <ref>
```

`state` is `meta/manifest.json` on `gh-pages`:

```json
{
  "schema": 1,
  "updated": "2026-11-13T04:00:00Z",
  "upstreams": {
    "libedgetpu": {"ref": "master", "sha": "c38ac3f6…", "version": "16.0tf2.19.1-1"},
    "gasket": {"ref": "main", "sha": "a1058f6b…", "version": "1.0-19~modern2"}
  },
  "builds": [
    {
      "component": "libedgetpu",
      "suite": "trixie",
      "version": "16.0tf2.19.1-1+trixie",
      "upstream_version": "16.0tf2.19.1-1",
      "ref": "master",
      "sha": "c38ac3f6…",
      "image": "debian:trixie",
      "arches": ["amd64", "arm64", "armhf"],
      "patches": [],
      "date": "2026-11-13T04:12:00Z"
    }
  ]
}
```

A source tarball for every built SHA is attached to a GitHub Release in this repository
(tag `<component>-<sha>`, asset `sources-<component>-<sha>.tar.gz`), so builds remain reproducible
even if an upstream branch is force-pushed.

## libedgetpu build

Upstream's `debian/rules` does no compilation: it packages prebuilt files from `out/`.

1. Build the upstream Docker image with `--build-arg IMAGE=<suite image>`.
2. Run the container as the runner user (upstream's `make docker-build` does this via
   `groupadd`/`useradd`/`su`; the workflow replicates it so extra mounts are possible).
3. Build all three CPUs:
   ```sh
   for cpu in k8 armv7a aarch64; do make CPU="$cpu" libedgetpu; done
   ```
   This produces `out/throttled/<cpu>` and `out/direct/<cpu>`; the Bazel build of TensorFlow Lite
   dominates the runtime.
4. For each architecture, in the source tree, rewrite only `debian/changelog` (a small Python
   heredoc, so no `devscripts` dependency is needed in the upstream image):
   ```sh
   dpkg-buildpackage -rfakeroot -us -uc -tc -b -a<arch> -d
   ```
   `-tc` cleans the tree after each pass so `debian/files` does not accumulate across the three
   architectures (this mirrors upstream's `deb:` target); `-d` skips build-dependency installation
   because `debian/rules` is a pure packaging step.
5. Upload `.deb`, `.changes`, `.buildinfo`, `build.json` and the pristine source tarball.

### Resource controls

TF/Bazel builds need roughly 15–20 GB of disk and 8+ GB of RAM. The workflow therefore:

- frees preinstalled runner disk (Android/.NET/Java caches) before building;
- mounts a `ci/bazelrc` with `--jobs` and `--local_ram_resources` limits;
- caches the Bazel output base (`$CACHE_DIR/bazel`, keyed by suite and upstream SHA);
- runs one suite per job so a failure in one suite does not block the other.

### Suite-specific build environment

Debian 13 needs no changes. Ubuntu 26.04 uses deb822 sources, while upstream's
`docker/update_sources.sh` only restricts `noble` to amd64 and adds `ports.ubuntu.com` for
arm64/armhf. A minimal `buildenv/resolute-sources.patch` is applied to the ephemeral checkout for
`resolute` (never to upstream and never to package source), and its file name is recorded in
`build.json`.

If the 26.04 toolchain still fails, the fallback is to build the resolute packages on
`ubuntu:24.04` (glibc is forward-compatible) and label them `+resolute`. The manifest records the
actual base image, so the deviation is visible.

## gasket build

The driver is `Architecture: all`; only its DKMS source is packaged. As with libedgetpu, only
`debian/changelog` is rewritten for the version/suite suffix.

```sh
dpkg-buildpackage -b -us -uc
```

Smoke test (amd64 only) in the same suite image. Auto-install is disabled so the build is
deterministic, and DKMS is driven explicitly:

```sh
apt-get install -y dkms linux-headers-<flavour>
: >/etc/dkms/no-autoinstall
apt-get install -y ./gasket-dkms_*.deb
dkms add gasket/<upstream>
dkms build gasket/<upstream> -k <headers-version>
test -n "$(find /var/lib/dkms/gasket -name gasket.ko)"
test -n "$(find /var/lib/dkms/gasket -name apex.ko)"
```

This compiles the module against the suite's real kernel headers without needing the running kernel.
The published repository is then exercised through the *real* `gasket-dkms` postinst by `verify.yml`.

## Publishing

`publish.yml` runs on `workflow_run` after either build workflow (and manually with a run id).

- `concurrency: apt-publish` (job level) serialises publishes across workflows.
- Environment `apt-signing` gates access to `GPG_PRIVATE_KEY` / `GPG_PASSPHRASE`.
- Import (`.changes` `Distribution` matches the suite because the changelog entry names the suite):
  ```sh
  reprepro -b "$REPO" include <suite> /artifacts/<component>-<suite>/*.changes
  ```
- Prune (retention), then export:
  ```sh
  reprepro -b "$REPO" removefilter <suite> '$Package (== <pkg>), $Version (== <version>)'
  reprepro -b "$REPO" deleteunreferenced
  reprepro -b "$REPO" export
  ```
  `removefilter` with an explicit `$Version` is required because reprepro's plain `remove` deletes
  every version of a package.
- Write key files, `licenses/`, `meta/manifest.json`, and a small `index.html`; ensure `.nojekyll`.
- Commit `conf/`, `db/`, `dists/`, `pool/`, `meta/` and push. On non-fast-forward: rebase and retry
  once.

### reprepro configuration

Rendered from `config/repo.yml`:

```
Origin: coral-edgetpu-apt
Label: Coral Edge TPU APT (unofficial)
Codename: trixie
Suite: trixie
Architectures: amd64 arm64 armhf
Components: main
Description: Unofficial Coral Edge TPU packages (Debian 13)
SignWith: <FINGERPRINT>
DebIndices: Packages Release . .gz .xz
```

`SignWith` is the bare fingerprint. A leading `!` is reprepro syntax for "run this hook
script", not "sign with this key", so it must not be used here.

`db/` and `conf/` are committed to `gh-pages` because reprepro needs them between runs. They contain
no secrets (the signing key lives only in the CI `GNUPGHOME`).

## Signing in CI

1. Import only the encrypted **secret signing subkey**:
   ```sh
   gpg --batch --import "$GPG_PRIVATE_KEY_FILE"
   ```
2. Allow passphrase presetting for the agent:
   ```sh
   echo allow-preset-passphrase > "$GNUPGHOME/gpg-agent.conf"
   gpgconf --kill gpg-agent
   echo "$GPG_PASSPHRASE" | gpg-preset-passphrase --preset "$KEYGRIP"
   ```
3. Run reprepro, which signs `Release` → `Release.gpg` and `InRelease`.

The primary key is not present, so CI cannot create identities, revoke keys, or rotate subkeys.

## Verification

- Post-publish `verify.yml` downloads the key from Pages, adds the deb822 source in a clean
  container, runs `apt update`, installs the packages, and checks `dkms status` / `modinfo`.
- `gpgv` validates `InRelease` independently of APT.
- A wrong-key negative test asserts that unsigned/foreign metadata is rejected.
- arm64 runs on an arm64 runner; armhf is install-tested through QEMU (`--platform linux/arm/v7`).
- A weekly scheduled run catches expired credentials, broken Pages deploys, and drifting distro
  images between releases.

## Retention and quota

GitHub Pages limits: 1 GB per site, 100 GB/month bandwidth, 10 builds/hour (soft limits).

Measured package sizes: `libedgetpu1-std` ≈ 380 KB, `libedgetpu-dev` ≈ 6 KB,
`gasket-dkms` ≈ 50 KB. A full release (2 suites × 3 arches × 3 packages) is well under 15 MB, so
the default retention of the last three versions per package/suite leaves ample headroom. Pruning
keeps the Pages site small; `db/` remains the authoritative record of what is published.

## Constraints

- No source or packaging logic changes. Only `debian/changelog` is rewritten at build time for the
  version/suite suffix, and only in the ephemeral checkout.
- No builds on pull requests from forks.
- No unsigned metadata is ever deployed; a failed signing step fails the publish.
