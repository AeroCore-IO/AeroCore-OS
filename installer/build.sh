#!/usr/bin/env bash

set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE=${BASE_IMAGE:?}
INSTALL_IMAGE_PAYLOAD=${INSTALL_IMAGE_PAYLOAD:?}
INSTALL_IMAGE_PAYLOAD_ARCHIVE=${INSTALL_IMAGE_PAYLOAD_ARCHIVE:-}

# The installer is a live KDE environment.  Keep the installed system payload
# separate: it is the AeroCore image, while BASE_IMAGE provides the live UI.
# Bazzite excludes some base packages from normal transactions. The live
# installer needs Anaconda's exact NetworkManager dependencies, so clear the
# excludes only for this dependency install.
dnf --setopt=excludepkgs= install -y \
  anaconda-live \
  libblockdev-btrfs \
  libblockdev-dm \
  libblockdev-lvm \
  dracut-live \
  livesys-scripts \
  grub2-efi-x64 \
  grub2-efi-x64-cdboot

# Kinoite can carry the EFI packages in the RPM database without their files
# materialized in the container filesystem. Restore the files for the ISO.
dnf --setopt=excludepkgs= reinstall -y \
  grub2-efi-x64 \
  grub2-efi-x64-cdboot

# Apply the same AeroCore overlay to the live session where possible.
if [[ -d /src/system_files ]]; then
  cp -a /src/system_files/. /
fi

BRANDING_DIR="${SCRIPT_DIR}/branding"
if [[ -d "${BRANDING_DIR}" ]]; then
  mkdir -p /usr/share/anaconda/pixmaps
  cp -a "${BRANDING_DIR}/." /usr/share/anaconda/pixmaps/
fi

# Installer-only overrides, kept separate from the installed AeroCore payload.
if [[ -d "${SCRIPT_DIR}/system_files/overrides" ]]; then
  cp -a "${SCRIPT_DIR}/system_files/overrides/." /
fi

# Plasma's live-session launcher defaults to start-here, and Fedora keeps
# LOGO=fedora-logo-icon in the base live environment.
for size in 16x16 22x22 24x24 32x32 36x36 48x48 64x64 96x96 128x128 256x256; do
  icon_dir="/usr/share/icons/hicolor/${size}"
  if [[ -f "${icon_dir}/bazzite-logo-icon.png" ]]; then
    mkdir -p "${icon_dir}/apps" "${icon_dir}/places"
    cp -f "${icon_dir}/bazzite-logo-icon.png" "${icon_dir}/apps/fedora-logo-icon.png"
    cp -f "${icon_dir}/bazzite-logo-icon.png" "${icon_dir}/places/start-here.png"
  fi
done

if [[ -f /usr/share/icons/hicolor/scalable/places/distributor-logo.svg ]]; then
  mkdir -p /usr/share/icons/hicolor/scalable/apps /usr/share/icons/hicolor/scalable/places
  cp -f /usr/share/icons/hicolor/scalable/places/distributor-logo.svg \
    /usr/share/icons/hicolor/scalable/apps/start-here.svg
  cp -f /usr/share/icons/hicolor/scalable/places/distributor-logo.svg \
    /usr/share/icons/hicolor/scalable/places/start-here.svg
fi

sed -i 's/^LOGO=.*/LOGO=distributor-logo/' /usr/lib/os-release

for desktop_file in \
  /usr/share/applications/liveinst.desktop \
  /usr/share/applications/org.fedoraproject.AnacondaInstaller.desktop \
  /usr/share/applications/anaconda.desktop; do
  if [[ -f "${desktop_file}" ]]; then
    sed -i 's/^Icon=.*/Icon=org.fedoraproject.AnacondaInstaller/' "${desktop_file}"
  fi
done

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor || true
fi

# Make the install payload available to Anaconda.
if [[ -n "${INSTALL_IMAGE_PAYLOAD_ARCHIVE}" && -f "${INSTALL_IMAGE_PAYLOAD_ARCHIVE}" ]]; then
  podman load --storage-opt additionalimagestore='' < "${INSTALL_IMAGE_PAYLOAD_ARCHIVE}"
elif mountpoint -q /usr/lib/containers/storage; then
  podman save --format oci-archive "${INSTALL_IMAGE_PAYLOAD}" | \
    podman load --storage-opt additionalimagestore=''
else
  podman pull "${INSTALL_IMAGE_PAYLOAD}"
fi

# Tell Anaconda to install the bootc container that was loaded above.
mkdir -p /var/lib/rpm-state
cat >> /usr/share/anaconda/interactive-defaults.ks <<EOF
ostreecontainer --url=${INSTALL_IMAGE_PAYLOAD} --transport=containers-storage --no-signature-verification
EOF

mkdir -p /usr/lib/bootc-image-builder
cp "${SCRIPT_DIR}/iso.yaml" /usr/lib/bootc-image-builder/iso.yaml

kernel="$(kernel-install list --json pretty | jq -r \
  '.[] | select(.has_kernel == true) | .version' | head -n1)"
if [[ -n "${kernel}" && -d "/usr/lib/modules/${kernel}" ]]; then
  DRACUT_NO_XATTR=1 dracut -v --force --zstd --reproducible --no-hostonly \
    --add "dmsquash-live dmsquash-live-autooverlay" \
    "/usr/lib/modules/${kernel}/initramfs.img" "${kernel}"
fi

sed -i 's/^livesys_session=.*/livesys_session=kde/' /etc/sysconfig/livesys
systemctl enable livesys.service livesys-late.service

mkdir -p /boot/efi
efi_dir="$(find /usr/lib/efi -type d -name EFI -print -quit 2>/dev/null || true)"
if [[ -n "${efi_dir}" ]]; then
  cp -a "${efi_dir}" /boot/efi/
fi

# bootc-image-builder needs the Fedora live ISO fallback EFI loader.
grubx64="$(find /usr/lib/efi /boot/efi -type f \
  -path '*/EFI/fedora/grubx64.efi' -print -quit 2>/dev/null || true)"
if [[ -z "${grubx64}" ]]; then
  echo "grubx64.efi was not found in the installed EFI tree" >&2
  find /usr/lib/efi /boot/efi -type f -path '*/EFI/*' -print >&2 || true
  exit 1
fi
mkdir -p /boot/efi/EFI/BOOT
# UEFI removable-media fallback; keep fbx64.efi for bootc-image-builder.
cp -v "${grubx64}" /boot/efi/EFI/BOOT/BOOTX64.EFI
cp -v "${grubx64}" /boot/efi/EFI/BOOT/fbx64.efi

systemd-firstboot --timezone UTC
dnf clean all
