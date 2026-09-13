#!/usr/bin/env python3
"""Generate an SBOM/package and commit changelog for an image release."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True)


def package_map(data: dict) -> dict[str, str]:
    packages: dict[str, str] = {}
    for artifact in data.get("artifacts", []):
        if artifact.get("type") != "rpm":
            continue
        name = artifact.get("name")
        version = artifact.get("version")
        if name and version:
            packages[name] = version
    return packages


def image_info(image: str, tag: str) -> dict:
    return json.loads(run("skopeo", "inspect", f"docker://{image}:{tag}"))


def fetch_sbom(image: str, digest: str) -> dict:
    subject = f"{image}@{digest}"
    discovery = json.loads(run("oras", "discover", "--format", "json", subject))
    sbom_digest = next(
        (
            referrer["digest"]
            for referrer in discovery.get("referrers", [])
            if "spdx+json" in referrer.get("artifactType", "")
        ),
        None,
    )
    if not sbom_digest:
        raise RuntimeError(f"No SPDX SBOM is attached to {subject}")

    with tempfile.TemporaryDirectory() as temp_dir:
        subprocess.run(["oras", "pull", f"{image}@{sbom_digest}"], cwd=temp_dir, check=True)
        for filename in os.listdir(temp_dir):
            if filename.endswith(".json"):
                return json.loads((Path(temp_dir) / filename).read_text())
    raise RuntimeError(f"The SBOM artifact {sbom_digest} did not contain JSON")


def release_tags(image: str, channel: str) -> list[str]:
    raw = run("skopeo", "list-tags", f"docker://{image}")
    tags = json.loads(raw).get("Tags", [])
    if channel == "stable":
        pattern = re.compile(r"^\d+\.\d{8}(?:\.\d+)?$")
    else:
        pattern = re.compile(rf"^{re.escape(channel)}-\d+\.\d{{8}}(?:\.\d+)?$")
    return sorted((tag for tag in tags if pattern.fullmatch(tag)), key=version_key)


def version_key(tag: str) -> tuple[int, int, int]:
    numbers = [int(value) for value in re.findall(r"\d+", tag)]
    return tuple((numbers + [0, 0, 0])[:3])


def markdown_version(value: str | None) -> str:
    return value or "—"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, help="registry/repository without tag")
    parser.add_argument("--repository", required=True, help="GitHub owner/repository")
    parser.add_argument("--current", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--handwritten", default="")
    args = parser.parse_args()

    tags = release_tags(args.image, args.channel)
    current_index = tags.index(args.current) if args.current in tags else len(tags)
    previous = tags[current_index - 1] if current_index > 0 else None

    current_info = image_info(args.image, args.current)
    current_packages = package_map(fetch_sbom(args.image, current_info["Digest"]))
    previous_packages: dict[str, str] | None = None
    if previous:
        try:
            previous_packages = package_map(
                fetch_sbom(args.image, image_info(args.image, previous)["Digest"])
            )
        except RuntimeError as error:
            print(f"Warning: {error}")

    changes = []
    if previous_packages is not None:
        for name in sorted(set(current_packages) | set(previous_packages)):
            old = previous_packages.get(name)
            new = current_packages.get(name)
            if old != new:
                changes.append((name, old, new))

    previous_info = image_info(args.image, previous) if previous else {}
    start_revision = previous_info.get("Labels", {}).get("org.opencontainers.image.revision")
    end_revision = current_info.get("Labels", {}).get("org.opencontainers.image.revision")
    commits = (
        run("git", "log", "--format=%H%x09%s%x09%an", f"{start_revision}..{end_revision}").splitlines()
        if start_revision and end_revision
        else []
    )

    lines = [args.handwritten.strip() or f"This is an automatically generated changelog for release `{args.current}`.", ""]
    if previous:
        lines.append(f"From previous `{args.channel}` version `{previous}` there have been the following package changes.")
    else:
        lines.append("No previous release was found for this channel; package changes are shown against an empty baseline.")
    lines += ["", "### Package changes", "", "| Name | Previous | New |", "| --- | --- | --- |"]
    if previous and previous_packages is None:
        lines.append("| — | Previous release has no attached SBOM | Diff starts with the next release |")
    elif not changes:
        lines.append("| — | — | — |")
    else:
        lines += [f"| `{name}` | {markdown_version(old)} | {markdown_version(new)} |" for name, old, new in changes]

    lines += ["", "### Commits", "", "| Hash | Subject | Author |", "| --- | --- | --- |"]
    for commit in commits:
        commit_hash, subject, author = commit.split("\t", 2)
        lines.append(f"| [{commit_hash[:7]}](https://github.com/{args.repository}/commit/{commit_hash}) | {subject} | {author} |")
    if not commits:
        lines.append("| — | No commit range available | — |")

    lines += ["", "### How to switch", "", "For current users, switch to the channel image with:", "", "```bash", f"sudo bootc switch {args.image}:{args.channel}", "", "# Or switch to this exact image:", f"sudo bootc switch {args.image}:{args.current}", "```", ""]
    args.output.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
