#!/usr/bin/env bash

set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE=${BASE_IMAGE:?}
INSTALL_IMAGE_PAYLOAD=${INSTALL_IMAGE_PAYLOAD:?}
INSTALL_IMAGE_PAYLOAD_ARCHIVE=${INSTALL_IMAGE_PAYLOAD_ARCHIVE:-}
INSTALL_IMAGE_TAG=${INSTALL_IMAGE_TAG:?}
OSTREE_IMAGE_REF=${OSTREE_IMAGE_REF:?}
ostree_origin_ref="${OSTREE_IMAGE_REF}:${INSTALL_IMAGE_TAG}"
live_version_id="$(awk -F= '$1 == "VERSION_ID" { gsub(/\"/, "", $2); print $2; exit }' /usr/lib/os-release)"

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
  gdisk \
  grub2-efi-x64 \
  grub2-efi-x64-cdboot

# Kinoite can carry the EFI packages in the RPM database without their files
# materialized in the container filesystem. Restore the files for the ISO.
dnf --setopt=excludepkgs= reinstall -y \
  grub2-efi-x64 \
  grub2-efi-x64-cdboot

# Fedora 43's anaconda-webui bundle embeds a Cockpit password helper from
# before cockpit-project/cockpit@900c13f. Fedora 44 already carries the fix;
# retain the workaround only for explicitly requested Fedora 43 live images.
if [[ "${live_version_id}" == "43" ]]; then
  "${SCRIPT_DIR}/patch-anaconda-webui.sh"
fi

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

# The target system is an upstream-built bootc image. Keep this installer-only
# helper out of the installed image and invoke it after Anaconda mounts the
# target rootfs.
install -Dm0755 \
  "${SCRIPT_DIR}/configure-target-grub.sh" \
  /usr/libexec/aerocore-configure-target-grub

install -Dm0755 \
  "${SCRIPT_DIR}/configure-target-gpt-root.sh" \
  /usr/libexec/aerocore-configure-target-gpt-root

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

live_product_name="AeroCore OS"
sed -i "s/^NAME=.*/NAME=\"${live_product_name}\"/" /usr/lib/os-release
sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"${live_product_name} ${live_version_id} (Kinoite)\"/" /usr/lib/os-release
sed -i "s/^LOGO=.*/LOGO=distributor-logo/" /usr/lib/os-release
printf '%s release %s (Kinoite)\n' "${live_product_name}" "${live_version_id}" > /etc/system-release

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

# Refuse to build an ISO with a payload that still carries Bazzite release
# bytes. bootupd derives its EFI label from system-release during installation;
# a trailing NUL there makes efibootmgr fail before Anaconda can run %post.
podman run --rm --entrypoint /usr/bin/bash "${INSTALL_IMAGE_PAYLOAD}" -ceu '
  system_release=/etc/system-release
  system_release_target=$(readlink -f "$system_release")

  if od -An -v -tx1 "$system_release_target" | awk '\''{ for (i = 1; i <= NF; i++) if ($i == "00") found = 1 } END { exit(found ? 0 : 1) }'\''; then
    echo "Install payload has a NUL byte in ${system_release_target}" >&2
    od -An -v -tx1 "$system_release_target" >&2
    exit 1
  fi

  expected_prefix="AeroCore OS release $(rpm -E %fedora) ("
  system_release_value=$(<"$system_release_target")
  case "$system_release_value" in
    "$expected_prefix"*) ;;
    *)
      echo "Install payload has an unexpected system-release: ${system_release_value@Q}" >&2
      exit 1
      ;;
  esac

  jq -e '\''.["image-name"] == "aerocore-os" and .["image-vendor"] == "aerocore-io"'\'' \
    /usr/share/ublue-os/image-info.json >/dev/null
'

# Tell Anaconda to install the bootc container that was loaded above.
mkdir -p /var/lib/rpm-state
cat >> /usr/share/anaconda/interactive-defaults.ks <<EOF
%pre-install --log=/tmp/aerocore-var-tmp.log
set -eux
target_tmp=
for root in /mnt/sysimage /mnt/sysroot /var/mnt/sysimage; do
    if mountpoint -q \${root}; then
        target_tmp=\${root}/var/tmp
        break
    fi
done
if [ x\${target_tmp} = x ]; then
    echo No mounted target system found for /var/tmp bind mount >&2
    exit 1
fi
mkdir -p \${target_tmp}
chmod 1777 \${target_tmp}
mount --bind \${target_tmp} /var/tmp
df -h /var/tmp \${target_tmp}
%end

# bootc relies on systemd's GPT auto-root discovery on the first boot. Anaconda
# can leave the installed root partition with the generic Linux filesystem
# type, which makes /dev/gpt-auto-root unavailable even though the filesystem
# itself is healthy. Normalize the type before ostreecontainer deployment.
%pre-install --erroronfail --log=/tmp/aerocore-gpt-root.log
set -eux
target_root=
for root in /mnt/sysroot /mnt/sysimage /var/mnt/sysroot /var/mnt/sysimage; do
    if mountpoint -q \${root}; then
        target_root=\${root}
        break
    fi
done
if [ x\${target_root} = x ]; then
    echo No mounted target system found for GPT root configuration >&2
    exit 1
fi
/usr/libexec/aerocore-configure-target-gpt-root \${target_root}
%end

# Do not let stale Fedora boot files from an earlier installation collide with
# the bootc payload being installed. This matches the upstream Bazzite
# installer behavior; other vendor EFI directories are left untouched.
%pre-install --erroronfail --log=/tmp/aerocore-efi-cleanup.log
set -eux
efi_root=
for root in /mnt/sysroot /mnt/sysimage /var/mnt/sysroot /var/mnt/sysimage; do
    if mountpoint -q \${root}/boot/efi; then
        efi_root=\${root}/boot/efi
        break
    fi
done
if [ x\${efi_root} = x ]; then
    echo No mounted EFI system partition found for cleanup >&2
    exit 1
fi
rm -rf \${efi_root}/EFI/fedora
%end
ostreecontainer --url=${INSTALL_IMAGE_PAYLOAD} --transport=containers-storage --no-signature-verification

# The local containers-storage deployment is intentionally unverified because
# the payload is loaded from an OCI archive. Point future bootc updates at the
# signed registry reference configured for the image instead.
%post --erroronfail --log=/tmp/aerocore-origin.log
set -eux
sed -i 's|container-image-reference=.*|container-image-reference=${ostree_origin_ref}|' /ostree/deploy/default/deploy/*.origin
%end

%post --nochroot --log=/tmp/aerocore-hostname.log
set -eux
target_root=
for root in /mnt/sysroot /mnt/sysimage /var/mnt/sysimage; do
    if mountpoint -q \${root}; then
        target_root=\${root}
        break
    fi
done
if [ x\${target_root} = x ]; then
    echo No mounted target system found for hostname setup >&2
    exit 1
fi
systemd-firstboot --root=\${target_root} --hostname=aerocore-os
%end

%post --nochroot --log=/tmp/aerocore-grub.log
set -eux
target_root=
for root in /mnt/sysroot /mnt/sysimage /var/mnt/sysimage; do
    if mountpoint -q \${root}; then
        target_root=\${root}
        break
    fi
done
if [ x\${target_root} = x ]; then
    echo No mounted target system found for GRUB configuration >&2
    exit 1
fi
/usr/libexec/aerocore-configure-target-grub \${target_root}
%end
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

systemd-firstboot --hostname aerocore-os --timezone UTC
dnf clean all
