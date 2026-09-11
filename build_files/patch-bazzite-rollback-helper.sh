#!/usr/bin/bash

set -euo pipefail

file=/usr/bin/bazzite-rollback-helper

if [[ ! -f "$file" ]]; then
  echo "Unable to locate Bazzite rollback helper: $file" >&2
  exit 1
fi

if grep -Fq 'current_image_prefix()' "$file"; then
  exit 0
fi

patched_file=$(mktemp)
awk '
  /^signing_scheme\(\) \{/ {
    print "signing_scheme() {"
    print "  local current=$(rpm-ostree status -b --json | jq -r '\''.deployments | map(select(.booted == true)) | first | .[\"container-image-reference\"] // empty'\'')"
    print "  local scheme=\"ostree-unverified-registry\""
    print "  [[ \"$current\" == *\"ostree-image-signed\"* ]] && scheme=\"ostree-image-signed\""
    print "  echo \"$scheme:docker://\""
    print "}"
    print ""
    print "current_image_prefix() {"
    print "  local current"
    print "  current=$(rpm-ostree status -b --json | jq -r '\''.deployments | map(select(.booted == true)) | first | .[\"container-image-reference\"] // empty'\'')"
    print "  if [[ -z \"$current\" ]]; then"
    print "    echo \"Unable to determine the current booted image reference.\" >&2"
    print "    return 1"
    print "  fi"
    print "  current=\"${current#ostree-image-signed:}\""
    print "  current=\"${current#ostree-unverified-registry:}\""
    print "  current=\"${current#docker://}\""
    print "  echo \"${current%/*}\""
    print "}"
    skip=1
    next
  }
  skip && /^warn_if_de_mismatch\(\) \{/ { skip=0; print; next }
  skip { next }
  { gsub("ostree-image-signed:docker://ghcr.io/ublue-os/", "$(signing_scheme)/$(current_image_prefix)/"); print }
' "$file" > "$patched_file"

install -m 0755 "$patched_file" "$file"
rm -f "$patched_file"
