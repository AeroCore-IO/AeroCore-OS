#!/usr/bin/env bash

set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
cd "${project_root}"

image_name="${IMAGE_NAME:-localhost/$(just image_name)}"
image_tag="${IMAGE_TAG:-$(just generate-default-tag)}"
live_base_image="${LIVE_BASE_IMAGE:-quay.io/fedora/fedora-kinoite:44}"
titanoboa_repository="${TITANOBOA_REPOSITORY:-https://github.com/Zeglius/titanoboa.git}"
titanoboa_revision="${TITANOBOA_REVISION:-7737f4748458252ac827dca14b3d6dd09298472a}"
source_image="${image_name}:${image_tag}"
# Keep the payload in local container storage, but use the public update
# reference as its local tag so Anaconda writes that reference as the boot
# origin instead of persisting the temporary localhost name. OSTREE_IMAGE_REF
# is intentionally tagless, matching the image-info contract.
image_basename="${image_name##*/}"
ostree_image_ref="${OSTREE_IMAGE_REF:-ostree-image-signed:docker://ghcr.io/${REPO_ORGANIZATION:-AeroCore-IO}/${image_basename}}"
install_image_ref="${ostree_image_ref#ostree-image-signed:docker://}"
install_image_ref="${install_image_ref#ostree-unverified-registry:docker://}"
install_image_ref="${install_image_ref#docker://}"
payload="${install_image_ref}:${image_tag}"
output_dir="${project_root}/output"
payload_archive="${output_dir}/install-payload.oci"
iso="${output_dir}/aerocore-os-${image_tag}-live-amd64.iso"
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
  --build-arg "INSTALL_IMAGE_TAG=${image_tag}" \
  --build-arg "OSTREE_IMAGE_REF=${ostree_image_ref}" \
  --tag "${payload}" \
  --file installer/Containerfile \
  .

if [[ "${EUID}" -eq 0 ]]; then
  rm -f "${iso}" "${checksum}"
else
  sudo rm -f "${iso}" "${checksum}"
fi

tmp_titanoboa="$(mktemp -d -t aerocore-titanoboa.XXXXXXXXXX)"
trap 'rm -rf "${tmp_titanoboa}"' EXIT

git clone --quiet --filter=blob:none --no-checkout \
  "${titanoboa_repository}" "${tmp_titanoboa}"
git -C "${tmp_titanoboa}" fetch --quiet origin "${titanoboa_revision}"
git -C "${tmp_titanoboa}" checkout --quiet "${titanoboa_revision}"

# Keep this invocation aligned with the pinned revision's GitHub Action.
# This revision exposes main.sh rather than a Justfile.
(
  cd "${tmp_titanoboa}"
  env \
    CI=1 \
    TITANOBOA_CTR_IMAGE="${payload}" \
    TITANOBOA_OUTPUT_DIR="${tmp_titanoboa}/output" \
    "${tmp_titanoboa}/main.sh"
)

titanoboa_iso="$(find "${tmp_titanoboa}/output" -maxdepth 1 -type f -name '*.iso' -print -quit)"
if [[ ! -f "${titanoboa_iso}" ]]; then
  echo "Titanoboa did not produce an ISO in ${tmp_titanoboa}/output" >&2
  exit 1
fi
if [[ "${EUID}" -eq 0 ]]; then
  rm -f "${iso}" "${checksum}"
  mv "${titanoboa_iso}" "${iso}"
else
  sudo rm -f "${iso}" "${checksum}"
  sudo mv "${titanoboa_iso}" "${iso}"
fi

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
