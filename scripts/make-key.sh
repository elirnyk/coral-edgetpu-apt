#!/usr/bin/env bash
# Generate the repository signing key (offline ceremony).
#
#   scripts/make-key.sh --out DIR [--passphrase-file FILE] [--update-config]
#
# Creates an RSA-4096 certify-only primary key plus an RSA-4096 signing subkey,
# and writes everything the project needs:
#
#   DIR/coral-edgetpu.gpg        binary public keyring (published, installed by users)
#   DIR/coral-edgetpu.asc        ASCII-armored public key
#   DIR/coral-edgetpu.gpg.sha256 checksum of the binary keyring
#   DIR/ci-signing.asc           encrypted secret *subkeys* only, for CI
#   DIR/revocation.asc           revocation certificate, keep offline
#   DIR/fingerprint.txt          primary fingerprint
#   DIR/keygrip.txt              signing subkey keygrip (for gpg-preset-passphrase)
#
# The primary secret key and the revocation certificate must never leave the
# offline machine. Only DIR/ci-signing.asc is uploaded to the `apt-signing`
# environment as the GPG_PRIVATE_KEY secret.
#
# By default the key is created in DIR/gnupg so the ceremony does not touch your
# normal keyring. Pass --gnupghome to use an existing one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT=""
PASSPHRASE_FILE=""
UPDATE_CONFIG=0
GNUPGHOME_OPT=""
UID_NAME="Coral Edge TPU APT (elirnyk)"
UID_EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --passphrase-file) PASSPHRASE_FILE="$2"; shift 2 ;;
    --gnupghome) GNUPGHOME_OPT="$2"; shift 2 ;;
    --name) UID_NAME="$2"; shift 2 ;;
    --email) UID_EMAIL="$2"; shift 2 ;;
    --update-config) UPDATE_CONFIG=1; shift ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo ":: error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf ':: %s\n' "$*" >&2; }
die() { printf ':: error: %s\n' "$*" >&2; exit 1; }

command -v gpg >/dev/null 2>&1 || die "gpg is required"

# Defaults from config/repo.yml.
if [[ -f "${ROOT}/scripts/lib/config.py" ]]; then
  maintainer="$(python3 "${ROOT}/scripts/lib/config.py" --get project.maintainer 2>/dev/null || true)"
  if [[ -n "${maintainer}" ]]; then
    # "elirnyk <edgetpumaint@gmail.com>"
    UID_EMAIL="${UID_EMAIL:-${maintainer##*<}}"
    UID_EMAIL="${UID_EMAIL%%>*}"
  fi
fi
UID_EMAIL="${UID_EMAIL:-edgetpumaint@gmail.com}"
KEY_UID="${UID_NAME} <${UID_EMAIL}>"

: "${OUT:?--out DIR is required}"
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
chmod 700 "${OUT}"

export GNUPGHOME="${GNUPGHOME_OPT:-${OUT}/gnupg}"
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"

# Passphrase handling: read from file, or from the environment, or prompt.
if [[ -n "${PASSPHRASE_FILE}" ]]; then
  [[ -f "${PASSPHRASE_FILE}" ]] || die "passphrase file not found: ${PASSPHRASE_FILE}"
  PASSPHRASE="$(cat "${PASSPHRASE_FILE}")"
elif [[ -n "${GPG_PASSPHRASE:-}" ]]; then
  PASSPHRASE="${GPG_PASSPHRASE}"
else
  read -r -s -p "Passphrase for the new key: " PASSPHRASE
  echo >&2
  read -r -s -p "Repeat passphrase: " PASSPHRASE2
  echo >&2
  [[ "${PASSPHRASE}" == "${PASSPHRASE2}" ]] || die "passphrases do not match"
fi
[[ -n "${PASSPHRASE}" ]] || die "empty passphrase is not allowed"

gpg_batch() {
  gpg --batch --yes --pinentry-mode loopback --passphrase "${PASSPHRASE}" "$@"
}

log "generating an RSA-4096 certify-only primary key"
gpg_batch --quick-gen-key "${KEY_UID}" rsa4096 cert 0
FINGERPRINT="$(gpg --batch --with-colons --list-keys "${UID_EMAIL}" |
  awk -F: '$1=="fpr"{print $10; exit}')"
[[ -n "${FINGERPRINT}" ]] || die "could not determine the new fingerprint"
log "primary fingerprint: ${FINGERPRINT}"

log "adding an RSA-4096 signing subkey"
gpg_batch --quick-add-key "${FINGERPRINT}" rsa4096 sign 0

log "exporting the public key"
gpg --batch --export "${FINGERPRINT}" >"${OUT}/coral-edgetpu.gpg"
gpg --batch --armor --export "${FINGERPRINT}" >"${OUT}/coral-edgetpu.asc"
(cd "${OUT}" && sha256sum coral-edgetpu.gpg >coral-edgetpu.gpg.sha256)

log "exporting the secret signing subkey for CI"
gpg_batch --armor --export-secret-subkeys "${FINGERPRINT}" >"${OUT}/ci-signing.asc"
chmod 600 "${OUT}/ci-signing.asc"

log "collecting the revocation certificate"
rev="${GNUPGHOME}/openpgp-revocs.d/${FINGERPRINT}.rev"
if [[ -f "${rev}" ]]; then
  cp "${rev}" "${OUT}/revocation.asc"
else
  # Older GnuPG builds do not write the file automatically.
  gpg_batch --command-fd 0 --output "${OUT}/revocation.asc" --gen-revoke "${FINGERPRINT}" </dev/null ||
    die "could not generate a revocation certificate"
fi
chmod 600 "${OUT}/revocation.asc"

printf '%s\n' "${FINGERPRINT}" >"${OUT}/fingerprint.txt"
KEYGRIP="$(gpg --batch --with-colons --with-keygrip --list-secret-keys "${FINGERPRINT}" |
  awk -F: '
    $1=="sec" { insecret=1 }
    $1=="ssb" { insecret=0 }
    $1=="grp" && insecret==0 { print $10; exit }
  ')"
if [[ -z "${KEYGRIP}" ]]; then
  # Older output orders the keygrip after the ssb line; take the last one.
  KEYGRIP="$(gpg --batch --with-colons --with-keygrip --list-secret-keys "${FINGERPRINT}" |
    awk -F: '$1=="grp"{grip=$10} END{print grip}')"
fi
[[ -n "${KEYGRIP}" ]] || die "could not determine the signing subkey keygrip"
printf '%s\n' "${KEYGRIP}" >"${OUT}/keygrip.txt"
log "signing subkey keygrip: ${KEYGRIP}"

if [[ "${UPDATE_CONFIG}" == "1" ]]; then
  log "updating fingerprint in config/repo.yml"
  python3 - "${ROOT}/config/repo.yml" "${FINGERPRINT}" <<'PY'
import re
import sys

path, fingerprint = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
new, count = re.subn(
    r"(?m)^(\s*fingerprint:\s*).*$", lambda m: m.group(1) + fingerprint, text, count=1
)
if count != 1:
    raise SystemExit(f"could not find the fingerprint key in {path}")
with open(path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(new)
print(f":: config/repo.yml fingerprint set to {fingerprint}")
PY
fi

cat >&2 <<EOF

:: done. Next steps:
   1. Keep ${OUT}/gnupg (primary secret key), ${OUT}/revocation.asc and
      ${OUT}/fingerprint.txt on offline media. Never commit them.
   2. Store the CI secret (encrypted signing subkey):
        gh secret set GPG_PRIVATE_KEY --env apt-signing < ${OUT}/ci-signing.asc
        gh secret set GPG_PASSPHRASE  --env apt-signing
   3. Record the keygrip ${KEYGRIP} if you preset the passphrase manually.
   4. Publish the public key by running a publish (it copies
      ${OUT}/coral-edgetpu.gpg content from the CI keyring export).
EOF
printf 'FINGERPRINT=%s\n' "${FINGERPRINT}"
