#!/usr/bin/env bash
# Shared helpers for the repository scripts.
#
# All scripts are expected to run under `set -euo pipefail`.

log() { printf ':: %s\n' "$*" >&2; }
warn() { printf ':: warning: %s\n' "$*" >&2; }
die() {
  printf ':: error: %s\n' "$*" >&2
  exit 1
}

# Print the repository root (the directory containing scripts/).
repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

# Emit `KEY=value` lines from config/repo.yml and export them.
load_config() {
  REPO_ROOT="${1:-$(repo_root)}"
  local out
  out="$(python3 "${REPO_ROOT}/scripts/lib/config.py" --shell)"
  # allexport so every KEY=value from config.py (including the upstream
  # coordinates) is exported without maintaining a second list here.
  set -a
  eval "${out}"
  set +a
}

# Read a single value from config/repo.yml, e.g. cfg_get suites.trixie.image.
cfg_get() {
  python3 "${REPO_ROOT}/scripts/lib/config.py" --get "$1"
}

# Space-separated architecture list for a suite.
cfg_arches() {
  python3 "${REPO_ROOT}/scripts/lib/config.py" --arches "$1"
}

require_env() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      die "required environment variable ${name} is not set"
    fi
  done
}

require_real_fingerprint() {
  if [[ "${FINGERPRINT}" == "FINGERPRINT" || -z "${FINGERPRINT}" ]]; then
    die "config/repo.yml still has the placeholder fingerprint; run scripts/make-key.sh first"
  fi
}

# Write a key=value line to $GITHUB_OUTPUT when running in Actions.
set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT}"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

# Clone an upstream repository and check out an exact commit.
#
#   fetch_upstream <owner/repo> <sha> <dest> [ref]
#
# The checkout is pinned to <sha>; <ref> is only a clone hint so the common case
# is a single-branch clone.
fetch_upstream() {
  local repo="$1" sha="$2" dest="$3" ref="${4:-}"
  rm -rf "${dest}"
  if [[ -n "${ref}" ]] && git clone -q --branch "${ref}" --single-branch \
    "https://github.com/${repo}.git" "${dest}"; then
    :
  else
    git clone -q "https://github.com/${repo}.git" "${dest}"
  fi
  if ! git -C "${dest}" checkout -q --detach "${sha}" 2>/dev/null; then
    git -C "${dest}" fetch -q origin "${sha}"
    git -C "${dest}" checkout -q --detach FETCH_HEAD
  fi
  local got
  got="$(git -C "${dest}" rev-parse HEAD)"
  [[ "${got}" == "${sha}" ]] || die "checked out ${got}, expected ${sha}"
  printf '%s\n' "${got}"
}

# Apply the buildenv patches that match a suite, in lexical order.
#
#   apply_buildenv_patches <root> <suite> <dest>
# Prints the applied patch file names, one per line.
apply_buildenv_patches() {
  local root="$1" suite="$2" dest="$3" patch
  shopt -s nullglob
  for patch in "${root}"/buildenv/"${suite}"-*.patch; do
    log "applying build environment patch $(basename "${patch}")"
    git -C "${dest}" apply --verbose "${patch}"
    basename "${patch}"
  done
  shopt -u nullglob
}

# Print the Debian source version from an upstream debian/changelog.
#
#   upstream_version <source-dir>
upstream_version() {
  dpkg-parsechangelog -l "$1/debian/changelog" -SVersion
}

# Print the Debian source package name from debian/changelog.
#
#   changelog_package <source-dir>
changelog_package() {
  dpkg-parsechangelog -l "$1/debian/changelog" -SSource
}

# Prepend a changelog entry for a suite-suffixed version.
#
# This rewrites only debian/changelog metadata in the ephemeral build checkout;
# no upstream source or packaging logic is modified. The generated entry is the
# change notice required by the upstream licences.
#
#   prepend_changelog_entry <source-dir> <version> <suite>
prepend_changelog_entry() {
  local src="$1" version="$2" suite="$3"
  local package
  package="$(changelog_package "${src}")"
  python3 - "${src}/debian/changelog" "${package}" "${version}" "${suite}" <<'PY'
import email.utils
import sys

path, package, version, suite = sys.argv[1:5]
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
PY
  log "changelog entry added: ${package} (${version}) ${suite}"
}

# Record build provenance next to the artifacts.
#
#   write_build_json <path>
#
# Reads the fields from the environment, so callers do not have to thread a long
# positional list:
#   COMPONENT SUITE VERSION SHA IMAGE ARCHES PATCHES
#   REF (optional) UPSTREAM_VERSION (optional)
write_build_json() {
  local path="$1"
  python3 - "$path" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path = sys.argv[1]
data = {
    "component": os.environ["COMPONENT"],
    "suite": os.environ["SUITE"],
    "version": os.environ["VERSION"],
    "upstream_version": os.environ.get("UPSTREAM_VERSION", ""),
    "ref": os.environ.get("REF", ""),
    "sha": os.environ["SHA"],
    "image": os.environ.get("IMAGE", ""),
    "arches": os.environ.get("ARCHES", "").split(),
    "patches": [p for p in os.environ.get("PATCHES", "").splitlines() if p],
    "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(f":: wrote {path}")
PY
}
