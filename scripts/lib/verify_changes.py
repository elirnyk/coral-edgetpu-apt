#!/usr/bin/env python3
"""Verify that every file a .changes references matches its recorded SHA256.

APT trusts the signed index, and the index is built from these files, so a
mismatch between the .changes and the .deb on disk would publish a hash that
does not describe the artifact. reprepro checks this too; doing it first gives a
clearer failure and catches a truncated artifact download.

Usage: verify_changes.py <file.changes> [...]
"""
from __future__ import annotations

import hashlib
import os
import sys


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(changes: str) -> list[str]:
    directory = os.path.dirname(os.path.abspath(changes))
    with open(changes, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()

    problems: list[str] = []
    index = next((i for i, line in enumerate(lines) if line.startswith("Checksums-Sha256:")), None)
    if index is None:
        return [f"{changes}: no Checksums-Sha256 field"]

    for line in lines[index + 1 :]:
        if not line.strip():
            break
        # Checksum entries are indented; a non-indented line starts a new
        # field (e.g. "Files:") and ends this block.
        if not line.startswith((" ", "\\t")):
            break
        parts = line.split()
        if len(parts) < 3:
            continue
        expected, name = parts[0], parts[-1]
        path = os.path.join(directory, os.path.basename(name))
        if not os.path.exists(path):
            problems.append(f"{changes}: missing {name}")
            continue
        actual = sha256(path)
        if actual != expected:
            problems.append(f"{changes}: {name} sha256 {actual} != {expected}")
    return problems


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    problems: list[str] = []
    for changes in argv[1:]:
        problems.extend(verify(changes))
    if problems:
        for problem in problems:
            print(f":: error: {problem}", file=sys.stderr)
        return 1
    for changes in argv[1:]:
        print(f":: verified checksums in {os.path.basename(changes)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
