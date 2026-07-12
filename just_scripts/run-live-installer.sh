#!/usr/bin/env bash

set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
cd "${project_root}"

image_tag="${IMAGE_TAG:-$(just generate-default-tag)}"
iso="${project_root}/output/aerocore-os-${image_tag}-amd64.iso"

if [[ ! -f "${iso}" ]]; then
  just build-live-installer
fi

podman run --rm --cap-add NET_ADMIN \
  --publish 127.0.0.1:8006:8006 \
  --env CPU_CORES=2 \
  --env RAM_SIZE=4G \
  --env DISK_SIZE=64G \
  --env BOOT_MODE=uefi \
  --device /dev/kvm \
  --volume "${iso}:/boot.iso:ro" \
  docker.io/qemux/qemu-docker
