#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
recipe="${project_root}/system_files/usr/share/ublue-os/just/92-aerocore-decky-mirror.just"

if [[ ! -f "${recipe}" ]]; then
  echo "Missing Decky mirror ujust recipe: ${recipe}" >&2
  exit 1
fi

if ! rg -q '^setup-decky-mirror ACTION=""' "${recipe}"; then
  echo "Decky mirror recipe must expose ujust setup-decky-mirror" >&2
  exit 1
fi

if ! rg -q 'decky\.mirror\.aerocore\.com\.cn' "${recipe}"; then
  echo "Decky mirror recipe must default to the AeroCore Decky mirror host" >&2
  exit 1
fi

if rg -q 'https://github\.com/SteamDeckHomebrew/decky-installer' "${recipe}"; then
  echo "Decky mirror recipe must not install from GitHub" >&2
  exit 1
fi

if ! rg -q 'configure_plugin_store\(\)' "${recipe}" || \
   ! rg -q 'plugins\.decky\.mirror\.aerocore\.com\.cn' "${recipe}" || \
   ! rg -q 'DECKY_PLUGIN_STORE_URL=.*\/plugins' "${recipe}"; then
  echo "Decky mirror recipe must configure the AeroCore plugin store URL" >&2
  exit 1
fi

if ! rg -q 'loader\.json' "${recipe}" || ! rg -q '\.store = 2' "${recipe}" || ! rg -q 'store-url' "${recipe}"; then
  echo "Decky mirror recipe must persist the custom plugin store in loader.json" >&2
  exit 1
fi

if ! rg -q 'rm -rf.*HOMEBREW_FOLDER.*/services/PluginLoader' "${recipe}" ||
   ! rg -q 'rm -f.*USER_DIR.*/\.steam/steam/\.cef-enable-remote-debugging' "${recipe}" ||
   ! rg -q 'rm -f.*USER_DIR.*/\.var/app/com\.valvesoftware\.Steam/data/Steam/\.cef-enable-remote-debugging' "${recipe}"; then
  echo "Decky mirror recipe must make uninstall safe for missing paths" >&2
  exit 1
fi

for script_name in install_release.sh install_prerelease.sh uninstall.sh; do
  if ! rg -q "\\$\\{DECKY_INSTALLER_BASE\\}/${script_name}" "${recipe}"; then
    echo "Decky mirror recipe does not route ${script_name} through the mirror base" >&2
    exit 1
  fi
done
