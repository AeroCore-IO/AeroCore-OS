#!/usr/bin/bash

set -euo pipefail

root="${AEROCORE_DECK_COMPAT_ROOT:-}"
root="${root%/}"

target_path() {
  printf '%s%s\n' "$root" "$1"
}

patch_condition() {
  local file="$1"
  local old_condition="$2"
  local new_condition="$3"
  local expected_count="$4"
  local old_count new_count patched_file

  if [[ ! -f "$file" ]]; then
    echo "Unable to locate expected Bazzite Deck file: $file" >&2
    exit 1
  fi

  new_count="$(grep -Foc "$new_condition" "$file" || true)"
  if [[ "$new_count" -eq "$expected_count" ]]; then
    return 0
  fi

  old_count="$(grep -Foc "$old_condition" "$file" || true)"
  if [[ "$old_count" -ne "$expected_count" ]]; then
    echo "Unable to locate the expected Bazzite Deck image check in $file" >&2
    echo "Expected $expected_count occurrence(s), found old=$old_count new=$new_count" >&2
    exit 1
  fi

  patched_file="$(mktemp)"
  awk \
    -v old_condition="$old_condition" \
    -v new_condition="$new_condition" \
    ' {
      position = index($0, old_condition)
      if (position) {
        $0 = substr($0, 1, position - 1) new_condition substr($0, position + length(old_condition))
      }
      print
    }' "$file" > "$patched_file"

  cp "$patched_file" "$file"
  rm -f "$patched_file"

  new_count="$(grep -Foc "$new_condition" "$file" || true)"
  if [[ "$new_count" -ne "$expected_count" ]]; then
    echo "Failed to patch the Bazzite Deck image check in $file" >&2
    exit 1
  fi
}

patch_steam_state_migration() {
  local file="$1"
  # shellcheck disable=SC2016
  local condition='if [[ $IMAGE_NAME =~ "deck" || $IMAGE_NAME == aerocore-os ]]; then'
  local marker='AeroCore Steam state migration'
  local patched_file

  if [[ ! -f "$file" ]]; then
    echo "Unable to locate expected Bazzite Deck file: $file" >&2
    exit 1
  fi

  if grep -Fq "$marker" "$file"; then
    return 0
  fi

  if [[ "$(grep -Foc "$condition" "$file" || true)" -ne 1 ]]; then
    echo "Unable to locate the AeroCore Steam bootstrap condition in $file" >&2
    exit 1
  fi

  patched_file="$(mktemp)"
  awk -v condition="$condition" '
    !inserted && $0 == condition {
      print
      print "  # AeroCore Steam state migration"
      print "  # Older AeroCore images could leave ~/.steam/steam as a directory."
      print "  # Preserve it before restoring the symlink expected by Steam."
      print "  STEAM_DATA_HOME=\"$HOME/.local/share/Steam\""
      print "  STEAM_DATA_LINK=\"$HOME/.steam/steam\""
      print "  if [[ -d \"$STEAM_DATA_LINK\" && ! -L \"$STEAM_DATA_LINK\" && -x \"$STEAM_DATA_HOME/steam.sh\" ]]; then"
      print "    STEAM_DATA_BACKUP=\"${STEAM_DATA_LINK}.aerocore-backup-$(date +%s)-$$\""
      print "    STEAM_DATA_TEMP=\"${STEAM_DATA_LINK}.aerocore-link-$$\""
      print "    if ln -s \"$STEAM_DATA_HOME\" \"$STEAM_DATA_TEMP\" && mv -- \"$STEAM_DATA_LINK\" \"$STEAM_DATA_BACKUP\" && mv -- \"$STEAM_DATA_TEMP\" \"$STEAM_DATA_LINK\"; then"
      print "      :"
      print "    else"
      print "      rm -f -- \"$STEAM_DATA_TEMP\""
      print "    fi"
      print "  fi"
      inserted=1
      next
    }
    { print }
    END { if (!inserted) exit 1 }
  ' "$file" > "$patched_file"

  cp "$patched_file" "$file"
  rm -f "$patched_file"

  if ! grep -Fq "$marker" "$file"; then
    echo "Failed to add the AeroCore Steam state migration to $file" >&2
    exit 1
  fi
}

# Keep AeroCore's public image-name, while restoring the Deck capability checks
# used by Bazzite's runtime scripts. These are literal source lines; variable
# expansion must happen later, when the scripts run on the installed system.
# shellcheck disable=SC2016
patch_condition \
  "${1:-$(target_path /usr/libexec/bazzite-hardware-setup)}" \
  'if [[ "$IMAGE_NAME" != *deck* && "$IMAGE_NAME" != *dx* ]]; then' \
  'if [[ "$IMAGE_NAME" != aerocore-os && "$IMAGE_NAME" != *deck* && "$IMAGE_NAME" != *dx* ]]; then' \
  1

# The hardware setup has a second Deck-only block after the top-level image
# guard. Keep it active for AeroCore as well.
# shellcheck disable=SC2016
patch_condition \
  "${1:-$(target_path /usr/libexec/bazzite-hardware-setup)}" \
  'if [[ $IMAGE_NAME =~ "deck" ]]; then' \
  'if [[ $IMAGE_NAME =~ "deck" || $IMAGE_NAME == aerocore-os ]]; then' \
  1

# bazzite-steam gates the Steam bootstrap archive and -steamdeck flag on the
# image name. The user setup script has the same Deck-only gating in three
# places.
# shellcheck disable=SC2016
patch_condition \
  "$(target_path /usr/bin/bazzite-steam)" \
  'if [[ $IMAGE_NAME =~ "deck" ]]; then' \
  'if [[ $IMAGE_NAME =~ "deck" || $IMAGE_NAME == aerocore-os ]]; then' \
  1

patch_steam_state_migration "$(target_path /usr/bin/bazzite-steam)"

# shellcheck disable=SC2016
patch_condition \
  "$(target_path /usr/libexec/bazzite-user-setup)" \
  'if [[ $IMAGE_NAME =~ "deck" ]]; then' \
  'if [[ $IMAGE_NAME =~ "deck" || $IMAGE_NAME == aerocore-os ]]; then' \
  3
