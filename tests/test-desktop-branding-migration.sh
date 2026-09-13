#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d -t aerocore-desktop-branding.XXXXXXXXXX)"
trap 'rm -rf "${test_root}"' EXIT

mkdir -p \
  "${test_root}/var/home/stock/.config" \
  "${test_root}/var/home/custom/.config"

printf '%s\n' 'icon=distributor-logo-steamdeck' \
  > "${test_root}/var/home/stock/.config/plasma-org.kde.plasma.desktop-appletsrc"
printf '%s\n' 'icon=user-selected-logo' \
  > "${test_root}/var/home/custom/.config/plasma-org.kde.plasma.desktop-appletsrc"

HOME="${test_root}/var/home/stock" \
  bash "${repo_root}/system_files/usr/libexec/aerocore-desktop-branding"

grep -Fxq 'icon=aerocore-logo' \
  "${test_root}/var/home/stock/.config/plasma-org.kde.plasma.desktop-appletsrc"
grep -Fxq 'icon=user-selected-logo' \
  "${test_root}/var/home/custom/.config/plasma-org.kde.plasma.desktop-appletsrc"

# The migration must also be idempotent.
first_digest="$(sha256sum \
  "${test_root}/var/home/stock/.config/plasma-org.kde.plasma.desktop-appletsrc")"
HOME="${test_root}/var/home/stock" \
  bash "${repo_root}/system_files/usr/libexec/aerocore-desktop-branding"
second_digest="$(sha256sum \
  "${test_root}/var/home/stock/.config/plasma-org.kde.plasma.desktop-appletsrc")"
test "${first_digest}" = "${second_digest}"

for path in \
  bazzite.webm \
  bazzite-oled.webm \
  bazzite-suspend.webm \
  bazzite-suspend-oled.webm; do
  grep -Fq "${path}" "${repo_root}/build_files/build.sh"
done

# The About System logo may be a symlink in the Bazzite base image. Both image
# build paths must explicitly replace that directory entry with AeroCore's PNG.
grep -Fq '"/usr/share/pixmaps/system-logo-white.png"' \
  "${repo_root}/build_files/build.sh"
grep -Fq 'rm -f /usr/share/pixmaps/system-logo-white.png' \
  "${repo_root}/installer/build.sh"

# Branding migration is user setup, not a system boot service.
if rg -n 'aerocore-desktop-branding\.service|systemctl enable aerocore-desktop-branding' \
  "${repo_root}/build_files" "${repo_root}/system_files"; then
  echo "Desktop branding must not be enabled as a system service" >&2
  exit 1
fi
test ! -e "${repo_root}/system_files/usr/lib/systemd/system/aerocore-desktop-branding.service"
test -x "${repo_root}/system_files/usr/libexec/aerocore-desktop-branding-privileged"

echo "Desktop branding migration fixture passed"
