#!/usr/bin/env python3
"""Read config/repo.yml and expose it to the build, publish and prune scripts.

This is the only place that parses the configuration, so suites, architectures
and retention live in exactly one file.

Usage:
    config.py --shell              # KEY=value lines, suitable for `eval "$(...)"`
    config.py --distributions      # reprepro conf/distributions, to stdout
    config.py --suites-json        # JSON list of suite names
    config.py --arches <suite>     # space-separated architecture list
    config.py --get <dotted.path>  # single scalar value
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import sys

DEFAULT_CONFIG = os.path.join(os.path.dirname(__file__), "..", "..", "config", "repo.yml")


def _yaml():
    try:
        import yaml  # noqa: PLC0415
    except ImportError:  # pragma: no cover - CI convenience
        import subprocess  # noqa: PLC0415

        cmd = [sys.executable, "-m", "pip", "install", "--quiet", "--disable-pip-version-check"]
        if sys.version_info >= (3, 11):
            cmd.append("--break-system-packages")
        subprocess.check_call([*cmd, "pyyaml"])
        import yaml  # noqa: PLC0415

    return yaml


def load(path: str | None = None) -> dict:
    path = path or os.environ.get("REPO_CONFIG", DEFAULT_CONFIG)
    with open(path, encoding="utf-8") as fh:
        return _yaml().safe_load(fh)


def suites(cfg: dict) -> list[str]:
    return list(cfg.get("suites", {}))


def arches(cfg: dict, suite: str) -> list[str]:
    return list(cfg["suites"][suite].get("arches", []))


def render_distributions(cfg: dict) -> str:
    """Render reprepro's conf/distributions from the configuration."""
    project = cfg["project"]
    fingerprint = project["fingerprint"]
    blocks = []
    for name in suites(cfg):
        suite = cfg["suites"][name]
        arch_list = " ".join(suite.get("arches", []))
        description = f"{project['description']} - {suite['description']}"
        blocks.append(
            "\n".join(
                [
                    f"Origin: {project['origin']}",
                    f"Label: {project['label']}",
                    f"Codename: {name}",
                    f"Suite: {name}",
                    f"Architectures: {arch_list}",
                    "Components: main",
                    f"Description: {description}",
                    # NOTE: a leading "!" here means "run a hook script", not
                    # "use this key". Give the key id directly so libgpgme
                    # selects the signing subkey.
                    f"SignWith: {fingerprint}",
                    "DebIndices: Packages Release . .gz .xz",
                ]
            )
        )
    return "\n\n".join(blocks) + "\n"


def shell_env(cfg: dict) -> str:
    project = cfg["project"]
    lines = {
        "PROJECT_NAME": project["name"],
        "PROJECT_OWNER": project["owner"],
        "PROJECT_URL": project["url"],
        "PAGES_URL": project["pages_url"].rstrip("/"),
        "REPO_ORIGIN": project["origin"],
        "REPO_LABEL": project["label"],
        "REPO_DESCRIPTION": project["description"],
        "REPO_MAINTAINER": project["maintainer"],
        "KEYRING_NAME": project["keyring"],
        "KEYRING_ASC_NAME": project["keyring_asc"],
        "FINGERPRINT": project["fingerprint"],
        "KEEP_VERSIONS": str(cfg.get("retention", {}).get("keep_versions", 3)),
        "SUITE_NAMES": " ".join(suites(cfg)),
    }
    for name, upstream in cfg.get("upstreams", {}).items():
        prefix = "UPSTREAM_" + name.upper()
        lines[f"{prefix}_REPO"] = upstream["repo"]
        lines[f"{prefix}_REF"] = upstream["ref"]
        lines[f"{prefix}_SOURCE"] = upstream["source_package"]
    return "\n".join(f"{k}={shlex.quote(str(v))}" for k, v in lines.items()) + "\n"


def _get(cfg: dict, dotted: str):
    node = cfg
    for part in dotted.split("."):
        node = node[part]
    return node


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--shell", action="store_true")
    group.add_argument("--distributions", action="store_true")
    group.add_argument("--suites-json", action="store_true")
    group.add_argument("--arches", metavar="SUITE")
    group.add_argument("--get", metavar="PATH")
    parser.add_argument("--config", default=None)
    args = parser.parse_args(argv)

    cfg = load(args.config)

    if args.shell:
        sys.stdout.write(shell_env(cfg))
    elif args.distributions:
        sys.stdout.write(render_distributions(cfg))
    elif args.suites_json:
        json.dump(suites(cfg), sys.stdout)
        sys.stdout.write("\n")
    elif args.arches:
        sys.stdout.write(" ".join(arches(cfg, args.arches)) + "\n")
    elif args.get:
        value = _get(cfg, args.get)
        sys.stdout.write(("" if value is None else str(value)) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
