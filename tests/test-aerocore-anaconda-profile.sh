#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${project_root}/installer/system_files/overrides/etc/anaconda/profile.d/aerocore.conf"
build_script="${project_root}/installer/build.sh"

grep -qx 'profile_id = aerocore' "${profile}"
grep -qx 'os_id = aerocore' "${profile}"
grep -Fqx "sed -i 's/^ID=.*/ID=aerocore/' /usr/lib/os-release" "${build_script}"

if grep -Eq '^[[:space:]]*(UserSpoke|anaconda-screen-accounts)[[:space:]]*$' "${profile}"; then
  echo "AeroCore's Anaconda profile must leave account creation visible" >&2
  exit 1
fi
