# Contributing

Thanks for helping. This repository is a **build and distribution** project: it packages two
upstream projects without modifying their source.

## Scope of contributions

Welcome:

- Fixes to workflows, scripts, reproducible-build setup, caching, and documentation.
- Improvements to verification (container tests, signature checks, provenance).
- New suite support when the kernel can run the modern gasket driver.
- Bug reports about packaging, signing, or installation.

Not accepted (send these upstream instead):

- Patches to `libedgetpu` or `gasket-driver` source or packaging files.
- Changes that add `[trusted=yes]` or otherwise weaken signature verification.
- Builds triggered from fork pull requests with access to signing secrets.

Upstream links:

- <https://github.com/feranick/libedgetpu>
- <https://github.com/erikpendragon/gasket-driver>

## Development workflow

1. Open an issue describing the change; pipeline changes benefit from a short design note.
2. Fork and create a branch.
3. Test locally where possible:
   ```sh
   scripts/verify-apt.sh --suite trixie --container
   ```
   CI runs the full build and verification; builds are expensive, so keep changes focused.
4. Open a pull request. Workflow changes run without signing secrets; maintainers run a full
   publish dry-run before merging.

## Commit style

Short imperative subject, body explaining the why. Reference issues with `Fixes #123`.

## Reporting problems

Include:

- Suite and version (`lsb_release -a`, `uname -r`, `apt-cache policy libedgetpu1-std`).
- The exact commands and full output.
- `dkms status` and the relevant `make.log` lines for driver issues.
- The repository URL and key fingerprint you are using.

Do not paste private keys, tokens, or personal data.
