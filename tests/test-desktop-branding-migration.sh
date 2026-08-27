#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d -t aerocore-desktop-branding.XXXXXXXXXX)"
trap 'rm -rf "${test_root}"' EXIT

mkdir -p \
  "${test_root}/usr/share/aerocore/desktop-branding" \
  "${test_root}/etc/xdg" \
  "${test_root}/var/home/stock/.config" \
  "${test_root}/var/home/custom/.config"

cp "${repo_root}/system_files/usr/share/aerocore/desktop-branding/kcm-about-distrorc" \
  "${test_root}/usr/share/aerocore/desktop-branding/kcm-about-distrorc"
printf '%s\n' '[General]' 'Name=Bazzite' > "${test_root}/etc/xdg/kcm-about-distrorc"
printf '%s\n' 'icon=distributor-logo-steamdeck' \
  > "${test_root}/var/home/stock/.config/plasma-org.kde.plasma.desktop-appletsrc"
printf '%s\n' 'icon=user-selected-logo' \
  > "${test_root}/var/home/custom/.config/plasma-org.kde.plasma.desktop-appletsrc"

AEROCORE_DESKTOP_BRANDING_ROOT="${test_root}" \
  bash "${repo_root}/system_files/usr/libexec/aerocore-desktop-branding"

grep -Fxq 'Name=AeroCore OS' "${test_root}/etc/xdg/kcm-about-distrorc"
grep -Fxq 'icon=aerocore-logo' \
  "${test_root}/var/home/stock/.config/plasma-org.kde.plasma.desktop-appletsrc"
grep -Fxq 'icon=user-selected-logo' \
  "${test_root}/var/home/custom/.config/plasma-org.kde.plasma.desktop-appletsrc"

# The migration must also be idempotent.
first_digest="$(sha256sum \
  "${test_root}/etc/xdg/kcm-about-distrorc" \
  "${test_root}/var/home/stock/.config/plasma-org.kde.plasma.desktop-appletsrc")"
AEROCORE_DESKTOP_BRANDING_ROOT="${test_root}" \
  bash "${repo_root}/system_files/usr/libexec/aerocore-desktop-branding"
second_digest="$(sha256sum \
  "${test_root}/etc/xdg/kcm-about-distrorc" \
  "${test_root}/var/home/stock/.config/plasma-org.kde.plasma.desktop-appletsrc")"
test "${first_digest}" = "${second_digest}"

for path in \
  bazzite.webm \
  bazzite-oled.webm \
  bazzite-suspend.webm \
  bazzite-suspend-oled.webm; do
  grep -Fq "${path}" "${repo_root}/build_files/build.sh"
done

echo "Desktop branding migration fixture passed"
