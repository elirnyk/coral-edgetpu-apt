# Troubleshooting

## APT cannot verify the repository

### `NO_PUBKEY` / `The following signatures couldn't be verified`

The keyring is missing, unreadable, or in the wrong format.

```sh
ls -l /usr/share/keyrings/coral-edgetpu.gpg
gpg --show-keys --with-fingerprint /usr/share/keyrings/coral-edgetpu.gpg
```

- `apt` must be able to read the file as `_apt`. `0644` is the correct mode.
- The `Signed-By` path must point at the keyring, not at an ASCII-armored `.asc` file.
- If you installed the key with `curl | sudo tee` but the file is empty, re-run the download and check
  for a `404`.

Re-fetch and verify:

```sh
cd /tmp
curl -fsSLO https://elirnyk.github.io/coral-edgetpu-apt/coral-edgetpu.gpg
gpg --show-keys --with-fingerprint coral-edgetpu.gpg
sudo install -m 0644 coral-edgetpu.gpg /usr/share/keyrings/coral-edgetpu.gpg
```

### `EXPKEYSIG` / `KEYEXPIRED`

The published key has no expiry, so this indicates an old keyring after a rotation. Re-fetch the
keyring and compare the fingerprint with the README.

### `Hash Sum mismatch` or `File has unexpected size`

Usually a stale CDN or a half-finished deployment:

```sh
sudo apt clean
sudo rm -rf /var/lib/apt/lists/*
sudo apt update
```

If it persists, check whether a publish job is still running, then open an issue.

### `404 Not Found` for `dists/<suite>/InRelease`

The suite is wrong (supported: `trixie`, `resolute`) or the repository has never published that
suite. Check the README table and the Pages index:

```sh
curl -fsS https://elirnyk.github.io/coral-edgetpu-apt/
```

### `Release file ... is not valid yet` / clock errors

Check the system clock (`timedatectl`). APT rejects metadata dated in the future.

## Package conflicts

### `libedgetpu1-std` and `libedgetpu1-max` cannot be installed together

Expected: both ship the same library path. Choose one, or switch:

```sh
sudo apt install libedgetpu1-max libedgetpu1-std-
```

### Same package names from Google's repository

If `apt update` reports duplicate sources or installs keep changing hands, remove Google's
`coral.ai` repository and its packages first (see the README section "Switching from the coral.ai
repository").

```sh
apt-cache policy libedgetpu1-std
```

The `+trixie` / `+resolute` suffix identifies packages from this repository.

### `libgcc1` dependency

`libgcc1` is a virtual package provided by `libgcc-s1` on trixie and resolute, so it resolves
normally. If a third-party repository has broken the dependency chain, install `libgcc-s1`.

## gasket / DKMS

### `gasket-dkms` fails to install or build

Check the kernel version first:

```sh
uname -r
```

The modern driver requires **Linux ≥ 6.12**. Debian 12 (6.1), Ubuntu 22.04 (5.15), and Ubuntu 24.04
(6.8) cannot build it. There is no workaround in this repository; use a supported suite or the
vendor's older driver.

Then inspect the DKMS log:

```sh
dkms status
cat /var/lib/dkms/gasket/*/build/make.log
```

Common causes:

- Missing kernel headers: `sudo apt install linux-headers-$(uname -r)` (the package's dependency
  normally handles this, but custom kernels may not have a headers package).
- Secure Boot rejecting the module (see below).
- A kernel newer than the driver supports; check the upstream project for an update.

### `modprobe: ERROR: could not insert 'gasket': Key was rejected by service`

Secure Boot is enabled and the DKMS module is not signed with an enrolled key.

```sh
mokutil --sb-state
sudo dpkg-reconfigure gasket-dkms
```

Enroll the machine's MOK key if it is not already enrolled, then reboot. On Debian/Ubuntu the key is
usually under `/var/lib/shim-signed/mok/`. The exact flow depends on the distribution.

### `/dev/apex_0` does not exist

```sh
lsmod | grep -E 'gasket|apex'
sudo dmesg | grep -i -E 'gasket|apex'
lspci -nn | grep -i coral
```

- The module is not loaded: reboot or `sudo modprobe gasket`.
- The device is not visible in `lspci`: check the PCIe/M.2 seating and power.
- USB devices do not create `/dev/apex_*`; they use the USB runtime only.

### `Permission denied` when opening `/dev/apex_0`

The node is owned by group `apex`:

```sh
sudo usermod -aG apex "$USER"
# log out and back in
```

### Module works until a kernel update

DKMS normally rebuilds on kernel upgrades. If it did not, headers for the new kernel were probably
missing:

```sh
sudo apt install linux-headers-$(uname -r)
sudo dkms autoinstall
```

## Hardware and runtime

### `libedgetpu` installed but no device is detected

- USB: check `lsusb` for `18d1:9302` (or the device's ID) and the USB cable/port.
- PCIe: `lspci -nn` should list the Coral device, and `/dev/apex_0` should exist.
- Permission issues appear as "failed to open device" from applications; check the `apex` group
  (PCIe) or the udev rule from the runtime package (USB).

### Temperature or throttling

`libedgetpu1-max` runs the device at maximum clock and can get hot; use `libedgetpu1-std` for
long-running inference. USB Accelerators need airflow, especially with `-max`.

## CI build failures

- Bazel/TensorFlow builds can fail on out-of-memory or disk exhaustion. Check the job log for
  `Killed` or `No space left on device`; the workflow frees disk before building and caps Bazel
  parallelism.
- Ubuntu 26.04 builds depend on a build-environment patch for deb822 sources; the job log lists the
  applied patch files.
- A DKMS smoke-test failure means the driver no longer compiles against that suite's kernel. File an
  upstream issue and hold the last good SHA (see `docs/maintenance.md`).

Report repository problems via a GitHub issue. Report driver or runtime bugs to the upstream
projects, not here.

## GitHub Pages / CDN

- Deployments take a few minutes to propagate. If a brand-new release is missing, retry later rather
  than `apt clean` first.
- `dists/`, `pool/`, and the key are all static files; if one is missing while another is present,
  the deployment was interrupted. Re-run `publish.yml` for the build run.
