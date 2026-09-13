#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="${repo_root}/tests/fixtures/bazzite-44"
test_root="$(mktemp -d -t aerocore-deck-identity.XXXXXXXXXX)"
trap 'rm -rf "${test_root}"' EXIT

cp -a "${fixture_root}/." "${test_root}/"

run_patch() {
  AEROCORE_DECK_COMPAT_ROOT="${test_root}" \
    bash "${repo_root}/build_files/patch-bazzite-deck-identity.sh"
}

assert_count() {
  local expected="$1"
  local pattern="$2"
  local file="$3"
  local actual

  actual="$(grep -Foc "${pattern}" "${file}" || true)"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Expected ${expected} occurrence(s) of '${pattern}' in ${file}, found ${actual}" >&2
    exit 1
  fi
}

hardware_setup="${test_root}/usr/libexec/bazzite-hardware-setup"
steam="${test_root}/usr/bin/bazzite-steam"
user_setup="${test_root}/usr/libexec/bazzite-user-setup"
# shellcheck disable=SC2016
deck_condition='if [[ $IMAGE_NAME =~ "deck" || $IMAGE_NAME == aerocore-os ]]; then'
# shellcheck disable=SC2016
non_deck_condition='if [[ "$IMAGE_NAME" != aerocore-os && "$IMAGE_NAME" != *deck* && "$IMAGE_NAME" != *dx* ]]; then'

run_patch

assert_count 1 "${non_deck_condition}" "${hardware_setup}"
assert_count 1 "${deck_condition}" "${hardware_setup}"
assert_count 1 "${deck_condition}" "${steam}"
assert_count 3 "${deck_condition}" "${user_setup}"
assert_count 1 'AeroCore Steam state migration' "${steam}"

# A second run must recognize the patched fixture and make no further changes.
first_digest="$(sha256sum "${hardware_setup}" "${steam}" "${user_setup}")"
run_patch
second_digest="$(sha256sum "${hardware_setup}" "${steam}" "${user_setup}")"

if [[ "${first_digest}" != "${second_digest}" ]]; then
  echo "Deck identity patch is not idempotent" >&2
  exit 1
fi

assert_count 1 'AeroCore Steam state migration' "${steam}"

echo "Bazzite 44 Deck identity fixture passed"
