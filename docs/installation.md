# Installation

The repository serves signed packages for Debian 13 (`trixie`) and Ubuntu 26.04 LTS (`resolute`).
The same instructions apply to derivatives that follow those suites (for example Raspberry Pi OS 13).

## Requirements

- A suite with **Linux ≥ 6.12** if you install `gasket-dkms`.
- `curl`, `gpg`, and `apt` (present on all supported systems).
- Root (or `sudo`) for installation.
- DKMS builds on install: the host needs kernel headers, which the `gasket-dkms` dependencies pull
  in automatically on Debian/Ubuntu.

## 1. Fetch and verify the signing key

```sh
sudo install -d -m 0755 /usr/share/keyrings

cd /tmp
curl -fsSLO https://elirnyk.github.io/coral-edgetpu-apt/coral-edgetpu.gpg
curl -fsSLO https://elirnyk.github.io/coral-edgetpu-apt/coral-edgetpu.gpg.sha256
sha256sum -c coral-edgetpu.gpg.sha256
gpg --show-keys --with-fingerprint coral-edgetpu.gpg
```

The fingerprint must match the one published in the top-level `README.md` and in
[signing-and-verification.md](signing-and-verification.md). If it does not, stop and do not install
the key.

```sh
sudo install -m 0644 coral-edgetpu.gpg /usr/share/keyrings/coral-edgetpu.gpg
```

The ASCII-armored copy is at <https://elirnyk.github.io/coral-edgetpu-apt/coral-edgetpu.asc> if you
prefer to inspect it first; `gpg --dearmor` it into the keyring path above.

## 2. Add the source

### Debian 13 (trixie)

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

### Ubuntu 26.04 LTS (resolute)

Identical, with `Suites: resolute`.

### One-line format

If your tooling does not read deb822 files:

```sh
echo "deb [signed-by=/usr/share/keyrings/coral-edgetpu.gpg] https://elirnyk.github.io/coral-edgetpu-apt trixie main" \
  | sudo tee /etc/apt/sources.list.d/coral-edgetpu.list
```

Always keep `signed-by=`. Never use `[trusted=yes]`.

## 3. Update and inspect

```sh
sudo apt update
apt-cache policy libedgetpu1-std libedgetpu1-max libedgetpu-dev gasket-dkms
```

`apt update` must finish without signature or hash warnings. The candidate versions should carry the
`+trixie` / `+resolute` suffix.

## 4. Install

### USB Accelerator

```sh
sudo apt install libedgetpu1-std      # throttled
# or
sudo apt install libedgetpu1-max      # maximum clock
```

The two variants cannot be installed together because they ship the same library path. If you want
to switch variants:

```sh
sudo apt install libedgetpu1-max libedgetpu1-std-
```

USB devices do not use `gasket`.

### PCIe / M.2 Accelerator

```sh
sudo apt install libedgetpu1-std gasket-dkms
sudo reboot
```

The `gasket-dkms` postinst registers the module with DKMS and builds it against the installed kernel
headers. A reboot is required so the module is loaded with the running kernel.

After reboot:

```sh
dkms status
lsmod | grep -E 'gasket|apex'
ls -l /dev/apex_0
sudo dmesg | grep -i -E 'gasket|apex'
```

`/dev/apex_0` is created by the udev rule shipped in the package. To grant a user access:

```sh
sudo usermod -aG apex "$USER"
# log out and back in
```

### Development files

```sh
sudo apt install libedgetpu-dev
```

This pulls in one of the runtime variants and provides the headers/symlink used to build against
`libedgetpu.so`.

## Secure Boot

DKMS modules must be signed for the kernel to load them when Secure Boot is enabled. On Debian and
Ubuntu, `dkms` normally signs with the machine's MOK key. If `modprobe gasket` fails with
`Key was rejected by service`, enroll a MOK key and rebuild:

```sh
mokutil --sb-state
sudo dpkg-reconfigure gasket-dkms     # rebuild and re-sign
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der   # if not already enrolled
```

The exact MOK path varies; see your distribution's DKMS/Secure Boot documentation. Rebooting into
the MOK manager is required after `mokutil --import`.

## Pin or hold versions

To prevent unattended upgrades of the runtime or driver:

```sh
sudo apt-mark hold libedgetpu1-std gasket-dkms
```

To pin to the repository only (if another source ships the same package names):

```sh
sudo tee /etc/apt/preferences.d/coral-edgetpu.pref >/dev/null <<'EOF'
Package: libedgetpu1-std libedgetpu1-max libedgetpu-dev gasket-dkms
Pin: origin elirnyk.github.io
Pin-Priority: 1001
EOF
```

Do not combine this repository with Google's `coral.ai` repository: the package names are identical.
Remove Google's packages and source entry first, as described in the README.

## Containers and CI images

APT works normally inside containers, but hardware access does not:

- `libedgetpu` can be installed and linked in any container matching the suite.
- `gasket-dkms` cannot load modules in an unprivileged container. For hardware use, run the
  container with `--device /dev/apex_0` and install the driver on the host.
- Building images that need the library should install `libedgetpu1-std` (or `-max`) and keep the
  matching keyring in the image.

## Offline installs

```sh
apt-get download libedgetpu1-std
```

Transfer the `.deb` (and `gasket-dkms` if needed) to the offline host and install with
`sudo apt install ./libedgetpu1-std_*.deb`. Dependencies must already be available or downloaded the
same way. Repository metadata verification only applies to online `apt update`; verify `.deb`
checksums against the signed `Packages` file if you need the same assurance offline.

## Downgrades

Older versions are retained for a limited number of releases (default: three per package and
suite). List what is still available:

```sh
apt-cache madison libedgetpu1-std
sudo apt install libedgetpu1-std=<version>
```

If a needed version has been pruned, open an issue with the version and suite.

## Removing the repository

```sh
sudo apt remove libedgetpu1-std libedgetpu1-max libedgetpu-dev gasket-dkms
sudo rm -f /etc/apt/sources.list.d/coral-edgetpu.{sources,list}
sudo rm -f /etc/apt/preferences.d/coral-edgetpu.pref
sudo rm -f /usr/share/keyrings/coral-edgetpu.gpg
sudo apt update
```

DKMS removes the built modules when `gasket-dkms` is purged. Reboot if the module is still loaded.
