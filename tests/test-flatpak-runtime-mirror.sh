#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_script="${project_root}/system_files/usr/libexec/aerocore-configure-flatpak-mirror"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    printf 'FAIL: %s\nexpected: <%s>\nactual:   <%s>\n' "${message}" "${expected}" "${actual}" >&2
    exit 1
  fi
}

run_case() {
  local name="$1" exists="$2" url="$3"
  local root="${test_root}/${name}"
  mkdir -p "${root}/etc/environment.d" "${root}/etc/flatpak/remotes.d" "${root}/usr/bin"
  printf 'FLATPAK_REMOTE_URL=%s\n' "${url}" > "${root}/etc/environment.d/99-aerocore-mirrors.conf"
  : > "${root}/etc/flatpak/remotes.d/flathub.flatpakrepo"
  printf '%s\n' "${exists}" > "${root}/remote-exists"
  : > "${root}/flatpak.calls"

  cat > "${root}/usr/bin/flatpak" <<'FLATPAK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_ROOT}/flatpak.calls"
if [[ "$1 $2 $3" == 'remotes --system --columns=name' ]]; then
  [[ "$(cat "${TEST_ROOT}/remote-exists")" == true ]] && echo flathub
fi
if [[ "$1 $2 $3" == 'remote-add --system --if-not-exists' ]]; then
  printf true > "${TEST_ROOT}/remote-exists"
fi
FLATPAK
  chmod +x "${root}/usr/bin/flatpak"

  sed -e "s|/etc/environment.d|${root}/etc/environment.d|g" \
      -e "s|/etc/flatpak|${root}/etc/flatpak|g" \
      "${source_script}" > "${root}/configure-mirror"
  chmod +x "${root}/configure-mirror"
  export TEST_ROOT="${root}" PATH="${root}/usr/bin:${PATH}"
  bash "${root}/configure-mirror"
  cat "${root}/flatpak.calls" > "${root}/calls.actual"
}

run_case existing_remote true https://mirror.example/flathub
assert_eq 'remotes --system --columns=name
remote-modify --system flathub --url=https://mirror.example/flathub/' "$(cat "${test_root}/existing_remote/calls.actual")" 'existing remote is updated'

run_case missing_remote false https://mirror.example/flathub/
expected_missing_calls="$(printf 'remotes --system --columns=name\nremote-add --system --if-not-exists flathub %s\nremote-modify --system flathub --url=https://mirror.example/flathub/' "${test_root}/missing_remote/etc/flatpak/remotes.d/flathub.flatpakrepo")"
assert_eq "${expected_missing_calls}" "$(cat "${test_root}/missing_remote/calls.actual")" 'missing remote is added then updated'

run_case empty_url true ''
assert_eq '' "$(cat "${test_root}/empty_url/calls.actual")" 'empty setting leaves remotes unchanged'

run_case invalid_url true 'not-a-url'
assert_eq '' "$(cat "${test_root}/invalid_url/calls.actual")" 'invalid setting leaves remotes unchanged'

echo "Flatpak runtime mirror behavior checks passed."
