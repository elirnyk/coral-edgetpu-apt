#!/usr/bin/env python3
"""Merge per-build build.json files into the published meta/manifest.json.

The manifest is the ledger of what was built and from which upstream commit. It
is merged (never rewritten from scratch) so that publishing one component does
not erase the record of the other, and it keeps the full build history even
after old versions are pruned from the pool.

Usage: update_manifest.py --repo-dir DIR --artifacts DIR
"""
from __future__ import annotations

import argparse
import glob
import json
import os
from datetime import datetime, timezone

DEFAULT: dict = {"schema": 1, "updated": "", "upstreams": {}, "builds": []}


def load(path: str) -> dict:
    if not os.path.exists(path):
        return json.loads(json.dumps(DEFAULT))
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read().strip()
        if not text:
            return json.loads(json.dumps(DEFAULT))
        data = json.loads(text)
    except (OSError, json.JSONDecodeError):
        return json.loads(json.dumps(DEFAULT))
    for key, value in DEFAULT.items():
        data.setdefault(key, json.loads(json.dumps(value)))
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-dir", required=True)
    parser.add_argument("--artifacts", required=True)
    args = parser.parse_args()

    path = os.path.join(args.repo_dir, "meta", "manifest.json")
    manifest = load(path)

    builds = {
        (b.get("component"), b.get("suite"), b.get("version")): b
        for b in manifest.get("builds", [])
    }

    merged = 0
    for build_json in sorted(glob.glob(os.path.join(args.artifacts, "*", "build.json"))):
        with open(build_json, encoding="utf-8") as handle:
            data = json.load(handle)
        builds[(data["component"], data["suite"], data["version"])] = data
        merged += 1

        upstream = manifest["upstreams"].setdefault(data["component"], {})
        upstream["ref"] = data.get("ref", "")
        upstream["sha"] = data["sha"]
        upstream["version"] = data.get("upstream_version", "")
        upstream["date"] = data.get("date", "")

    manifest["builds"] = [
        builds[key] for key in sorted(builds, key=lambda k: tuple(part or "" for part in k))
    ]
    manifest["updated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")

    print(f":: manifest: merged {merged} build record(s), {len(builds)} total")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
