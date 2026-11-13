# Signing and verification

## Key

| | |
|---|---|
| UID | `Coral Edge TPU APT (elirnyk) <edgetpumaint@gmail.com>` |
| Algorithm | RSA-4096 primary (certify only) + RSA-4096 signing subkey |
| Fingerprint | `22234DCCC8AAB3475B5F495CBB1DFCCA79E3A376` |
| Expiry | none; rotation and revocation documented below |
| Published | <https://elirnyk.github.io/coral-edgetpu-apt/coral-edgetpu.gpg> (binary keyring) |
| | <https://elirnyk.github.io/coral-edgetpu-apt/coral-edgetpu.asc> (ASCII armor) |
| | <https://elirnyk.github.io/coral-edgetpu-apt/coral-edgetpu.gpg.sha256> |

Only the **signing subkey** is present in CI. The primary key's secret material and the revocation
certificate are kept offline.

## How APT verifies this repository

1. `apt update` downloads `dists/<suite>/InRelease` (or `Release` + `Release.gpg`).
2. APT checks the OpenPGP signature against the keys in the `Signed-By` keyring.
3. APT stores the signed hashes from `Release` and verifies every `Packages` file and every `.deb`
   against them.

Package files themselves are not individually signed; the signed index is what protects them. That
is why the key must come from a trusted path and why `signed-by` must never be replaced with
`trusted=yes`.

## First-time verification

```sh
gpg --show-keys --with-fingerprint /usr/share/keyrings/coral-edgetpu.gpg
```

Compare the full fingerprint (not the short key ID) with `22234DCCC8AAB3475B5F495CBB1DFCCA79E3A376`. Compare it through a second
channel when possible (the repository's Git history, a signed release note, or the maintainer).

Verify the key file hash:

```sh
cd /tmp
curl -fsSLO https://elirnyk.github.io/coral-edgetpu-apt/coral-edgetpu.gpg
curl -fsSLO https://elirnyk.github.io/coral-edgetpu-apt/coral-edgetpu.gpg.sha256
sha256sum -c coral-edgetpu.gpg.sha256
```

## Manual metadata check

Without involving APT:

```sh
cd /tmp
curl -fsSLO https://elirnyk.github.io/coral-edgetpu-apt/dists/trixie/InRelease
gpgv --keyring /usr/share/keyrings/coral-edgetpu.gpg InRelease
```

Expected output ends with `Good signature`. For Ubuntu, replace `trixie` with `resolute`.

To confirm a package matches the signed index:

```sh
cd /tmp
apt-get download libedgetpu1-std
apt-cache show libedgetpu1-std | grep -E '^(Version|Filename|SHA256):'
sha256sum libedgetpu1-std_*.deb
```

`apt-get download` already verifies the file against the signed index and refuses a mismatch; the
manual comparison is useful when you want to see the hash explicitly.

## Negative test

APT must refuse a repository signed by another key. To confirm the `signed-by` wiring is effective:

```sh
gpg --export --armor some-other-key > /tmp/other.gpg
gpg --dearmor < /tmp/other.gpg > /tmp/other-keyring.gpg
# point a throwaway source at the repo with Signed-By: /tmp/other-keyring.gpg
# apt update must fail with NO_PUBKEY / "not signed"
```

The verification workflow runs an equivalent negative test after every publish.

## Threat model

The signature protects against:

- Tampering with `Packages` or `.deb` files on GitHub Pages, the CDN, or the network.
- A compromised Pages deployment that cannot produce a valid `InRelease`.

It does **not** protect against:

- A compromised signing key or CI environment.
- Malicious upstream code (packages are built from upstream sources by design).
- Compromise of the machine where you first install the key.

## Key rotation

Rotation is planned, not accidental. During an overlap window the repository is signed by both keys
and the keyring file contains both; clients update the keyring, then the old key is retired.

1. Generate a new primary + signing subkey offline; publish the revocation certificate of the old key
   only when retiring it.
2. Add the new public key to the published keyring (`coral-edgetpu.gpg`), keeping the old key.
3. Configure `reprepro` with both key fingerprints (`SignWith` accepts multiple values) and publish.
4. Announce the rotation with the new fingerprint in the README and `meta/manifest.json`.
5. After the overlap window, sign with the new key only and remove the old key from the keyring.
6. Update the CI secret to the new signing subkey and delete the old secret.

## Compromise response

If the signing subkey or CI secret is suspected to be compromised:

1. Revoke the signing subkey (the offline primary can sign the revocation).
2. Publish the revocation certificate and a newly signed `InRelease` as soon as possible.
3. Remove the compromised secret, rotate the `apt-signing` environment, and audit workflow runs.
4. Publish a pinned issue describing the window and the fingerprint users should trust.
5. Rebuild and re-sign the current package set from the archived sources.

The same procedure applies if the GitHub account or Pages deployment is compromised: the attacker
cannot produce valid metadata without the key, but they can serve stale or broken data.
