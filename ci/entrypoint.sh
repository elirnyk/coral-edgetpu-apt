#!/usr/bin/env bash
# Container entrypoint for the libedgetpu build.
#
# The upstream Dockerfile expects to run as a user that matches the host, so
# that files written into the bind-mounted workspace keep usable ownership and
# so that Bazel does not run as root.
#
# Layout inside the container (see scripts/build-libedgetpu.sh):
#   /work       bind mount of the build scratch dir; /work/src is the checkout
#               and dpkg-buildpackage writes ../*.deb into /work
#   /work/out   collected artifacts
#   /cache      bind mount of the Bazel cache volume
#
# Environment:
#   HOST_UID, HOST_GID, HOST_USER   identity to adopt
# Usage: bash /ci/entrypoint.sh <script> [args...]
set -euo pipefail

: "${HOST_UID:?HOST_UID is required}"
: "${HOST_GID:?HOST_GID is required}"
: "${HOST_USER:?HOST_USER is required}"

mkdir -p /work/out /cache

# Output directories are created by Docker as root; the build user must be able
# to write into them.
for dir in /work /work/out /cache; do
  chmod a+rwx "${dir}"
done

if ! getent group "${HOST_GID}" >/dev/null; then
  groupadd --gid "${HOST_GID}" "${HOST_USER}"
fi
if ! getent passwd "${HOST_UID}" >/dev/null; then
  useradd -m -e '' -s /bin/bash --gid "${HOST_GID}" --uid "${HOST_UID}" "${HOST_USER}"
fi
echo "${HOST_USER} ALL=(ALL) NOPASSWD:ALL" >>/etc/sudoers

home="$(getent passwd "${HOST_UID}" | cut -d: -f6)"
install -d -o "${HOST_UID}" -g "${HOST_GID}" "${home}/.cache"
install -d -o "${HOST_UID}" -g "${HOST_GID}" /cache/bazel

# Bazel's output base is large; keep it on the mounted cache volume so Actions
# can reuse it between runs.
ln -sfn /cache/bazel "${home}/.cache/bazel"

# User-level bazelrc: applied after the workspace .bazelrc, so CI resource
# limits and the reusable caches win over the upstream defaults.
if [[ -f /ci/bazelrc ]]; then
  install -o "${HOST_UID}" -g "${HOST_GID}" -m 0644 /ci/bazelrc "${home}/.bazelrc"
fi

exec runuser -u "${HOST_USER}" -- \
  env HOME="${home}" USER="${HOST_USER}" LOGNAME="${HOST_USER}" \
  bash "$@"
