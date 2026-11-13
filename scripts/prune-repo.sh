#!/usr/bin/env bash
# Keep only the newest N versions of every package in every suite.
#
#   scripts/prune-repo.sh [--repo DIR] [--keep N] [--dry-run]
#
# Uses `reprepro removefilter` with a $Version condition, so exactly one version
# is dropped per call (reprepro's plain `remove` deletes every version of a
# package, which is not what retention wants).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT="$(repo_root)"
load_config "${ROOT}"

REPO_DIR=""
KEEP=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_DIR="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

REPO_DIR="${REPO_DIR:-${ROOT}/repo}"
KEEP="${KEEP:-${KEEP_VERSIONS}}"
[[ -d "${REPO_DIR}/db" ]] || die "no reprepro database in ${REPO_DIR} (is that a gh-pages checkout?)"

removed=0
for suite in ${SUITE_NAMES}; do
  if ! reprepro -b "${REPO_DIR}" list "${suite}" >/dev/null 2>&1; then
    log "suite ${suite} is not configured yet; skipping"
    continue
  fi

  candidates="$(
    reprepro -b "${REPO_DIR}" --list-format '${package}|${version}\n' list "${suite}" |
      sort -u |
      python3 "${ROOT}/scripts/lib/select_prunable.py" --keep "${KEEP}"
  )"

  if [[ -z "${candidates}" ]]; then
    log "suite ${suite}: nothing to prune (keeping ${KEEP} version(s) per package)"
    continue
  fi

  while IFS='|' read -r package version; do
    [[ -n "${package}" ]] || continue
    if [[ "${DRY_RUN}" == "1" ]]; then
      log "would remove ${suite}/${package} ${version}"
    else
      log "removing ${suite}/${package} ${version}"
      reprepro -b "${REPO_DIR}" removefilter "${suite}" \
        "\$Package (== ${package}), \$Version (== ${version})"
    fi
    removed=$((removed + 1))
  done <<<"${candidates}"
done

if [[ "${DRY_RUN}" == "1" ]]; then
  log "dry run: ${removed} version(s) would be removed"
  exit 0
fi

if [[ "${removed}" -gt 0 ]]; then
  reprepro -b "${REPO_DIR}" deleteunreferenced
  reprepro -b "${REPO_DIR}" export
  log "pruned ${removed} version(s)"
else
  log "nothing pruned"
fi
