# AeroCore OS

A customized Bazzite-deck image tailored for living-room HTPCs, featuring China-localized updates and an integrated game accelerator.

AeroCore OS is built on top of the `ublue-os/image-template` ecosystem. Unlike a heavy fork of `ublue-os/bazzite`, AeroCore OS adopts a **layered architecture** that starts directly from a pre-built upstream Bazzite image:

```dockerfile
FROM ghcr.io/ublue-os/bazzite-deck:stable

```

By focusing strictly on file overlays and configuration writing, this build intentionally avoids invasive operations like `dnf5 install/remove`, COPR enablement, akmods pulls, or kernel recompilations. This architectural choice keeps AeroCore OS completely immune to Fedora/COPR dependency drift during major upstream transition windows (e.g., Bazzite 43 to 44).

## AeroCore Booster integration

Image builds download the selected AeroCore Booster release from
`AeroCore-IO/booster-installer`, verify its published SHA-256 checksum, and
store the complete release seed under `/usr/share/aerocore-booster-release`.
The release installer runs once for the first active graphical user and copies
the application into that user's XDG directories. After bootstrapping, updates
and uninstallation remain owned by the normal Instruments user-space installer.
The bootstrap completion marker is stored at
`/var/lib/aerocore/instruments-bootstrap-complete`, so uninstalling the user
application does not cause the image seed to reinstall it on the next boot.
Remove that marker and enable `aerocore-instruments-setup.service` to explicitly
bootstrap the application again.

Set `INSTRUMENTS_VERSION` to a release tag for reproducible builds, or leave it
as `latest` for rolling development images. Set `INSTRUMENTS_ENABLED=false` to
build without Booster. The release repository and API base can be overridden
with `INSTRUMENTS_RELEASE_REPOSITORY` and `INSTRUMENTS_RELEASE_API_BASE`.

---

## Key Features & Optimizations

* **Couch-Gaming Tailored:** Optimized settings for a seamless, out-of-the-box living-room console experience.
* **China-Localized Mirrors:** Pre-configured environment setups (e.g., `/etc/environment.d/99-aerocore-mirrors.conf`) utilizing low-latency, mainland China-hosted update streams.
* **Integrated Game Accelerator:** Embedded network booster configuration to ensure low-latency connection for Steam and local gaming services.
* **Maintainable Overlay Structure:** Structured `system_files/` directory for robust, long-term AeroCore core file injection without touching upstream packages.

## Local Build

To build AeroCore OS locally, edit `image-template.env` to match your target configurations and then run:

```bash
sudo just build

```

To test a different upstream base image directly without modifying the environment files:

```bash
BASE_IMAGE=ghcr.io/ublue-os/bazzite-deck:testing just build

```

To build the Bazzite-style installer ISO locally, first build the AeroCore
image and then run:

```bash
sudo just build
just build-installer-iso
just run-installer-iso
```

This requires privileged Podman, a rootful Podman API socket, and roughly
70 GiB of free space. The installer ISO workflow consumes the published
`latest` AeroCore image and uploads the ISO as a GitHub Actions artifact.
