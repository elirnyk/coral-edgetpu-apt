#!/usr/bin/env python3
"""Resolve upstream commits and emit the build matrix.

Reads `config/repo.yml` and the published manifest (`meta/manifest.json` from
gh-pages), resolves the upstream default branches, and decides what needs to be
(re)built. The result is a JSON matrix consumed by `.github/workflows/build.yml`.

Only the `debian/changelog` metadata of the ephemeral checkout is rewritten at
build time (to add the suite and, when needed, a git or rebuild suffix); no
upstream source or packaging logic is modified.

Environment:
    REPO_CONFIG        path to config/repo.yml        (default config/repo.yml)
    MANIFEST           path to the published manifest (default state/manifest.json)
    GITHUB_TOKEN       token for the GitHub API
    GITHUB_OUTPUT      set by Actions; receives `matrix` and `count`
    DISPATCH_COMPONENT limit to one component (libedgetpu | gasket)
    DISPATCH_SHA       build this exact commit instead of the branch head
    DISPATCH_VERSION   use this upstream version instead of parsing the changelog
    DISPATCH_SUITES    comma-separated suite list
    DISPATCH_REBUILD   truthy: force a `+rebuildN` suffix
    DISPATCH_FORCE     truthy: build even when the commit is unchanged
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
import config as repo_config  # noqa: E402

CHANGELOG_FIRST_LINE = re.compile(r"^[^(\s]+ \(([^)]+)\)")
REBUILD_SUFFIX = re.compile(r"\+rebuild(\d+)$")
TRUTHY = {"1", "true", "yes", "on"}


def api(url: str, token: str | None) -> dict:
    request = urllib.request.Request(url)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("User-Agent", "coral-edgetpu-apt")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def fetch_text(url: str, token: str | None) -> str:
    request = urllib.request.Request(url)
    request.add_header("User-Agent", "coral-edgetpu-apt")
    if token and "api.github.com" in url:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8", "replace")


def resolve_commit(repo: str, ref: str, token: str | None) -> tuple[str, str]:
    """Return (sha, commit_date) for the tip of ref."""
    data = api(f"https://api.github.com/repos/{repo}/commits/{ref}", token)
    sha = data["sha"]
    date = data["commit"]["committer"]["date"]
    return sha, date


def changelog_version(repo: str, sha: str, token: str | None) -> str:
    text = fetch_text(
        f"https://raw.githubusercontent.com/{repo}/{sha}/debian/changelog", token
    )
    first = text.splitlines()[0]
    match = CHANGELOG_FIRST_LINE.match(first)
    if not match:
        raise SystemExit(f"cannot parse version from {repo}@{sha[:8]} debian/changelog")
    return match.group(1)


def load_manifest(path: str) -> dict:
    if not os.path.exists(path):
        return {"schema": 1, "builds": [], "upstreams": {}}
    with open(path, encoding="utf-8") as fh:
        text = fh.read().strip()
    if not text:
        return {"schema": 1, "builds": [], "upstreams": {}}
    return json.loads(text)


def bump_rebuild(version: str, existing: set[str]) -> str:
    match = REBUILD_SUFFIX.search(version)
    base = version[: match.start()] if match else version
    highest = 0
    for candidate in existing:
        candidate_match = REBUILD_SUFFIX.search(candidate)
        if candidate == base:
            highest = max(highest, 0)
        elif candidate_match and candidate[: candidate_match.start()] == base:
            highest = max(highest, int(candidate_match.group(1)))
    return f"{base}+rebuild{highest + 1}"


def main() -> int:
    cfg = repo_config.load()
    manifest = load_manifest(os.environ.get("MANIFEST", "state/manifest.json"))
    token = os.environ.get("GITHUB_TOKEN") or None

    builds = manifest.get("builds", [])
    published_versions = {b["version"] for b in builds}

    want_component = os.environ.get("DISPATCH_COMPONENT", "").strip()
    want_sha = os.environ.get("DISPATCH_SHA", "").strip()
    want_version = os.environ.get("DISPATCH_VERSION", "").strip()
    # A final version computed elsewhere (the orchestrator already applied the
    # suite suffix and any rebuild bump); used verbatim for every suite.
    want_final = os.environ.get("DISPATCH_FINAL_VERSION", "").strip()
    want_suites = [s.strip() for s in os.environ.get("DISPATCH_SUITES", "").split(",") if s.strip()]
    want_rebuild = os.environ.get("DISPATCH_REBUILD", "").lower() in TRUTHY
    force = os.environ.get("DISPATCH_FORCE", "").lower() in TRUTHY
    # Optional per-run overrides for the container image and headers package.
    image_override = os.environ.get("DISPATCH_IMAGE", "").strip()
    fallback_override = os.environ.get("DISPATCH_FALLBACK_IMAGE", "").strip()
    headers_override = os.environ.get("DISPATCH_HEADERS", "").strip()
    arches_override = [a for a in os.environ.get("DISPATCH_ARCHES", "").split() if a]

    all_suites = repo_config.suites(cfg)
    if want_suites:
        unknown = [s for s in want_suites if s not in all_suites]
        if unknown:
            raise SystemExit(f"unknown suite(s): {', '.join(unknown)}")
        target_suites = want_suites
    else:
        target_suites = all_suites

    matrix: list[dict] = []
    summary: list[str] = []

    for component, upstream in cfg["upstreams"].items():
        if want_component and component != want_component:
            continue

        repo = upstream["repo"]
        ref = upstream["ref"]
        previous = manifest.get("upstreams", {}).get(component, {})

        if upstream.get("hold"):
            sha, commit_date = upstream["hold"], previous.get("date", "")
        elif want_sha:
            sha, commit_date = want_sha, ""
        else:
            sha, commit_date = resolve_commit(repo, ref, token)

        if not commit_date:
            try:
                commit_date = api(f"https://api.github.com/repos/{repo}/commits/{sha}", token)[
                    "commit"
                ]["committer"]["date"]
            except urllib.error.HTTPError:
                commit_date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        upstream_ver = want_version or changelog_version(repo, sha, token)
        git_suffix = bool(previous) and previous.get("version") == upstream_ver and previous.get(
            "sha"
        ) != sha
        if git_suffix:
            stamp = commit_date[:10].replace("-", "")
            git_suffix_text = f"+git{stamp}.{sha[:7]}"
        else:
            git_suffix_text = ""

        built_suites = {b["suite"] for b in builds if b["component"] == component and b["sha"] == sha}
        unchanged = previous.get("sha") == sha

        for suite in target_suites:
            if (
                unchanged
                and suite in built_suites
                and not force
                and not want_rebuild
                and not want_final
            ):
                continue

            if want_final:
                version = want_final
                needs_rebuild = True
            else:
                version = f"{upstream_ver}+{suite}{git_suffix_text}"
                needs_rebuild = want_rebuild or version in published_versions
                if needs_rebuild:
                    version = bump_rebuild(version, published_versions)
                published_versions.add(version)

            suite_cfg = cfg["suites"][suite]
            entry_arches = arches_override or list(suite_cfg.get("arches", []))
            entry = {
                "component": component,
                "repo": repo,
                "ref": ref,
                "sha": sha,
                "upstream_version": upstream_ver,
                "version": version,
                "suite": suite,
                "family": suite_cfg["family"],
                "image": image_override or suite_cfg["image"],
                "fallback_image": fallback_override or suite_cfg.get("fallback_image", ""),
                "headers": headers_override or suite_cfg.get("headers", ""),
                "arches": entry_arches,
                "arches_str": " ".join(entry_arches),
                "git_suffix": bool(git_suffix_text),
                "rebuild": needs_rebuild,
            }
            matrix.append(entry)
            summary.append(f"{component} {suite} {version} ({sha[:8]})")

    payload = json.dumps(matrix, separators=(",", ":"))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
            out.write(f"matrix={payload}\n")
            out.write(f"count={len(matrix)}\n")
    else:
        print(json.dumps({"matrix": matrix, "count": len(matrix)}, indent=2))

    if summary:
        print("Build plan:", file=sys.stderr)
        for line in summary:
            print(f"  {line}", file=sys.stderr)
    else:
        print("Nothing to build: upstream is unchanged.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
