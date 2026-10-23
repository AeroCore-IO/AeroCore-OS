#!/usr/bin/bash

set -euo pipefail

file=/usr/libexec/os-branch-select

if [[ ! -f "$file" ]]; then
  echo "Unable to locate Bazzite OS branch selector: $file" >&2
  exit 1
fi

old='      branch=$(cut -d ":" -f4 <<< "$(rpm-ostree status --booted | grep -m 1 $ID)")'
if ! grep -Fxq "$old" "$file"; then
  echo "Bazzite OS branch selector changed; review the downstream patch" >&2
  exit 1
fi

patched_file=$(mktemp)
awk -v old="$old" '
  $0 == old {
    print "      # Read the booted deployment directly; its image name need not match os-release ID."
    print "      image_ref=$(rpm-ostree status --booted --json | jq -r '\''[.deployments[] | select(.booted) | .[\"container-image-reference\"] // empty][0] // empty'\'')"
    print "      branch=\"\""
    print "      if [[ $image_ref =~ :([^/:]+)$ ]]; then"
    print "        branch=${BASH_REMATCH[1]}"
    print "      fi"
    found++
    next
  }
  { print }
  END { if (found != 1) exit 1 }
' "$file" > "$patched_file"

install -m 0755 "$patched_file" "$file"
rm -f "$patched_file"
