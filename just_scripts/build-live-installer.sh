#!/usr/bin/env bash

set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
cd "${project_root}"

image_name="${IMAGE_NAME:-localhost/$(just image_name)}"
image_tag="${IMAGE_TAG:-$(just generate-default-tag)}"
live_base_image="${LIVE_BASE_IMAGE:-quay.io/fedora/fedora-kinoite:43}"
installer_builder_image="${INSTALLER_BUILDER_IMAGE:-ghcr.io/jasonn3/build-container-installer:v1.5.0}"
source_image="${image_name}:${image_tag}"
payload="localhost/aerocore-live-payload:latest"
output_dir="${project_root}/output"
payload_archive="${output_dir}/install-payload.oci"
iso="${output_dir}/aerocore-os-${image_tag}-amd64.iso"
checksum="${iso}-CHECKSUM"
api_socket="${PODMAN_SOCKET:-/run/podman/podman.sock}"
if [[ "${EUID}" -eq 0 ]]; then
  podman_cmd=(podman)
  socket_test=(test -S "${api_socket}")
else
  podman_cmd=(sudo podman)
  socket_test=(sudo test -S "${api_socket}")
fi

if ! "${socket_test[@]}"; then
  echo "Podman API socket not found: ${api_socket}" >&2
  echo "Set PODMAN_SOCKET to the rootful Podman socket and retry." >&2
  exit 1
fi

ensure_rootful_image() {
  local root_image_id user_image_id user_name user_uid copy_tmp

  root_image_id="$("${podman_cmd[@]}" images \
    --filter "reference=${source_image}" \
    --format "{{.ID}}" | head -n1)"

  if [[ -n "${root_image_id}" ]]; then
    return 0
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    just _rootful_load_image "${image_name}" "${image_tag}"
    return
  fi

  if [[ -z "${SUDO_USER:-}" ]]; then
    return
  fi

  user_name="${SUDO_USER}"
  user_uid="$(id -u "${user_name}")"
  user_image_id="$(sudo -u "${user_name}" \
    env XDG_RUNTIME_DIR="/run/user/${user_uid}" \
    podman images \
      --filter "reference=${source_image}" \
      --format "{{.ID}}" | head -n1)"

  if [[ -z "${user_image_id}" ]]; then
    return
  fi

  copy_tmp="$(mktemp -p "${project_root}" -d -t _build_podman_scp.XXXXXXXXXX)"
  TMPDIR="${copy_tmp}" podman image scp \
    "${user_uid}@localhost::${source_image}" \
    "root@localhost::${source_image}"
  rm -rf "${copy_tmp}"
}

mkdir -p "${output_dir}"
ensure_rootful_image

"${podman_cmd[@]}" tag "${source_image}" "${payload}"
"${podman_cmd[@]}" save --format oci-archive --output "${payload_archive}" "${payload}"

"${podman_cmd[@]}" build \
  --cap-add sys_admin \
  --security-opt label=disable \
  --build-arg "BASE_IMAGE=${live_base_image}" \
  --build-arg "INSTALL_IMAGE_PAYLOAD=${payload}" \
  --build-arg "INSTALL_IMAGE_PAYLOAD_ARCHIVE=/install-payload.oci" \
  --tag "${payload}" \
  --file installer/Containerfile \
  .

if [[ "${EUID}" -eq 0 ]]; then
  rm -f "${iso}" "${checksum}"
else
  sudo rm -f "${iso}" "${checksum}"
fi

"${podman_cmd[@]}" run --rm --privileged \
  --volume "${api_socket}:/var/run/docker.sock" \
  --volume /var/lib/containers/storage:/var/lib/containers/storage \
  --volume "${project_root}/output:/build-container-installer/build" \
  --volume "${project_root}/installer/lorax_templates:/additional_lorax_templates:ro" \
  "${installer_builder_image}" \
  ADDITIONAL_TEMPLATES="/additional_lorax_templates/remove_root_password_prompt.tmpl /additional_lorax_templates/set_default_user.tmpl" \
  ARCH="x86_64" \
  ENABLE_CACHE_DNF="false" \
  ENABLE_CACHE_SKOPEO="false" \
  ENABLE_FLATPAK_DEPENDENCIES="false" \
  IMAGE_NAME="aerocore-live-payload" \
  IMAGE_REPO="localhost" \
  IMAGE_SRC="containers-storage:${payload}" \
  IMAGE_TAG="latest" \
  ISO_NAME="build/aerocore-os-${image_tag}-amd64.iso" \
  VARIANT="Kinoite" \
  VERSION="${FEDORA_VERSION:-44}"

if [[ -f "${iso}" ]]; then
  if [[ "${EUID}" -ne 0 ]]; then
    sudo chown "$(id -u):$(id -g)" "${iso}"
    sudo rm -f "${checksum}"
    (cd "${output_dir}" && sha256sum "$(basename "${iso}")") | sudo tee "${checksum}"
    sudo chown "$(id -u):$(id -g)" "${checksum}"
  else
    (cd "${output_dir}" && sha256sum "$(basename "${iso}")") | tee "${checksum}"
  fi
fi
