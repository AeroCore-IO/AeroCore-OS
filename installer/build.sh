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
  grub2-efi-x64-cdboot

# Apply the same AeroCore overlay to the live session where possible.
if [[ -d /src/system_files ]]; then
  cp -a /src/system_files/. /
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
if compgen -G '/usr/lib/efi/*/*/EFI' >/dev/null; then
  cp -a /usr/lib/efi/*/*/EFI /boot/efi/
fi

# bootc-image-builder needs the Fedora live ISO fallback EFI loader.
cp -v /boot/efi/EFI/fedora/grubx64.efi /boot/efi/EFI/BOOT/fbx64.efi

systemd-firstboot --timezone UTC
dnf clean all
