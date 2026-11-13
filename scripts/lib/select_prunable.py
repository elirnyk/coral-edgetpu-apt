#!/usr/bin/env python3
"""Choose which package versions a suite should drop.

Reads ``<package>|<version>`` lines on stdin (one per line, as produced by
``reprepro --list-format '${package}|${version}\\n' list <suite>``), keeps the
newest ``--keep`` versions of every package and prints the rest as
``<package>|<version>`` lines.

Versions are ordered with Debian semantics via ``dpkg --compare-versions``, so
``~``, ``+`` and epoch handling match APT exactly.
"""
from __future__ import annotations

import argparse
import functools
import subprocess
import sys


def debian_compare(a: str, b: str) -> int:
    if subprocess.run(["dpkg", "--compare-versions", a, "lt", b], check=False).returncode == 0:
        return -1
    if subprocess.run(["dpkg", "--compare-versions", a, "gt", b], check=False).returncode == 0:
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep", type=int, required=True, help="versions to keep per package")
    args = parser.parse_args(argv)
    if args.keep < 1:
        parser.error("--keep must be at least 1")

    groups: dict[str, set[str]] = {}
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        package, _, version = line.partition("|")
        if not package or not version:
            continue
        groups.setdefault(package, set()).add(version)

    for package in sorted(groups):
        versions = sorted(groups[package], key=functools.cmp_to_key(debian_compare))
        # Newest last; drop everything older than the newest --keep.
        for version in versions[: max(0, len(versions) - args.keep)]:
            print(f"{package}|{version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
