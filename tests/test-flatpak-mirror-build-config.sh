#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_script="${project_root}/build_files/build.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

mirror_function="${test_root}/configure-mirrors.sh"
sed -n '/^configure_mirrors() {/,/^}$/p' "${build_script}" > "${mirror_function}"
source "${mirror_function}"

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    printf 'FAIL: %s\nexpected: <%s>\nactual:   <%s>\n' "${message}" "${expected}" "${actual}" >&2
    exit 1
  fi
}

run_case() {
  local name="$1" helper_mode="$2" repo_mode="$3"
  local case_root="${test_root}/${name}"
  mkdir -p "${case_root}/etc/environment.d" "${case_root}/skel/.config/environment.d" "${case_root}/etc/flatpak/remotes.d" "${case_root}/usr/libexec"
  export TEST_ROOT="${case_root}"
  export FLATPAK_REMOTE_URL='https://mirror.example/flathub'
  unset HOMEBREW_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN

  if [[ "${helper_mode}" != missing ]]; then
    cat > "${case_root}/usr/libexec/bazzite-mirror-utils.sh" <<'HELPER'
#!/usr/bin/env bash
[[ "${HELPER_MODE}" == fail ]] && exit 1
awk -v url="${2%/}/" 'BEGIN{updated=0} /^Url=/{print "Url=" url;updated=1;next} {print} END{if(!updated)print "Url=" url}' "${TEST_ROOT}/etc/flatpak/remotes.d/flathub.flatpakrepo" > "${TEST_ROOT}/repo.tmp" && mv "${TEST_ROOT}/repo.tmp" "${TEST_ROOT}/etc/flatpak/remotes.d/flathub.flatpakrepo"
HELPER
    chmod +x "${case_root}/usr/libexec/bazzite-mirror-utils.sh"
  fi

  printf '[Flatpak Repo]\nTitle=Flathub\nUrl=https://dl.flathub.org/repo/\nHomepage=https://flathub.org/\n' > "${case_root}/etc/flatpak/remotes.d/flathub.flatpakrepo"
  if [[ "${repo_mode}" == readonly ]]; then chmod 0444 "${case_root}/etc/flatpak/remotes.d/flathub.flatpakrepo"; fi

  # Relocate production paths into an isolated fixture, then execute the
  # extracted production function directly.
  export HELPER_MODE="${helper_mode}"
  sed -e "s|/etc/environment.d|${case_root}/etc/environment.d|g" \
      -e "s|/etc/skel|${case_root}/skel|g" \
      -e "s|/usr/libexec|${case_root}/usr/libexec|g" \
      -e "s|/etc/flatpak|${case_root}/etc/flatpak|g" \
      "${mirror_function}" > "${case_root}/configure-mirrors.sh"
  source "${case_root}/configure-mirrors.sh"
  configure_mirrors

  local actual_url
  actual_url="$(sed -n 's/^Url=//p' "${case_root}/etc/flatpak/remotes.d/flathub.flatpakrepo")"
  if [[ "${helper_mode}" == success || ( "${repo_mode}" == writable && "${helper_mode}" != success ) ]]; then
    assert_eq 'https://mirror.example/flathub/' "${actual_url}" "${name}: configured mirror URL"
  else
    assert_eq 'https://dl.flathub.org/repo/' "${actual_url}" "${name}: retain original URL when no write path exists"
  fi
  assert_eq 'FLATPAK_REMOTE_URL=https://mirror.example/flathub' "$(cat "${case_root}/etc/environment.d/99-aerocore-mirrors.conf")" "${name}: persist environment setting"
}

run_case helper_success success writable
run_case helper_failure fail writable
run_case helper_missing missing writable
run_case no_write_path fail readonly

echo "Flatpak mirror behavior checks passed."
