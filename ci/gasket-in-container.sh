#!/usr/bin/env bash
# Runs inside a plain suite container as root.
#
# Layout inside the container (see scripts/build-gasket.sh):
#   /work       bind mount of the build scratch dir; /work/src is the checkout
#               and dpkg-buildpackage writes ../*.deb into /work
#   /work/out   collected artifacts
#
# Environment:
#   VERSION         suite-suffixed package version for debian/changelog
#   SUITE           APT suite (trixie, resolute, ...)
#   HEADERS_PACKAGE kernel headers metapackage for the suite
#
# gasket-dkms is Architecture: all: it packages the DKMS source and the module
# is compiled on the target. The smoke test here compiles it against the
# suite's real kernel headers, so a broken driver fails the build instead of the
# user's machine.
set -euo pipefail

cd /work/src

echo ":: upstream commit $(git rev-parse HEAD)"
echo ":: version=${VERSION} suite=${SUITE} headers=${HEADERS_PACKAGE}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  debhelper dh-dkms dkms dpkg-dev build-essential ca-certificates python3

# Rewrite only debian/changelog metadata (suite suffix / rebuild suffix).
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

dpkg-buildpackage -b -us -uc

mkdir -p /work/out
mv /work/*.deb /work/*.changes /work/*.buildinfo /work/out/ 2>/dev/null || true
ls -l /work/out

if [[ -z "${HEADERS_PACKAGE}" ]]; then
  echo ":: no headers package configured; skipping the DKMS smoke test"
  exit 0
fi

echo ":: DKMS compile smoke test against ${HEADERS_PACKAGE}"
apt-get install -y -qq --no-install-recommends "${HEADERS_PACKAGE}"

# Let the package's postinst stay out of the way: it builds for the kernels it
# finds in /lib/modules and installs them, which is what the verify job
# exercises against the published repository. Here the goal is only to prove
# that the driver still compiles against this suite's kernel headers, so drive
# DKMS explicitly and fail loudly if it does not.
mkdir -p /etc/dkms
: >/etc/dkms/no-autoinstall
apt-get install -y -qq --no-install-recommends /work/out/gasket-dkms_*.deb

src_dir="$(ls -d /usr/src/gasket-* | head -1)"
module_name="$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' "${src_dir}/dkms.conf")"
module_version="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "${src_dir}/dkms.conf")"
kernel_version="$(
  basename "$(ls -d /usr/src/linux-headers-* | grep -v -- '-common$' | head -1)"
)"
kernel_version="${kernel_version#linux-headers-}"

echo ":: dkms build ${module_name}/${module_version} -k ${kernel_version}"
dkms add "${module_name}/${module_version}"
dkms build "${module_name}/${module_version}" -k "${kernel_version}"
dkms status

built=0
while IFS= read -r module; do
  echo ":: built ${module}"
  built=$((built + 1))
done < <(find "/var/lib/dkms/${module_name}" \( -name 'gasket.ko' -o -name 'apex.ko' \))

if [[ "${built}" -lt 2 ]]; then
  echo ":: error: expected gasket.ko and apex.ko, found ${built}" >&2
  exit 1
fi
echo ":: DKMS smoke test passed"
