#!/usr/bin/env bash

set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
cd "${project_root}"

image_name="${IMAGE_NAME:-$(just image_name)}"
image_tag="${IMAGE_TAG:-$(just generate-default-tag)}"
base_image="${BASE_IMAGE:-ghcr.io/ublue-os/bazzite:stable}"
payload="localhost/${image_name}:live-payload"
output_dir="${project_root}/output"
api_socket="${PODMAN_SOCKET:-/run/podman/podman.sock}"
if [[ "${EUID}" -eq 0 ]]; then
  podman_cmd=(podman)
else
  podman_cmd=(sudo podman)
fi

if [[ ! -S "${api_socket}" ]]; then
  echo "Podman API socket not found: ${api_socket}" >&2
  echo "Set PODMAN_SOCKET to the rootful Podman socket and retry." >&2
  exit 1
fi

mkdir -p "${output_dir}"
"${podman_cmd[@]}" tag "${image_name}:${image_tag}" "${payload}"

"${podman_cmd[@]}" build \
  --cap-add sys_admin \
  --security-opt label=disable \
  --build-arg "BASE_IMAGE=${base_image}" \
  --build-arg "INSTALL_IMAGE_PAYLOAD=${payload}" \
  --tag localhost/aerocore-live-payload:latest \
  --file installer/Containerfile \
  .

"${podman_cmd[@]}" run --rm --privileged \
  --volume "${api_socket}:/var/run/docker.sock" \
  --volume "${project_root}/output:/build-container-installer/build" \
  --volume "${project_root}/installer/lorax_templates:/additional_lorax_templates:ro" \
  docker.io/jasonn3/build-container-installer:latest \
  ADDITIONAL_TEMPLATES="/additional_lorax_templates/remove_root_password_prompt.tmpl /additional_lorax_templates/set_default_user.tmpl" \
  ARCH="x86_64" \
  ENABLE_CACHE_DNF="false" \
  ENABLE_CACHE_SKOPEO="false" \
  ENABLE_FLATPAK_DEPENDENCIES="false" \
  IMAGE_NAME="aerocore-live-payload" \
  IMAGE_REPO="localhost" \
  IMAGE_TAG="latest" \
  ISO_NAME="build/aerocore-os-${image_tag}-amd64.iso" \
  VARIANT="Kinoite" \
  VERSION="${FEDORA_VERSION:-44}"

iso="${output_dir}/aerocore-os-${image_tag}-amd64.iso"
if [[ -f "${iso}" ]]; then
  sha256sum "${iso}" | tee "${iso}-CHECKSUM"
fi
