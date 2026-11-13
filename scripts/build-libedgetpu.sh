#!/usr/bin/env bash
# Build libedgetpu packages for one suite and all of its architectures.
#
# Runs on the CI runner (not in a container): it builds upstream's Docker image
# from the pinned checkout, then runs the compile and the three
# dpkg-buildpackage passes inside it. See ci/libedgetpu-in-container.sh.
#
# Environment:
#   COMPONENT        must be libedgetpu
#   SUITE            APT suite (trixie, resolute, ...)
#   SHA              upstream commit to build
#   VERSION          suite-suffixed package version
#   IMAGE            suite container image (debian:trixie, ubuntu:26.04, ...)
#   FALLBACK_IMAGE   optional image to retry with if IMAGE fails
#   ARCHES           space-separated Debian architectures
#   UPSTREAM_VERSION optional upstream changelog version (for provenance)
#   ARTIFACT_DIR     where to place .deb/.changes/build.json (default artifacts/...)
#   WORKDIR          scratch directory (default under $RUNNER_TEMP)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(repo_root)"
load_config "${ROOT}"

COMPONENT="${COMPONENT:-libedgetpu}"
require_env COMPONENT SUITE SHA VERSION
[[ "${COMPONENT}" == "libedgetpu" ]] || die "COMPONENT must be libedgetpu, got ${COMPONENT}"

IMAGE="${IMAGE:-$(cfg_get "suites.${SUITE}.image")}"
require_env IMAGE
ARCHES="${ARCHES:-$(cfg_arches "${SUITE}")}"
FALLBACK_IMAGE="${FALLBACK_IMAGE:-$(cfg_get "suites.${SUITE}.fallback_image")}"
REF="${REF:-${UPSTREAM_LIBEDGETPU_REF:-}}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT}/artifacts/${COMPONENT}-${SUITE}}"
WORKDIR="${WORKDIR:-${RUNNER_TEMP:-/tmp}/coral-${COMPONENT}-${SUITE}}"
# Bazel's output base is large; allow the caller to point it at a path that is
# cached between runs.
CACHE_DIR="${CACHE_DIR:-${WORKDIR}/cache}"
tag="coral-edgetpu/${COMPONENT}:${SUITE}"

log "${COMPONENT}: suite=${SUITE} sha=${SHA} version=${VERSION} arches=${ARCHES}"

# upstream CPU names for the requested architectures
cpus=""
for arch in ${ARCHES}; do
  case "${arch}" in
    amd64) cpus="${cpus} k8" ;;
    arm64) cpus="${cpus} aarch64" ;;
    armhf) cpus="${cpus} armv7a" ;;
    *) die "unsupported architecture ${arch}" ;;
  esac
done
cpus="${cpus# }"

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/src" "${WORKDIR}/out" "${CACHE_DIR}" "${ARTIFACT_DIR}"

# 1. Pinned upstream checkout.
fetch_upstream "${UPSTREAM_LIBEDGETPU_REPO}" "${SHA}" "${WORKDIR}/src" "${REF}" >/dev/null

# 2. Build-environment patches (ephemeral checkout only).
PATCHES="$(apply_buildenv_patches "${ROOT}" "${SUITE}" "${WORKDIR}/src")"

# 3. Pristine source tarball for the provenance release. `git archive HEAD`
#    ignores the working-tree patches above, so this is exactly upstream.
git -C "${WORKDIR}/src" archive --format=tar.gz \
  --prefix="${COMPONENT}-${SHA}/" \
  -o "${ARTIFACT_DIR}/sources-${COMPONENT}-${SHA}.tar.gz" HEAD

# 4. Build the upstream cross image for this suite.
image_used="${IMAGE}"
if ! docker build --build-arg "IMAGE=${IMAGE}" -t "${tag}" "${WORKDIR}/src/docker"; then
  if [[ -n "${FALLBACK_IMAGE}" ]]; then
    warn "image build failed for ${IMAGE}; retrying with ${FALLBACK_IMAGE}"
    docker build --build-arg "IMAGE=${FALLBACK_IMAGE}" -t "${tag}" "${WORKDIR}/src/docker"
    image_used="${FALLBACK_IMAGE}"
  else
    die "image build failed for ${IMAGE} and no fallback image is configured"
  fi
fi
[[ "${image_used}" == "${IMAGE}" ]] || warn "built with fallback image ${image_used}"

# 5. Compile and package inside the container, as the runner user.
docker run --rm \
  -v "${WORKDIR}:/work" \
  -v "${CACHE_DIR}:/cache" \
  -v "${ROOT}/ci:/ci:ro" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -e HOST_USER="$(id -un)" \
  -e CPUS="${cpus}" \
  -e ARCHES="${ARCHES}" \
  -e VERSION="${VERSION}" \
  -e SUITE="${SUITE}" \
  -w /work \
  "${tag}" \
  bash /ci/entrypoint.sh /ci/libedgetpu-in-container.sh

# 6. Collect artifacts.
shopt -s nullglob
debs=("${WORKDIR}/out"/*.deb)
changes=("${WORKDIR}/out"/*.changes)
buildinfo=("${WORKDIR}/out"/*.buildinfo)
shopt -u nullglob
[[ "${#debs[@]}" -gt 0 ]] || die "no .deb files were produced"
cp "${debs[@]}" "${changes[@]}" "${buildinfo[@]}" "${ARTIFACT_DIR}/"

export COMPONENT SUITE VERSION SHA ARCHES PATCHES REF
export IMAGE="${image_used}"
export UPSTREAM_VERSION="${UPSTREAM_VERSION:-}"
write_build_json "${ARTIFACT_DIR}/build.json"

log "artifacts in ${ARTIFACT_DIR}:"
ls -l "${ARTIFACT_DIR}"
