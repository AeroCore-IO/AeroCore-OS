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
