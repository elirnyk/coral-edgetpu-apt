#!/usr/bin/env bash
# Runs inside the upstream libedgetpu build container, as the mapped host user.
#
# Environment:
#   CPUS    upstream CPU names to compile (k8, aarch64, armv7a)
#   ARCHES  Debian architectures to package (amd64, arm64, armhf)
#   VERSION suite-suffixed package version to write into debian/changelog
#   SUITE   APT suite (trixie, resolute, ...)
#
# The Bazel/TensorFlow compile is the expensive part and happens once per CPU.
# Packaging is a pure file-copy step in upstream's debian/rules, so the three
# dpkg-buildpackage runs are cheap.
set -euo pipefail

cd /work/src

# Start from a clean artifact directory so a retried build cannot mix stale
# .deb/.changes files from a previous attempt.
rm -rf /work/out
mkdir -p /work/out

echo ":: upstream commit $(git rev-parse HEAD)"
echo ":: cpus=${CPUS} arches=${ARCHES} version=${VERSION} suite=${SUITE}"

# dpkg-buildpackage runs under fakeroot when it is not root; the upstream image
# does not ship it.
if ! command -v fakeroot >/dev/null 2>&1; then
  echo ":: installing fakeroot"
  sudo apt-get install -y -qq fakeroot ||
    { sudo apt-get update -qq && sudo apt-get install -y -qq fakeroot; }
fi

# Some Ubuntu images ship a toolchain without `ld` on PATH, which Bazel needs
# at link time. Make sure binutils is present.
if ! command -v ld >/dev/null 2>&1; then
  echo ":: installing binutils"
  sudo apt-get update -qq
  sudo apt-get install -y -qq binutils
fi

for cpu in ${CPUS}; do
  echo ":: bazel build for CPU=${cpu}"
  make CPU="${cpu}" libedgetpu
done

# Restore the pristine changelog so a retried build does not stack entries.
git checkout -- debian/changelog 2>/dev/null || true

# Rewrite only debian/changelog metadata: the suite suffix (and any git or
# rebuild suffix). No upstream source or packaging logic is touched.
python3 - "${VERSION}" "${SUITE}" <<'PY'
import email.utils
import subprocess
import sys

version, suite = sys.argv[1], sys.argv[2]
path = "debian/changelog"
package = subprocess.check_output(
    ["dpkg-parsechangelog", "-l", path, "-SSource"], text=True
).strip()
stamp = email.utils.formatdate(localtime=True)
entry = (
    f"{package} ({version}) {suite}; urgency=medium\n"
    f"\n"
    f"  * Automated build from upstream source for the {suite} suite.\n"
    f"\n"
    f" -- coral-edgetpu-apt automation <edgetpumaint@gmail.com>  {stamp}\n"
    f"\n"
)
with open(path, encoding="utf-8") as handle:
    previous = handle.read()
with open(path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(entry + previous)
print(f":: changelog entry: {package} ({version}) {suite}")
PY

mkdir -p /work/out

for arch in ${ARCHES}; do
  case "${arch}" in
    amd64) cpu=k8 ;;
    arm64) cpu=aarch64 ;;
    armhf) cpu=armv7a ;;
    *)
      echo ":: error: unsupported architecture ${arch}" >&2
      exit 1
      ;;
  esac
  for variant in throttled direct; do
    if [[ ! -f "out/${variant}/${cpu}/libedgetpu.so.1.0" ]]; then
      echo ":: error: missing out/${variant}/${cpu}/libedgetpu.so.1.0" >&2
      exit 1
    fi
  done
  echo ":: dpkg-buildpackage for ${arch} (CPU=${cpu})"
  # -tc cleans the source tree after each build so debian/files does not
  # accumulate across the three architectures (this mirrors upstream's `deb:`
  # target); -d skips build dependencies because packaging is compile-free.
  dpkg-buildpackage -rfakeroot -us -uc -tc -b -a"${arch}" -d
done

# With -tc the .deb/.changes/.buildinfo land in the parent of the source tree.
mv /work/*.deb /work/*.changes /work/*.buildinfo /work/out/ 2>/dev/null || true
ls -l /work/out
