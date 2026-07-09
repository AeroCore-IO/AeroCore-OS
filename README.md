# AeroCore OS

A customized Bazzite-deck image tailored for living-room HTPCs, featuring China-localized updates and an integrated game accelerator.

AeroCore OS is built on top of the `ublue-os/image-template` ecosystem. Unlike a heavy fork of `ublue-os/bazzite`, AeroCore OS adopts a **layered architecture** that starts directly from a pre-built upstream Bazzite image:

```dockerfile
FROM ghcr.io/ublue-os/bazzite-deck:stable

```

By focusing strictly on file overlays and configuration writing, this build intentionally avoids invasive operations like `dnf5 install/remove`, COPR enablement, akmods pulls, or kernel recompilations. This architectural choice keeps AeroCore OS completely immune to Fedora/COPR dependency drift during major upstream transition windows (e.g., Bazzite 43 to 44).

---

## Key Features & Optimizations

* **Couch-Gaming Tailored:** Optimized settings for a seamless, out-of-the-box living-room console experience.
* **China-Localized Mirrors:** Pre-configured environment setups (e.g., `/etc/environment.d/99-aerocore-mirrors.conf`) utilizing low-latency, mainland China-hosted update streams.
* **Integrated Game Accelerator:** Embedded network booster configuration to ensure low-latency connection for Steam and local gaming services.
* **Maintainable Overlay Structure:** Structured `system_files/` directory for robust, long-term AeroCore core file injection without touching upstream packages.

## Local Build

To build AeroCore OS locally, edit `image-template.env` to match your target configurations and then run:

```bash
just build

```

To test a different upstream base image directly without modifying the environment files:

```bash
BASE_IMAGE=ghcr.io/ublue-os/bazzite-deck:testing just build

```
