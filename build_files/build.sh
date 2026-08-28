#!/bin/bash

set -ouex pipefail

case "${BASE_IMAGE:-}" in
  ghcr.io/ublue-os/bazzite-deck:* | ghcr.io/ublue-os/bazzite-deck@*)
    ;;
  *)
    echo "AeroCore OS only supports bazzite-deck BASE_IMAGE values for HTPC game-mode builds: ${BASE_IMAGE:-<unset>}" >&2
    exit 1
    ;;
esac

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

install_regular_file() {
  local source_file="$1"
  local destination_file="$2"

  # Several Bazzite branding paths are symlinks.  cp follows an existing
  # destination symlink, which leaves the name Plasma resolves untouched.
  # Replace the link itself so the final immutable image owns this exact path.
  rm -f -- "${destination_file}"
  install -Dm0644 -- "${source_file}" "${destination_file}"
}

# KDE's Deck presets use distributor-logo-steamdeck.svg for the Kickoff
# launcher.  In the Bazzite base image that name (and the related aliases)
# may already exist as links to the upstream distributor-logo.svg.  Install
# the AeroCore asset explicitly after the general overlay so the final image
# cannot silently retain the upstream Bazzite logo.
AEROCORE_DISTRIBUTOR_LOGO="/ctx/system_files/usr/share/icons/hicolor/scalable/places/distributor-logo.svg"
AEROCORE_ICON_DIR="/usr/share/icons/hicolor/scalable/places"
mkdir -p "${AEROCORE_ICON_DIR}"
for icon_name in \
  distributor-logo.svg \
  distributor-logo-steamdeck.svg \
  bazzite-logo.svg \
  start-here.svg; do
  install_regular_file "${AEROCORE_DISTRIBUTOR_LOGO}" "${AEROCORE_ICON_DIR}/${icon_name}"
done

# Use a downstream-specific, non-upstream icon name for Plasma's launcher.
install_regular_file \
  "/ctx/system_files/usr/share/pixmaps/bazzite-logo-le.svg" \
  "/usr/share/icons/hicolor/scalable/apps/aerocore-logo.svg"

# KDE's About System KCM loads this path from kcm-about-distrorc.  The base
# image may provide it as a symlink, so replace the directory entry itself or
# the KCM can continue rendering the upstream Bazzite logo.
install_regular_file \
  "/ctx/system_files/usr/share/pixmaps/system-logo-white.png" \
  "/usr/share/pixmaps/system-logo-white.png"

# Game Mode's Vapor splash asset is an upstream symlink on current Bazzite
# images, while VGUI is a regular file.  Replace both exact paths explicitly.
for look_and_feel in com.valve.vapor.desktop com.valve.vgui.desktop; do
  install_regular_file \
    "/ctx/system_files/usr/share/plasma/look-and-feel/${look_and_feel}/contents/splash/images/bazzite_logo.svgz" \
    "/usr/share/plasma/look-and-feel/${look_and_feel}/contents/splash/images/bazzite_logo.svgz"
done

# Steam's Game Mode transitions load these four assets directly.  They are
# symlinks in some upstream layers, so replace their directory entries just
# like the Plasma splash assets above.
for animation in \
  bazzite.webm \
  bazzite-oled.webm \
  bazzite-suspend.webm \
  bazzite-suspend-oled.webm; do
  install_regular_file \
    "/ctx/system_files/usr/share/ublue-os/bazzite/${animation}" \
    "/usr/share/ublue-os/bazzite/${animation}"
done

gtk-update-icon-cache -f /usr/share/icons/hicolor || true

# The Plasma launcher resolves the standard start-here name from both scalable
# and per-size places directories.  Populate every existing Bazzite icon size
# in the installed payload, not only in the live installer image.
for icon_dir in /usr/share/icons/hicolor/*; do
  [[ -d "${icon_dir}" ]] || continue
  source_icon="${icon_dir}/bazzite-logo-icon.png"
  if [[ -f "${source_icon}" ]]; then
    mkdir -p "${icon_dir}/apps" "${icon_dir}/places"
    cp -f "${source_icon}" "${icon_dir}/places/start-here.png"
    cp -f "${source_icon}" "${icon_dir}/apps/fedora-logo-icon.png"
  fi
done

if ! cmp -s "${AEROCORE_DISTRIBUTOR_LOGO}" "${AEROCORE_ICON_DIR}/distributor-logo.svg"; then
  echo "AeroCore distributor logo was not installed into the image" >&2
  exit 1
fi

# Default HDMI-CEC to putting the TV into standby when the system sleeps.
# `ujust toggle-cec-sleep enable` changes this same setting at runtime.  Keep
# the default in the base image's config so users do not need to run the
# command manually after a fresh install; the runtime command can still
# change it later.
CEC_CONFIG=/etc/default/cec-control
if [[ -f "${CEC_CONFIG}" ]]; then
  if grep -q '^CEC_ONSLEEP_STANDBY=' "${CEC_CONFIG}"; then
    sed -i 's/^CEC_ONSLEEP_STANDBY=.*/CEC_ONSLEEP_STANDBY=true/' "${CEC_CONFIG}"
  else
    printf '%s\n' 'CEC_ONSLEEP_STANDBY=true' >> "${CEC_CONFIG}"
  fi
fi

mkdir -p /etc/environment.d

if [[ -n "${FLATPAK_REMOTE_URL:-}" || -n "${HOMEBREW_BOTTLE_DOMAIN:-}" || -n "${HOMEBREW_API_DOMAIN:-}" ]]; then
  : > /etc/environment.d/99-aerocore-mirrors.conf
fi

if [[ -n "${FLATPAK_REMOTE_URL:-}" ]]; then
  printf '%s\n' "FLATPAK_REMOTE_URL=${FLATPAK_REMOTE_URL}" >> /etc/environment.d/99-aerocore-mirrors.conf
  if [[ -f /usr/libexec/bazzite-mirror-utils.sh ]]; then
    bash /usr/libexec/bazzite-mirror-utils.sh update_flathub_repo_url "${FLATPAK_REMOTE_URL}"
  fi
fi

if [[ -n "${HOMEBREW_BOTTLE_DOMAIN:-}" || -n "${HOMEBREW_API_DOMAIN:-}" ]]; then
  mkdir -p /etc/skel/.config/environment.d
  : > /etc/skel/.config/environment.d/99-aerocore-mirrors.conf
fi

if [[ -n "${HOMEBREW_BOTTLE_DOMAIN:-}" ]]; then
  printf '%s\n' "HOMEBREW_BOTTLE_DOMAIN=${HOMEBREW_BOTTLE_DOMAIN}" | tee -a /etc/environment.d/99-aerocore-mirrors.conf /etc/skel/.config/environment.d/99-aerocore-mirrors.conf >/dev/null
fi

if [[ -n "${HOMEBREW_API_DOMAIN:-}" ]]; then
  printf '%s\n' "HOMEBREW_API_DOMAIN=${HOMEBREW_API_DOMAIN}" | tee -a /etc/environment.d/99-aerocore-mirrors.conf /etc/skel/.config/environment.d/99-aerocore-mirrors.conf >/dev/null
fi

find /etc/environment.d /etc/skel/.config/environment.d -name 99-aerocore-mirrors.conf -type f -exec chmod 0644 {} + 2>/dev/null || true

/ctx/install-instruments.sh
/ctx/patch-bazzite-deck-identity.sh
