#!/usr/bin/env python3
"""Render the small landing page published at the repository root.

The page is a convenience index, not part of what APT consumes: APT only needs
dists/, pool/ and the key. Keeping it generated from config/repo.yml and
meta/manifest.json means the published page can never drift from the suites and
versions that actually exist.

Usage: render_index.py --repo-dir DIR --output DIR/index.html
"""
from __future__ import annotations

import argparse
import html
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import config as repo_config  # noqa: E402

STYLE = """
:root { color-scheme: light dark; }
body { font-family: system-ui, sans-serif; line-height: 1.5; max-width: 52rem;
       margin: 2rem auto; padding: 0 1rem; }
code, pre { font-family: ui-monospace, monospace; }
pre { background: rgba(127,127,127,.15); padding: .75rem; overflow-x: auto;
      border-radius: .35rem; }
table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
th, td { border-bottom: 1px solid rgba(127,127,127,.35); padding: .4rem .6rem;
         text-align: left; }
.note { border-left: .25rem solid rgba(127,127,127,.5); padding-left: .75rem; }
"""


def latest_versions(manifest: dict) -> dict[tuple[str, str], str]:
    """Map (component, suite) to the newest recorded version."""
    latest: dict[tuple[str, str], tuple[str, str]] = {}
    for build in manifest.get("builds", []):
        key = (build.get("component", ""), build.get("suite", ""))
        stamp = build.get("date", "")
        if key not in latest or stamp >= latest[key][0]:
            latest[key] = (stamp, build.get("version", ""))
    return {key: value[1] for key, value in latest.items()}


def render(cfg: dict, manifest: dict) -> str:
    project = cfg["project"]
    url = project["pages_url"].rstrip("/")
    title = html.escape(project["label"])
    description = html.escape(project["description"])
    fingerprint = project["fingerprint"]
    versions = latest_versions(manifest)

    rows = []
    for suite in repo_config.suites(cfg):
        suite_cfg = cfg["suites"][suite]
        arches = " ".join(suite_cfg.get("arches", []))
        for component, component_cfg in cfg.get("components", {}).items():
            version = versions.get((component, suite), "not published yet")
            packages = ", ".join(component_cfg.get("packages", []))
            rows.append(
                "<tr>"
                f"<td><code>{html.escape(suite)}</code></td>"
                f"<td>{html.escape(suite_cfg.get('description', suite))}</td>"
                f"<td><code>{html.escape(arches)}</code></td>"
                f"<td>{html.escape(packages)}</td>"
                f"<td><code>{html.escape(version)}</code></td>"
                "</tr>"
            )

    upstream_rows = []
    for name, upstream in manifest.get("upstreams", {}).items():
        upstream_rows.append(
            "<tr>"
            f"<td>{html.escape(name)}</td>"
            f"<td><code>{html.escape(upstream.get('ref', ''))}</code></td>"
            f"<td><code>{html.escape((upstream.get('sha') or '')[:12])}</code></td>"
            f"<td><code>{html.escape(upstream.get('version', ''))}</code></td>"
            "</tr>"
        )

    suites = repo_config.suites(cfg)
    primary = suites[0] if suites else "trixie"
    source_block = "\n".join(
        [
            "Types: deb",
            f"URIs: {url}",
            f"Suites: {primary}",
            "Components: main",
            f"Architectures: {' '.join(cfg['suites'][primary].get('arches', []))}",
            f"Signed-By: /usr/share/keyrings/{project['keyring']}",
        ]
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>{STYLE}</style>
</head>
<body>
<h1>{title}</h1>
<p>{description}</p>

<p class="note"><strong>Unofficial.</strong> Not affiliated with, endorsed by, or supported by
Google, Coral, Debian, Ubuntu, or the upstream maintainers.</p>

<h2>Signing key</h2>
<p>Fingerprint: <code>{html.escape(fingerprint)}</code></p>
<p>
<a href="{project['keyring']}">{html.escape(project['keyring'])}</a> ·
<a href="{project['keyring_asc']}">{html.escape(project['keyring_asc'])}</a> ·
<a href="{project['keyring']}.sha256">{html.escape(project['keyring'])}.sha256</a>
</p>

<h2>Install</h2>
<pre>sudo install -d -m 0755 /usr/share/keyrings
curl -fsSL {url}/{project['keyring']} \\
  | sudo tee /usr/share/keyrings/{project['keyring']} &gt;/dev/null
sudo tee /etc/apt/sources.list.d/{project['origin']}.sources &gt;/dev/null &lt;&lt;'EOF'
{source_block}
EOF
sudo apt update
sudo apt install libedgetpu1-std
sudo apt install gasket-dkms   # PCIe/M.2 devices only</pre>

<h2>Suites and versions</h2>
<table>
<thead><tr><th>Suite</th><th>System</th><th>Architectures</th><th>Packages</th><th>Version</th></tr></thead>
<tbody>
{os.linesep.join(rows)}
</tbody>
</table>

<h2>Upstream</h2>
<table>
<thead><tr><th>Component</th><th>Branch</th><th>Commit</th><th>Upstream version</th></tr></thead>
<tbody>
{os.linesep.join(upstream_rows)}
</tbody>
</table>

<h2>Links</h2>
<ul>
<li><a href="{project['url']}">Source repository and build logs</a></li>
<li><a href="meta/manifest.json">meta/manifest.json</a> — build provenance</li>
<li><a href="licenses/Apache-2.0.txt">Apache-2.0</a> (libedgetpu) ·
    <a href="licenses/GPL-2.0.txt">GPL-2.0</a> (gasket-dkms)</li>
</ul>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-dir", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--config", default=None)
    args = parser.parse_args()

    cfg = repo_config.load(args.config)
    manifest_path = os.path.join(args.repo_dir, "meta", "manifest.json")
    manifest = {}
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as handle:
            manifest = json.load(handle)

    with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(render(cfg, manifest))
    print(f":: wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
