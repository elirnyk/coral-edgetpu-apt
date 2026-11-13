# Build environment patches

Patches in this directory are applied to the **ephemeral upstream checkout** at build
time, never committed upstream and never shipped as part of a package. They exist only
when an upstream build script cannot run on a suite image as-is.

Rules:

- One patch per problem, named `<suite-or-distro>-<what>.patch`.
- Unified diff, applied with `git apply --verbose` from the upstream source root.
- Every patch **must** be applicable to the pinned upstream SHA. If it stops applying,
  the build fails loudly rather than silently skipping the fix.
- Because these patches modify upstream build files, they are licensed under the
  licence of the patched file (Apache-2.0 for `libedgetpu`), not the MIT licence of
  this repository. Each patch carries a change notice in its header.
- The publish step records the applied patch file names in
  `meta/manifest.json`, so every published package can be traced to the exact build
  environment.

## Current patches

| Patch | Applies to | Reason |
|---|---|---|
| `resolute-sources.patch` | `docker/update_sources.sh` (libedgetpu, suite `resolute`) | Upstream only special-cases `noble` for Ubuntu's deb822 sources. Ubuntu 26.04 needs the archive pinned to `amd64` and `ports.ubuntu.com` added for `arm64`/`armhf`. |
| `resolute-uint8.patch` | `driver/usb/usb_device_interface.h` (libedgetpu, suite `resolute`) | Ubuntu's libstdc++ no longer exposes `uint8_t`/`uint16_t` transitively, while Debian still does. Adds `#include <cstdint>` so the upstream header compiles unchanged on Ubuntu. |
