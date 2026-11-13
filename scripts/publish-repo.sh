#!/usr/bin/env bash
# Import build artifacts into the gh-pages reprepro repository, sign it and
# publish the public key, licences, manifest and index page.
#
#   scripts/publish-repo.sh [--repo-dir DIR] [--artifacts DIR]
#                           [--push] [--rebuild-db] [--dry-run]
#
# Environment:
#   GNUPGHOME   temporary GnuPG home containing the signing subkey (required
#               unless --dry-run without signing)
#   FINGERPRINT from config/repo.yml; must no longer be the placeholder
#
# The script only mutates the gh-pages checkout; pushing is opt-in so a dry run
# can inspect the result first.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(repo_root)"
load_config "${ROOT}"

REPO_DIR=""
ARTIFACTS=""
PUSH=0
REBUILD_DB=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --artifacts) ARTIFACTS="$2"; shift 2 ;;
    --push) PUSH=1; shift ;;
    --rebuild-db) REBUILD_DB=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

REPO_DIR="${REPO_DIR:-${ROOT}/repo}"
ARTIFACTS="${ARTIFACTS:-${ROOT}/artifacts}"
require_env PAGES_URL
require_real_fingerprint

[[ -d "${REPO_DIR}" ]] || die "gh-pages checkout not found at ${REPO_DIR}"
REPO_DIR="$(cd "${REPO_DIR}" && pwd)"
ARTIFACTS="$(cd "${ARTIFACTS}" && pwd)"

# ---------------------------------------------------------------- config ----
mkdir -p "${REPO_DIR}/conf" "${REPO_DIR}/meta" "${REPO_DIR}/licenses"
cp "${ROOT}/reprepro/conf/options" "${REPO_DIR}/conf/options"
python3 "${ROOT}/scripts/lib/config.py" --distributions >"${REPO_DIR}/conf/distributions"
: >"${REPO_DIR}/.nojekyll"

# ---------------------------------------------------------------- import ----
shopt -s nullglob
changes_files=("${ARTIFACTS}"/*/*.changes)
shopt -u nullglob

if [[ "${REBUILD_DB}" == "1" ]]; then
  log "rebuilding the reprepro database from the pool"
  shopt -s nullglob
  for deb in "${REPO_DIR}"/pool/main/*/*/*.deb; do
    version="$(dpkg-deb -f "${deb}" Version)"
    suite=""
    for candidate in ${SUITE_NAMES}; do
      case "${version}" in
        *"+${candidate}" | *"+${candidate}+"*) suite="${candidate}"; break ;;
      esac
    done
    [[ -n "${suite}" ]] || die "cannot derive the suite from ${deb} (version ${version})"
    reprepro -b "${REPO_DIR}" includedeb "${suite}" "${deb}"
  done
  shopt -u nullglob
fi

imported=0
skipped=0
for changes in "${changes_files[@]}"; do
  suite="$(awk -F': ' '/^Distribution:/{print $2; exit}' "${changes}")"
  [[ -n "${suite}" ]] || die "no Distribution field in ${changes}"
  python3 "${ROOT}/scripts/lib/verify_changes.py" "${changes}"

  # Publishing is idempotent: if every binary in the .changes is already present
  # with this version, skip it. reprepro refuses to include a version twice.
  version="$(awk -F': ' '/^Version:/{print $2; exit}' "${changes}")"
  binaries="$(awk -F': ' '/^Binary:/{print $2; exit}' "${changes}" | tr ',' ' ')"
  existing="$(reprepro -b "${REPO_DIR}" --list-format '${package}|${version}\n' list "${suite}" 2>/dev/null || true)"
  already=1
  for binary in ${binaries}; do
    if ! grep -qx "${binary}|${version}" <<<"${existing}"; then
      already=0
      break
    fi
  done
  if [[ "${already}" == "1" && -n "${version}" ]]; then
    log "$(basename "${changes}") is already published (${version}); skipping"
    skipped=$((skipped + 1))
    continue
  fi

  log "importing $(basename "${changes}") into ${suite}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    continue
  fi
  reprepro -b "${REPO_DIR}" include "${suite}" "${changes}"
  imported=$((imported + 1))
done

if [[ "${DRY_RUN}" == "1" ]]; then
  log "dry run: ${#changes_files[@]} changes file(s) validated, nothing imported"
  exit 0
fi

# ----------------------------------------------------------------- prune ----
bash "${ROOT}/scripts/prune-repo.sh" --repo "${REPO_DIR}" --keep "${KEEP_VERSIONS}"

# -------------------------------------------------------- export and sign ----
log "exporting and signing"
reprepro -b "${REPO_DIR}" export ${SUITE_NAMES}

# ------------------------------------------------------------------- key ----
log "writing the public key"
gpg --batch --yes --export "${FINGERPRINT}" >"${REPO_DIR}/${KEYRING_NAME}"
gpg --batch --yes --armor --export "${FINGERPRINT}" >"${REPO_DIR}/${KEYRING_ASC_NAME}"
(
  cd "${REPO_DIR}"
  sha256sum "${KEYRING_NAME}" >"${KEYRING_NAME}.sha256"
)

# --------------------------------------------------------------- licences ----
cp "${ROOT}"/licenses/*.txt "${REPO_DIR}/licenses/"
cp "${ROOT}/LICENSE" "${REPO_DIR}/licenses/MIT.txt"
cp "${ROOT}/NOTICE" "${REPO_DIR}/NOTICE"

# --------------------------------------------------------------- manifest ----
python3 "${ROOT}/scripts/lib/update_manifest.py" \
  --repo-dir "${REPO_DIR}" --artifacts "${ARTIFACTS}"

python3 "${ROOT}/scripts/lib/render_index.py" \
  --repo-dir "${REPO_DIR}" --output "${REPO_DIR}/index.html"

# --------------------------------------------------------------- sanity -----
for suite in ${SUITE_NAMES}; do
  [[ -f "${REPO_DIR}/dists/${suite}/InRelease" ]] ||
    die "missing dists/${suite}/InRelease after export (signing failed?)"
  [[ -f "${REPO_DIR}/dists/${suite}/Release.gpg" ]] ||
    die "missing dists/${suite}/Release.gpg after export"
done

# --------------------------------------------------------------- commit -----
maintainer_email="${REPO_MAINTAINER##*<}"
maintainer_email="${maintainer_email%%>*}"
git -C "${REPO_DIR}" add -A
if git -C "${REPO_DIR}" diff --cached --quiet; then
  log "nothing changed; the repository is already up to date"
else
  git -C "${REPO_DIR}" \
    -c user.name="${REPO_ORIGIN}" \
    -c user.email="${maintainer_email}" \
    commit -q -m "publish: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "committed $(git -C "${REPO_DIR}" rev-parse --short HEAD)"
fi

if [[ "${PUSH}" == "1" ]]; then
  log "pushing gh-pages"
  for attempt in 1 2 3; do
    if git -C "${REPO_DIR}" push origin HEAD:gh-pages; then
      log "pushed gh-pages"
      break
    fi
    if [[ "${attempt}" == "3" ]]; then
      die "could not push gh-pages after ${attempt} attempts"
    fi
    warn "push failed; rebasing on the remote and retrying"
    git -C "${REPO_DIR}" pull --rebase --autostash origin gh-pages
  done
fi

log "published: ${#changes_files[@]} changes file(s), ${imported} imported, ${skipped} already present"
