#!/usr/bin/env bash

set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
mkdir -p "${tmp_dir}/bin"

# shellcheck disable=SC2016 # The generated fixture expands this in its own process.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ " $* " == *" -no SOURCE "* ]]; then' \
  '  [[ " $* " == *" --nofsroot "* ]] || exit 97' \
  '  printf "%s\\n" "${TEST_FINDMNT_SOURCE:?}"' \
  'else' \
  "  printf '252:3\\n'" \
  'fi' > "${tmp_dir}/bin/findmnt"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case " $* " in' \
  "  *\" PKNAME \"*) printf 'vda\\n' ;;" \
  "  *\" PARTN \"*) printf '3\\n' ;;" \
  "  *\" PARTNUM \"*) exit 98 ;;" \
  "  *) printf '/dev/vda3 252:3\\n' ;;" \
  'esac' > "${tmp_dir}/bin/lsblk"

# shellcheck disable=SC2016 # The generated fixture expands TEST_OUTPUT itself.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" > "${TEST_OUTPUT:?}"' > "${tmp_dir}/bin/sgdisk"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${tmp_dir}/bin/partprobe"

chmod +x "${tmp_dir}/bin/"*

run_fixture() {
  local findmnt_source=$1

  TEST_FINDMNT_SOURCE="${findmnt_source}" TEST_OUTPUT="${tmp_dir}/sgdisk.args" \
    PATH="${tmp_dir}/bin:${PATH}" \
    bash "${project_root}/installer/configure-target-gpt-root.sh" /mnt/sysroot

  grep -qx -- '--typecode=3:4f68bce3-e8cd-4db1-96e7-fbcaf984b709 /dev/vda' \
    "${tmp_dir}/sgdisk.args"
}

run_fixture root
run_fixture '/dev/vda3[/root]'
printf 'GPT root bind-mount and Btrfs subvolume fixtures passed\n'
