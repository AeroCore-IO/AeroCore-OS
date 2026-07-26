#!/usr/bin/env bash

set -euo pipefail

target_root=${1:?usage: configure-target-grub.sh TARGET_ROOT}

if [[ ! -d "${target_root}/etc" || ! -d "${target_root}/usr" ]]; then
  echo "Invalid target root: ${target_root}" >&2
  exit 1
fi

grub_defaults="${target_root}/etc/default/grub"
mkdir -p "$(dirname "${grub_defaults}")"

if [[ -f "${grub_defaults}" ]] && grep -q '^GRUB_TIMEOUT=' "${grub_defaults}"; then
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' "${grub_defaults}"
else
  printf 'GRUB_TIMEOUT=0\n' >> "${grub_defaults}"
fi

grub_editenv=""
for candidate in \
  "${target_root}/usr/bin/grub2-editenv" \
  "${target_root}/usr/sbin/grub2-editenv"; do
  if [[ -x "${candidate}" ]]; then
    grub_editenv="${candidate#"${target_root}"}"
    break
  fi
done

grub_mkconfig=""
for candidate in \
  "${target_root}/usr/bin/grub2-mkconfig" \
  "${target_root}/usr/sbin/grub2-mkconfig"; do
  if [[ -x "${candidate}" ]]; then
    grub_mkconfig="${candidate#"${target_root}"}"
    break
  fi
done

if [[ -z "${grub_editenv}" || -z "${grub_mkconfig}" ]]; then
  echo "The target image does not contain the required GRUB tools" >&2
  exit 1
fi

mounted_paths=()
cleanup() {
  local path
  for path in "${mounted_paths[@]}"; do
    umount -R "${path}" 2>/dev/null || true
  done
}
trap cleanup EXIT

bind_runtime_tree() {
  local source=$1
  local destination="${target_root}/${source#/}"

  mkdir -p "${destination}"
  if mountpoint -q "${destination}"; then
    return 0
  fi

  mount --rbind "${source}" "${destination}"
  mount --make-rslave "${destination}"
  mounted_paths+=("${destination}")
}

# grub2-mkconfig invokes grub-probe and needs the installer's device and EFI
# views while it runs inside the installed image.
bind_runtime_tree /dev
bind_runtime_tree /proc
bind_runtime_tree /sys

chroot "${target_root}" "${grub_editenv}" - set menu_auto_hide=1

if [[ -e "${target_root}/etc/grub2-efi.cfg" || -L "${target_root}/etc/grub2-efi.cfg" ]]; then
  grub_config=/etc/grub2-efi.cfg
elif [[ -e "${target_root}/etc/grub2.cfg" || -L "${target_root}/etc/grub2.cfg" ]]; then
  grub_config=/etc/grub2.cfg
elif [[ -d /sys/firmware/efi ]]; then
  grub_config=/etc/grub2-efi.cfg
else
  grub_config=/etc/grub2.cfg
fi

chroot "${target_root}" "${grub_mkconfig}" -o "${grub_config}"

echo "Configured target GRUB: GRUB_TIMEOUT=0, menu_auto_hide=1, ${grub_config}"
