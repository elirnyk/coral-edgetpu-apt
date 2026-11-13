#!/usr/bin/env bash
# Import the CI signing subkey into a throwaway GnuPG home.
#
#   scripts/import-key.sh [--key FILE] [--passphrase-file FILE]
#
# Environment:
#   GPG_PRIVATE_KEY   armored secret subkeys (from scripts/make-key.sh)
#   GPG_PASSPHRASE    passphrase protecting the signing subkey
#   GNUPGHOME         target GnuPG home (default: a fresh directory under $RUNNER_TEMP)
#   FINGERPRINT       expected primary fingerprint (from config/repo.yml)
#
# Only the secret signing subkey is imported, so CI can sign Release/InRelease
# but cannot create identities, add subkeys or revoke the key. The passphrase is
# preset for the agent with gpg-preset-passphrase so reprepro (via gpgme) can
# sign without an interactive prompt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KEY_FILE=""
PASSPHRASE_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY_FILE="$2"; shift 2 ;;
    --passphrase-file) PASSPHRASE_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo ":: error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf ':: %s\n' "$*" >&2; }
die() { printf ':: error: %s\n' "$*" >&2; exit 1; }

command -v gpg >/dev/null 2>&1 || die "gpg is required"

if [[ -z "${GNUPGHOME:-}" ]]; then
  base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  GNUPGHOME="${base}/coral-edgetpu-gnupg"
fi
export GNUPGHOME
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"

# Resolve the armored key and the passphrase.
if [[ -n "${KEY_FILE}" ]]; then
  [[ -f "${KEY_FILE}" ]] || die "key file not found: ${KEY_FILE}"
elif [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then
  KEY_FILE="${GNUPGHOME}/ci-signing.asc"
  printf '%s\n' "${GPG_PRIVATE_KEY}" >"${KEY_FILE}"
  chmod 600 "${KEY_FILE}"
else
  die "no signing key: pass --key FILE or set GPG_PRIVATE_KEY"
fi

if [[ -n "${PASSPHRASE_FILE}" ]]; then
  [[ -f "${PASSPHRASE_FILE}" ]] || die "passphrase file not found: ${PASSPHRASE_FILE}"
  GPG_PASSPHRASE="$(cat "${PASSPHRASE_FILE}")"
fi
: "${GPG_PASSPHRASE:?GPG_PASSPHRASE is not set}"

# Default the expected fingerprint from config/repo.yml.
if [[ -z "${FINGERPRINT:-}" && -f "${ROOT}/scripts/lib/config.py" ]]; then
  FINGERPRINT="$(python3 "${ROOT}/scripts/lib/config.py" --get project.fingerprint 2>/dev/null || true)"
fi

log "importing the signing subkey"
gpg --batch --import "${KEY_FILE}" 2>&1 | sed 's/^/   /'

# gpgme (used by reprepro) needs the passphrase available to the agent. Preset it
# for every secret subkey so no pinentry is invoked during the signing step.
printf 'allow-preset-passphrase\n' >"${GNUPGHOME}/gpg-agent.conf"
gpgconf --kill gpg-agent >/dev/null 2>&1 || true
gpgconf --launch gpg-agent >/dev/null 2>&1 || true

preset="$(command -v gpg-preset-passphrase || true)"
if [[ -z "${preset}" ]]; then
  for candidate in /usr/lib/gnupg/gpg-preset-passphrase /usr/libexec/gpg-preset-passphrase; do
    [[ -x "${candidate}" ]] && preset="${candidate}" && break
  done
fi
[[ -n "${preset}" ]] || die "gpg-preset-passphrase not found"

grips="$(gpg --batch --with-colons --with-keygrip --list-secret-keys |
  awk -F: '$1=="grp"{print $10}')"
[[ -n "${grips}" ]] || die "no secret subkey keygrips found after import"

while IFS= read -r grip; do
  [[ -n "${grip}" ]] || continue
  printf '%s' "${GPG_PASSPHRASE}" | "${preset}" --preset "${grip}"
  log "preset passphrase for keygrip ${grip}"
done <<<"${grips}"

# Prove the key can sign without an interactive prompt.
probe_dir="$(mktemp -d)"
trap 'rm -rf "${probe_dir}"' EXIT
printf 'coral-edgetpu signing probe\n' >"${probe_dir}/data"
sign_args=(--batch --yes --armor --detach-sign)
[[ -n "${FINGERPRINT:-}" ]] && sign_args+=(--local-user "${FINGERPRINT}")
gpg "${sign_args[@]}" -o "${probe_dir}/data.asc" "${probe_dir}/data" ||
  die "the imported key could not sign (wrong passphrase or missing subkey)"
gpg --batch --verify "${probe_dir}/data.asc" "${probe_dir}/data" >/dev/null 2>&1 ||
  die "the signature produced by the imported key does not verify"
log "signing probe succeeded"

if [[ -n "${FINGERPRINT:-}" ]]; then
  gpg --batch --list-secret-keys "${FINGERPRINT}" >&2 || die "key ${FINGERPRINT} not present"
fi
log "GNUPGHOME=${GNUPGHOME} is ready"
