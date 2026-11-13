#!/usr/bin/env bash
# End-to-end verification of the published APT repository.
#
#   scripts/verify-apt.sh [options]
#
# Options:
#   --suite NAME        suite to verify                (default: first in config)
#   --arch ARCH         architecture to verify         (default: host arch)
#   --headers           also install gasket-dkms and assert the module builds
#   --key-only          only fetch/verify the key and run gpgv on InRelease
#   --container         run the checks inside the suite container image
#   --image IMAGE       override the container image
#   --platform PLATFORM docker --platform for the container (for QEMU)
#   --fingerprint FPR   expected signing fingerprint (default: config)
#   --pages-url URL     repository base URL (default: config)
#   --inside            internal: run the checks on this system
#
# The checks mirror docs/installation.md: download the key, check its sha256 and
# fingerprint, add the deb822 source, run `apt update`, validate InRelease with
# gpgv independently of APT, install the packages, and finally prove that a
# foreign key is rejected.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OPT_SUITE=""
OPT_ARCH=""
OPT_FINGERPRINT=""
OPT_PAGES_URL=""
HEADERS=0
KEY_ONLY=0
CONTAINER=0
INSIDE=0
IMAGE=""
PLATFORM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite) OPT_SUITE="$2"; shift 2 ;;
    --arch) OPT_ARCH="$2"; shift 2 ;;
    --headers) HEADERS=1; shift ;;
    --key-only) KEY_ONLY=1; shift ;;
    --container) CONTAINER=1; shift ;;
    --inside) INSIDE=1; shift ;;
    --image) IMAGE="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --fingerprint) OPT_FINGERPRINT="$2"; shift 2 ;;
    --pages-url) OPT_PAGES_URL="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo ":: error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf ':: %s\n' "$*" >&2; }
die() { printf ':: error: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ config ---
# The container mounts the repository read-only at /coral, so this works both
# on the runner and inside the container.
CONFIG_ROOT="${VERIFY_ROOT:-${ROOT}}"
have_config=0
if [[ -f "${CONFIG_ROOT}/scripts/lib/config.py" ]]; then
  have_config=1
  eval "$(python3 "${CONFIG_ROOT}/scripts/lib/config.py" --shell)"
fi

cfg_get() {
  [[ "${have_config}" == "1" ]] || return 0
  python3 "${CONFIG_ROOT}/scripts/lib/config.py" --get "$1" 2>/dev/null || true
}

if [[ "${INSIDE}" == "1" ]]; then
  SUITE="${VERIFY_SUITE:-}"
  ARCH="${VERIFY_ARCH:-}"
  HEADERS="${VERIFY_HEADERS:-0}"
  KEY_ONLY="${VERIFY_KEY_ONLY:-0}"
  FINGERPRINT="${VERIFY_FINGERPRINT:-}"
  PAGES_URL="${VERIFY_PAGES_URL:-}"

  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends python3 python3-yaml curl ca-certificates gnupg gpgv
  fi
else
  SUITE="${OPT_SUITE}"
  ARCH="${OPT_ARCH}"
  FINGERPRINT="${OPT_FINGERPRINT}"
  PAGES_URL="${OPT_PAGES_URL}"
fi

SUITE="${SUITE:-$(python3 - "${CONFIG_ROOT}/scripts/lib/config.py" <<'PY' 2>/dev/null || true
import json, subprocess, sys
out = subprocess.check_output([sys.executable, sys.argv[1], "--suites-json"], text=True)
print(json.loads(out)[0])
PY
)}"
FINGERPRINT="${FINGERPRINT:-$(cfg_get project.fingerprint)}"
PAGES_URL="${PAGES_URL:-$(cfg_get project.pages_url)}"
PAGES_URL="${PAGES_URL%/}"
: "${SUITE:?suite is required}"
: "${PAGES_URL:?pages url is required}"
: "${FINGERPRINT:?fingerprint is required}"
if [[ "${FINGERPRINT}" == "FINGERPRINT" ]]; then
  die "config/repo.yml still has the placeholder fingerprint"
fi

# --------------------------------------------------------------- container ---
if [[ "${CONTAINER}" == "1" && "${INSIDE}" == "0" ]]; then
  IMAGE="${IMAGE:-$(cfg_get "suites.${SUITE}.image")}"
  [[ -n "${IMAGE}" ]] || die "no image configured for suite ${SUITE}"
  command -v docker >/dev/null 2>&1 || die "docker is required for --container"
  log "verifying ${SUITE} inside ${IMAGE}${PLATFORM:+ (${PLATFORM})}"
  docker pull -q ${PLATFORM:+--platform "${PLATFORM}"} "${IMAGE}"
  exec docker run --rm \
    ${PLATFORM:+--platform "${PLATFORM}"} \
    -v "${ROOT}:/coral:ro" \
    -e VERIFY_ROOT=/coral \
    -e VERIFY_SUITE="${SUITE}" \
    -e VERIFY_ARCH="${ARCH}" \
    -e VERIFY_HEADERS="${HEADERS}" \
    -e VERIFY_KEY_ONLY="${KEY_ONLY}" \
    -e VERIFY_FINGERPRINT="${FINGERPRINT}" \
    -e VERIFY_PAGES_URL="${PAGES_URL}" \
    "${IMAGE}" \
    bash /coral/scripts/verify-apt.sh --inside
fi

ARCH="${ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export DEBIAN_FRONTEND=noninteractive
as_root() {
  if [[ "$(id -u)" == "0" ]]; then "$@"; else sudo "$@"; fi
}
apt_quiet() {
  as_root apt-get -qq -o Dpkg::Use-Pty=0 "$@"
}

log "suite=${SUITE} arch=${ARCH} headers=${HEADERS} key_only=${KEY_ONLY}"
log "repository ${PAGES_URL}"

# ------------------------------------------------------- 1. fetch the key ---
KEYRING="${WORK}/coral-edgetpu.gpg"
log "downloading the signing key"
curl -fsSL "${PAGES_URL}/${KEYRING_NAME:-coral-edgetpu.gpg}" -o "${KEYRING}"
curl -fsSL "${PAGES_URL}/${KEYRING_NAME:-coral-edgetpu.gpg}.sha256" -o "${KEYRING}.sha256"
log "checking the key checksum"
(cd "${WORK}" && sha256sum -c "$(basename "${KEYRING}").sha256") ||
  die "key checksum mismatch"

log "checking the key fingerprint"
actual="$(gpg --batch --show-keys --with-colons "${KEYRING}" | awk -F: '$1=="fpr"{print $10; exit}')"
[[ "${actual}" == "${FINGERPRINT}" ]] ||
  die "fingerprint ${actual} does not match the expected ${FINGERPRINT}"
log "key fingerprint ok: ${actual}"

# ---------------------------------------------- 2. validate InRelease/gpgv ---
log "downloading dists/${SUITE}/InRelease"
curl -fsSL "${PAGES_URL}/dists/${SUITE}/InRelease" -o "${WORK}/InRelease" ||
  die "cannot download dists/${SUITE}/InRelease (has the suite been published?)"
# gpgv validates the signature independently of APT's own trust database.
gpgv --keyring "${KEYRING}" "${WORK}/InRelease" ||
  die "gpgv rejected the InRelease signature"
log "InRelease signature verified with gpgv"

if [[ "${KEY_ONLY}" == "1" ]]; then
  log "key-only run complete"
  exit 0
fi

# --------------------------------------------------------- 3. add source ---
SOURCES="${WORK}/coral-edgetpu.sources"
KEYRING_INSTALLED="/usr/share/keyrings/coral-edgetpu.gpg"
as_root install -d -m 0755 /usr/share/keyrings
as_root install -m 0644 "${KEYRING}" "${KEYRING_INSTALLED}"
cat >"${SOURCES}" <<EOF
Types: deb
URIs: ${PAGES_URL}
Suites: ${SUITE}
Components: main
Architectures: $(python3 "${CONFIG_ROOT}/scripts/lib/config.py" --arches "${SUITE}" 2>/dev/null || echo "${ARCH}")
Signed-By: ${KEYRING_INSTALLED}
EOF
as_root cp "${SOURCES}" "/etc/apt/sources.list.d/coral-edgetpu.sources"

log "apt update"
as_root apt-get update -o Dpkg::Use-Pty=0 ||
  die "apt update failed against the published repository"

log "apt-cache policy"
apt-cache policy libedgetpu1-std libedgetpu1-max libedgetpu-dev gasket-dkms || true

# --------------------------------------------------------- 4. install pkgs ---
log "installing libedgetpu1-std and libedgetpu-dev"
apt_quiet install -y libedgetpu1-std libedgetpu-dev ||
  die "installing libedgetpu failed"

lib="$(find /usr/lib -name 'libedgetpu.so*' -print -quit)"
[[ -n "${lib}" ]] || die "libedgetpu.so was not installed"
log "installed ${lib}"
dpkg-query -W -f='${Package} ${Version}\n' libedgetpu1-std libedgetpu-dev

# gasket-dkms is Architecture: all and builds the module in its postinst against
# the kernels that have headers installed. In a container that means the kernel
# image and headers have to be present, so the module actually compiles.
if [[ "${HEADERS}" == "1" ]]; then
  log "installing a kernel with headers for the DKMS build"
  headers_pkg="$(cfg_get "suites.${SUITE}.headers")"
  image_pkg="$(cfg_get "suites.${SUITE}.kernel_image")"
  if [[ ! -e "/lib/modules/$(uname -r)/build" ]]; then
    [[ -n "${headers_pkg}" ]] || die "no headers package configured for ${SUITE}"
    pkgs=("${headers_pkg}")
    [[ -n "${image_pkg}" ]] && pkgs+=("${image_pkg}")
    apt_quiet install -y "${pkgs[@]}" || die "installing kernel headers failed"
  fi

  log "installing gasket-dkms (runs the DKMS postinst)"
  apt_quiet install -y gasket-dkms || die "installing gasket-dkms failed"

  log "checking dkms status"
  dkms status || true
  if ! dkms status | grep -q ': installed'; then
    die "gasket-dkms did not build/install a module (dkms status shows no 'installed')"
  fi

  built=0
  while IFS= read -r module; do
    log "module: ${module}"
    built=$((built + 1))
  done < <(find /lib/modules -name 'gasket.ko*' -o -name 'apex.ko*' 2>/dev/null)
  [[ "${built}" -ge 2 ]] ||
    die "expected gasket.ko and apex.ko under /lib/modules, found ${built}"
  log "DKMS modules present"
fi

# --------------------------------------------------- 5. negative key test ---
log "negative test: a foreign key must be rejected"
NEG="${WORK}/neg"
mkdir -p "${NEG}/gnupg" "${NEG}/lists/partial"
chmod 700 "${NEG}/gnupg"
GNUPGHOME="${NEG}/gnupg" gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-gen-key 'coral-edgetpu verification negative <neg@example.invalid>' rsa2048 sign 0 \
  >/dev/null 2>&1 || die "could not generate the throwaway key"
GNUPGHOME="${NEG}/gnupg" gpg --batch --export >"${NEG}/wrong.gpg"

cat >"${NEG}/sources.list" <<EOF
deb [signed-by=${NEG}/wrong.gpg] ${PAGES_URL} ${SUITE} main
EOF

set +e
as_root apt-get update \
  -o Dir::Etc::sourcelist="${NEG}/sources.list" \
  -o Dir::Etc::sourceparts="-" \
  -o Dir::State::lists="${NEG}/lists" \
  -o APT::Get::List-Cleanup="0" >"${NEG}/out.log" 2>&1
rc=$?
set -e

if [[ "${rc}" == "0" ]]; then
  cat "${NEG}/out.log" >&2
  die "apt update accepted a foreign key: the signature is not being enforced"
fi
log "foreign key rejected (apt exit ${rc}), as expected"

log "verification passed for ${SUITE}/${ARCH}"
