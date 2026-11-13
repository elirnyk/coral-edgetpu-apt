#!/usr/bin/env bash
# Build the gasket-dkms package for one suite.
#
# gasket-dkms is Architecture: all, so one build serves amd64, arm64 and armhf.
# The build runs in the suite image and finishes with a DKMS compile smoke test
# against that suite's real kernel headers.
#
# Environment:
#   COMPONENT        must be gasket
#   SUITE            APT suite (trixie, resolute, ...)
#   SHA              upstream commit to build
#   VERSION          suite-suffixed package version
#   IMAGE            suite container image
#   FALLBACK_IMAGE   optional image to retry with if IMAGE fails
#   HEADERS          kernel headers metapackage used by the smoke test
#   UPSTREAM_VERSION optional upstream changelog version (for provenance)
#   ARTIFACT_DIR     where to place .deb/.changes/build.json
#   WORKDIR          scratch directory
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(repo_root)"
load_config "${ROOT}"

COMPONENT="${COMPONENT:-gasket}"
require_env COMPONENT SUITE SHA VERSION
[[ "${COMPONENT}" == "gasket" ]] || die "COMPONENT must be gasket, got ${COMPONENT}"

IMAGE="${IMAGE:-$(cfg_get "suites.${SUITE}.image")}"
require_env IMAGE
FALLBACK_IMAGE="${FALLBACK_IMAGE:-$(cfg_get "suites.${SUITE}.fallback_image")}"
HEADERS="${HEADERS:-$(cfg_get "suites.${SUITE}.headers")}"
REF="${REF:-${UPSTREAM_GASKET_REF:-}}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT}/artifacts/${COMPONENT}-${SUITE}}"
WORKDIR="${WORKDIR:-${RUNNER_TEMP:-/tmp}/coral-${COMPONENT}-${SUITE}}"

log "${COMPONENT}: suite=${SUITE} sha=${SHA} version=${VERSION} headers=${HEADERS:-none}"

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/src" "${WORKDIR}/out" "${ARTIFACT_DIR}"

# 1. Pinned upstream checkout.
fetch_upstream "${UPSTREAM_GASKET_REPO}" "${SHA}" "${WORKDIR}/src" "${REF}" >/dev/null

# 2. Build-environment patches (ephemeral checkout only).
PATCHES="$(apply_buildenv_patches "${ROOT}" "${SUITE}" "${WORKDIR}/src")"

# 3. Pristine source tarball for the provenance release.
git -C "${WORKDIR}/src" archive --format=tar.gz \
  --prefix="${COMPONENT}-${SHA}/" \
  -o "${ARTIFACT_DIR}/sources-${COMPONENT}-${SHA}.tar.gz" HEAD

# 4. Build and smoke-test in a plain suite container, as root. The DKMS smoke
#    test always runs on amd64: the resulting package is Architecture: all, so
#    the module only has to compile once.
image_used="${IMAGE}"
pull_and_run() {
  local image="$1"
  docker pull -q "${image}"
  docker run --rm \
    -v "${WORKDIR}:/work" \
    -v "${ROOT}/ci:/ci:ro" \
    -e VERSION="${VERSION}" \
    -e SUITE="${SUITE}" \
    -e HEADERS_PACKAGE="${HEADERS}" \
    -w /work \
    --platform linux/amd64 \
    "${image}" \
    bash /ci/gasket-in-container.sh
}
if ! pull_and_run "${IMAGE}"; then
  if [[ -n "${FALLBACK_IMAGE}" ]]; then
    warn "build failed in ${IMAGE}; retrying with ${FALLBACK_IMAGE}"
    pull_and_run "${FALLBACK_IMAGE}"
    image_used="${FALLBACK_IMAGE}"
  else
    die "build failed in ${IMAGE} and no fallback image is configured"
  fi
fi
[[ "${image_used}" == "${IMAGE}" ]] || warn "built with fallback image ${image_used}"

# The container runs as root; hand the artifacts back to the runner user.
if command -v sudo >/dev/null 2>&1; then
  sudo chown -R "$(id -u):$(id -g)" "${WORKDIR}/out"
fi

# 5. Collect artifacts.
shopt -s nullglob
debs=("${WORKDIR}/out"/*.deb)
changes=("${WORKDIR}/out"/*.changes)
buildinfo=("${WORKDIR}/out"/*.buildinfo)
shopt -u nullglob
[[ "${#debs[@]}" -gt 0 ]] || die "no .deb files were produced"
cp "${debs[@]}" "${changes[@]}" "${buildinfo[@]}" "${ARTIFACT_DIR}/"

export COMPONENT SUITE VERSION SHA PATCHES REF
export ARCHES="all"
export IMAGE="${image_used}"
export UPSTREAM_VERSION="${UPSTREAM_VERSION:-}"
write_build_json "${ARTIFACT_DIR}/build.json"

log "artifacts in ${ARTIFACT_DIR}:"
ls -l "${ARTIFACT_DIR}"
