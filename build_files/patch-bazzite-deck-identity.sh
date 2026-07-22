#!/usr/bin/bash

set -euo pipefail

hardware_setup="${1:-/usr/libexec/bazzite-hardware-setup}"
# These are literal source lines; variable expansion must happen at boot time.
# shellcheck disable=SC2016
old_condition='if [[ "$IMAGE_NAME" != *deck* && "$IMAGE_NAME" != *dx* ]]; then'
# shellcheck disable=SC2016
new_condition='if [[ "$IMAGE_NAME" != aerocore-os && "$IMAGE_NAME" != *deck* && "$IMAGE_NAME" != *dx* ]]; then'

if grep -Fqx "$new_condition" "$hardware_setup"; then
  exit 0
fi

if [[ "$(grep -Fxc "$old_condition" "$hardware_setup")" -ne 1 ]]; then
  echo "Unable to locate the Bazzite Deck image check in $hardware_setup" >&2
  exit 1
fi

patched_file=$(mktemp)
trap 'rm -f "$patched_file"' EXIT

awk \
  -v old_condition="$old_condition" \
  -v new_condition="$new_condition" \
  '$0 == old_condition {
    print new_condition
    next
  }
  { print }' "$hardware_setup" > "$patched_file"

cp "$patched_file" "$hardware_setup"

grep -Fqx "$new_condition" "$hardware_setup"
