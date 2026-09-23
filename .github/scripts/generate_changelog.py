#!/usr/bin/env python3
"""Generate an SBOM/package and commit changelog for an image release."""

from __future__ import annotations

import argparse
import json
import os
import re
import urllib.error
import urllib.request
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


MAJOR_PACKAGES = {
    "kernel": "Kernel",
    "kernel-core": "Kernel",
    "kernel-modules": "Kernel",
    "kernel-modules-core": "Kernel",
    "kernel-modules-extra": "Kernel",
    "kernel-tools": "Kernel",
    "kernel-devel": "Kernel",
    "kernel-headers": "Kernel",
    "kernel-lts": "Kernel (Nvidia LTS)",
    "linux-firmware": "Firmware",
    "mesa-dri-drivers": "Mesa",
    "mesa-filesystem": "Mesa",
    "mesa-libEGL": "Mesa",
    "mesa-libGL": "Mesa",
    "mesa-libgbm": "Mesa",
    "mesa-va-drivers": "Mesa",
    "mesa-vulkan-drivers": "Mesa",
    "gamescope": "Gamescope",
    "gamescope-session": "Gamescope Session",
    "mangohud": "MangoHUD",
    "inputplumber": "InputPlumber",
    "opengamepadui": "OpenGamepadUI",
    "powerstation": "PowerStation",
    "steamos-manager": "SteamOS-Manager",
    "umu-launcher": "UMU Launcher",
    "bazaar": "Bazaar",
    "distrobox": "Distrobox",
    "gnome-shell": "Gnome",
    "plasma-desktop": "KDE",
    "waydroid": "Waydroid",
}


def major_package_rows(
    current_packages: dict[str, str],
    previous_packages: dict[str, str] | None,
) -> list[str]:
    selected: dict[str, tuple[str | None, str | None]] = {}
    for name, current in current_packages.items():
        display_name = MAJOR_PACKAGES.get(name)
        if not display_name:
            continue
        previous = (previous_packages or {}).get(name)
        selected[display_name] = (previous, current)

    rows = []
    for display_name, (old, new) in selected.items():
        version = markdown_version(new)
        if old and new and old != new:
            version = f"{old} ➡️ {new}"
        rows.append(f"| **{display_name}** | {version} |")
    return rows


def all_image_rows(changes: list[tuple[str, str | None, str | None]]) -> list[str]:
    rows = []
    for name, old, new in changes:
        icon = "➕" if old is None else "➖" if new is None else "🔄"
        rows.append(
            f"| {icon} | `{name}` | {markdown_version(old)} | {markdown_version(new)} |"
        )
    return rows


def upstream_release_commit(tag: str) -> str | None:
    try:
        request = urllib.request.Request(
            f"https://api.github.com/repos/ublue-os/bazzite/git/ref/tags/{tag}",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "AeroCore-OS-release-notes"},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.load(response)
        obj = data["object"]
        if obj.get("type") == "tag":
            request = urllib.request.Request(
                f"https://api.github.com/repos/ublue-os/bazzite/git/tags/{obj['sha']}",
                headers={"Accept": "application/vnd.github+json", "User-Agent": "AeroCore-OS-release-notes"},
            )
            with urllib.request.urlopen(request, timeout=30) as response:
                obj = json.load(response)["object"]
        return obj.get("sha")
    except (urllib.error.URLError, urllib.error.HTTPError, KeyError, json.JSONDecodeError):
        return None


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
    base_image = current_info.get("Labels", {}).get("org.opencontainers.image.base.name")
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
    previous_base = previous_info.get("Labels", {}).get("org.opencontainers.image.base.name", "")
    previous_base_tag = previous_base.rpartition(":")[2]
    current_base_tag = base_image.rpartition(":")[2] if base_image else ""
    start_revision = upstream_release_commit(previous_base_tag) if previous_base_tag else None
    end_revision = upstream_release_commit(current_base_tag) if current_base_tag else None
    upstream_commits = []
    if start_revision and end_revision and start_revision != end_revision:
        request = urllib.request.Request(
            f"https://api.github.com/repos/ublue-os/bazzite/compare/{start_revision}...{end_revision}",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "AeroCore-OS-release-notes"},
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            compare = json.load(response)
        upstream_commits = [
            (
                item["sha"],
                item["commit"]["message"].splitlines()[0],
                item["commit"]["author"].get("name", "Unknown"),
            )
            for item in compare.get("commits", [])
        ]

    start_revision = previous_info.get("Labels", {}).get("org.opencontainers.image.revision")
    end_revision = current_info.get("Labels", {}).get("org.opencontainers.image.revision")
    aerocore_commits = (
        [
            (item.split("\t", 2)[0], item.split("\t", 2)[1], item.split("\t", 2)[2])
            for item in run(
                "git", "log", "--format=%H%x09%s%x09%an", f"{start_revision}..{end_revision}"
            ).splitlines()
        ]
        if start_revision and end_revision and start_revision != end_revision
        else []
    )

    lines = [args.handwritten.strip() or f"This is an automatically generated changelog for release `{args.current}`.", ""]
    if base_image:
        base_name, _, base_tag = base_image.rpartition(":")
        if base_name and base_tag:
            base_repo = base_name.removeprefix("docker://")
            upstream_version = re.sub(r"^(?:stable|testing|testing-candidate)-", "", base_tag)
            lines.append(
                f"Based on upstream [{upstream_version}](https://github.com/ublue-os/bazzite/releases/tag/{base_tag}) "
                f"(`{base_repo}`)."
            )
        else:
            lines.append(f"Based on upstream image `{base_image}`.")
        lines.append("")
    if previous:
        lines.append(f"From previous `{args.channel}` version `{previous}` there have been the following changes. One package per new version shown.")
    else:
        lines.append("No previous release was found for this channel; changes are shown against an empty baseline.")

    lines += ["", "### Major packages", "", "| Name | Version |", "| --- | --- |"]
    major_rows = major_package_rows(current_packages, previous_packages)
    lines.extend(major_rows or ["| — | No major package changes |"])

    lines += ["", "### Commits", "", "| Hash | Subject | Author |", "| --- | --- | --- |"]
    if upstream_commits:
        lines.append("| | **Upstream Bazzite** | | |")
        for commit_hash, subject, author in upstream_commits:
            lines.append(f"| | **[{commit_hash[:7]}](https://github.com/ublue-os/bazzite/commit/{commit_hash})** | {subject} | {author} |")
    if aerocore_commits:
        lines.append("| | **AeroCore OS** | | |")
    for commit_hash, subject, author in aerocore_commits:
        lines.append(f"| | **[{commit_hash[:7]}](https://github.com/{args.repository}/commit/{commit_hash})** | {subject} | {author} |")
    if not upstream_commits and not aerocore_commits:
        lines.append("| — | No commit range available | — |")

    lines += ["", "### All Images", "", "| | Name | Previous | New |", "| --- | --- | --- | --- |"]
    if previous and previous_packages is None:
        lines.append("| — | Previous release has no attached SBOM | — | Diff starts with the next release |")
    elif not changes:
        lines.append("| — | No package changes | — | — |")
    else:
        lines.extend(all_image_rows(changes))

    lines += ["", "### How to switch", "", "For current users, switch to the channel image with:", "", "```bash", f"sudo bootc switch {args.image}:{args.channel}", "", "# Or switch to this exact image:", f"sudo bootc switch {args.image}:{args.current}", "```", ""]
    args.output.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
