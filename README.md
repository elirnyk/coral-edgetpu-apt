# Unofficial Coral Edge TPU APT repository

[![libedgetpu build](https://github.com/elirnyk/coral-edgetpu-apt/actions/workflows/build-libedgetpu.yml/badge.svg)](https://github.com/elirnyk/coral-edgetpu-apt/actions/workflows/build-libedgetpu.yml)
[![gasket build](https://github.com/elirnyk/coral-edgetpu-apt/actions/workflows/build-gasket.yml/badge.svg)](https://github.com/elirnyk/coral-edgetpu-apt/actions/workflows/build-gasket.yml)
[![verify](https://github.com/elirnyk/coral-edgetpu-apt/actions/workflows/verify.yml/badge.svg)](https://github.com/elirnyk/coral-edgetpu-apt/actions/workflows/verify.yml)

A signed APT repository with packages for Google Coral Edge TPU devices, built in GitHub Actions
directly from upstream source and published on GitHub Pages:

| Component | Upstream source | Packages |
|---|---|---|
| Userspace runtime | [feranick/libedgetpu](https://github.com/feranick/libedgetpu) | `libedgetpu1-std`, `libedgetpu1-max`, `libedgetpu-dev` |
| PCIe/M.2 kernel driver | [erikpendragon/gasket-driver](https://github.com/erikpendragon/gasket-driver) | `gasket-dkms` |

> **This is an unofficial repository.** It is not affiliated with, endorsed by, or supported by
> Google, Coral, Debian, Ubuntu, or the upstream maintainers. Upstream projects remain the source
> of truth; report bugs in the software to the upstream projects.

## Supported systems

| Suite | Codename | Architectures | `libedgetpu` | `gasket-dkms` |
|---|---|---|---|---|
| Debian 13 | `trixie` | amd64, arm64, armhf | yes | yes |
| Ubuntu 26.04 LTS | `resolute` | amd64, arm64, armhf | yes | yes |

- The gasket driver requires **Linux ≥ 6.12**. Older suites (Debian 12, Ubuntu 22.04/24.04) are not
  supported by this repository. See [troubleshooting](docs/troubleshooting.md).
- `gasket-dkms` is only needed for **PCIe/M.2** Coral devices. USB Accelerators need
  `libedgetpu1-std` or `libedgetpu1-max` only.
- Raspberry Pi OS 13 (trixie) and other Debian 13 arm64/armhf derivatives are covered by the
  `trixie` suite.

## Install

### 1. Add the signing key

```sh
sudo install -d -m 0755 /usr/share/keyrings
curl -fsSL https://elirnyk.github.io/coral-edgetpu-apt/coral-edgetpu.gpg \
  | sudo tee /usr/share/keyrings/coral-edgetpu.gpg >/dev/null
sudo chmod 0644 /usr/share/keyrings/coral-edgetpu.gpg
```

Check the fingerprint before you trust it:

```sh
gpg --show-keys --with-fingerprint /usr/share/keyrings/coral-edgetpu.gpg
# Expected: 22234DCCC8AAB3475B5F495CBB1DFCCA79E3A376
```

The same key is available as ASCII armor at
<https://elirnyk.github.io/coral-edgetpu-apt/coral-edgetpu.asc>, with a SHA256 file next to the binary
key. See [verifying the repository](docs/signing-and-verification.md).

### 2. Add the repository

Debian 13 (`trixie`) — recommended deb822 format:

```sh
sudo tee /etc/apt/sources.list.d/coral-edgetpu.sources >/dev/null <<'EOF'
Types: deb
URIs: https://elirnyk.github.io/coral-edgetpu-apt
Suites: trixie
Components: main
Architectures: amd64 arm64 armhf
Signed-By: /usr/share/keyrings/coral-edgetpu.gpg
EOF
```

Ubuntu 26.04 LTS (`resolute`) — same file with `Suites: resolute`.

One-line equivalent for older tooling:

```sh
echo "deb [signed-by=/usr/share/keyrings/coral-edgetpu.gpg] https://elirnyk.github.io/coral-edgetpu-apt trixie main" \
  | sudo tee /etc/apt/sources.list.d/coral-edgetpu.list
```

### 3. Install packages

```sh
sudo apt update

# Userspace runtime — choose ONE of the two variants:
sudo apt install libedgetpu1-std    # throttled (lower temperature)
# sudo apt install libedgetpu1-max  # maximum clock (runs hot)

# Headers, only if you build against libedgetpu:
sudo apt install libedgetpu-dev

# PCIe/M.2 Coral devices only:
sudo apt install gasket-dkms
sudo reboot
```

After the reboot, verify the driver and device:

```sh
dkms status                 # gasket/<version>, <kernel>: installed
lsmod | grep -E 'gasket|apex'
ls -l /dev/apex_0
```

To use the device without root, add your user to the `apex` group and log in again:

```sh
sudo usermod -aG apex "$USER"
```

## Packages

| Package | Contents |
|---|---|
| `libedgetpu1-std` | `libedgetpu.so.1` at the throttled clock — the safe default |
| `libedgetpu1-max` | `libedgetpu.so.1` at maximum clock; conflicts at file level with `-std` |
| `libedgetpu-dev` | headers and the `libedgetpu.so` development symlink |
| `gasket-dkms` | DKMS source for `gasket`/`apex`, udev rule, `apex` group setup |

`libedgetpu1-std` and `libedgetpu1-max` install the same path and cannot be installed together.
Pick one; to switch, `sudo apt install libedgetpu1-max libedgetpu1-std-` (or remove `-std` first).

`gasket-dkms` is a source package: the module is compiled on your machine at install time against
your running kernel's headers. No prebuilt kernel modules are published, so the driver follows
kernel upgrades without waiting for a repository rebuild.

## Verify the repository

```sh
apt-cache policy libedgetpu1-std gasket-dkms
```

Manual metadata check:

```sh
cd /tmp
curl -fsSLO https://elirnyk.github.io/coral-edgetpu-apt/dists/trixie/InRelease
gpgv --keyring /usr/share/keyrings/coral-edgetpu.gpg InRelease
```

`apt update` must complete without `NO_PUBKEY`, `EXPKEYSIG`, or `Hash Sum mismatch` warnings. If it
does not, see [troubleshooting](docs/troubleshooting.md).

## Versions

Packages are versioned as:

```
<upstream version>+<suite>[+git<date>.<sha>]
```

Examples: `16.0tf2.19.1-1+trixie`, `1.0-19~modern2+resolute`,
`1.0-19~modern2+trixie+git20260924.a1058f6b`.

A `+git…` component means upstream moved without bumping `debian/changelog`; it is not a patch.
No source or packaging logic is changed by this project. Build provenance and the exact upstream
commits are recorded in
[`meta/manifest.json`](https://elirnyk.github.io/coral-edgetpu-apt/meta/manifest.json).

## Switching from the coral.ai repository

The package names are the same as those in Google's repository. Remove the old packages and source
entry first, otherwise APT sees two sources for the same packages:

```sh
sudo apt remove libedgetpu1-std libedgetpu1-max gasket-dkms
sudo rm -f /etc/apt/sources.list.d/coral-edgetpu.list   # Google's file, if present
```

Then follow the install steps above.

## Removing the repository

```sh
sudo apt remove libedgetpu1-std libedgetpu1-max libedgetpu-dev gasket-dkms
sudo rm -f /etc/apt/sources.list.d/coral-edgetpu.{sources,list}
sudo rm -f /usr/share/keyrings/coral-edgetpu.gpg
sudo apt update
```

## Documentation

- [Installation details](docs/installation.md) — per-suite steps, Secure Boot, pinning, containers
- [Signing and verification](docs/signing-and-verification.md) — key, fingerprint, manual checks
- [Architecture](docs/architecture.md) — how the pipeline builds and publishes packages
- [Maintenance](docs/maintenance.md) — runbooks for rebuilds, key rotation, new suites
- [Troubleshooting](docs/troubleshooting.md) — common APT, DKMS, and device errors
- [Security policy](SECURITY.md) · [Contributing](CONTRIBUTING.md)

## How it works

```text
cron / manual dispatch
        │
        ▼
  poll upstream HEAD ──► build (Docker + Bazel / debuild) ──► publish (reprepro + GPG) ──► gh-pages
                                                                       │
                                                                       └──► container verification
```

- Upstream commits are pinned by SHA; source tarballs are archived for reproducibility.
- The repository index is signed; the signing key is only used in a protected CI environment.
- Only the repository metadata is signed — APT validates every package against the signed index.

## License

The automation and documentation in this repository are licensed under the
[MIT License](LICENSE). The packages are built from upstream sources and carry their own licenses:
`libedgetpu` is [Apache-2.0](licenses/Apache-2.0.txt), `gasket-dkms` is
[GPL-2.0](licenses/GPL-2.0.txt). See [NOTICE](NOTICE) for attribution and licence texts.
