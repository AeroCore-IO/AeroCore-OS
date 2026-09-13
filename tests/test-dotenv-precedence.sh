#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

grep -Fqx 'set dotenv-filename := ".env"' "${project_root}/Justfile"
grep -Fqx '.env' "${project_root}/.gitignore"
if rg -F -- '--dotenv-path image-template.env' "${project_root}/.github/workflows"; then
  echo 'CI must not load image-template.env as a dotenv file' >&2
  exit 1
fi

printf '%s\n' \
  'set dotenv-load' \
  'value := env_var("VALUE")' \
  'show:' \
  '    @echo "{{value}}"' > "${tmp_dir}/justfile"
printf '%s\n' 'VALUE=from-dotenv' > "${tmp_dir}/.env"

[[ "$(cd "${tmp_dir}" && just show)" == 'from-dotenv' ]]
[[ "$(cd "${tmp_dir}" && VALUE=from-runtime just show)" == 'from-runtime' ]]

mkdir "${tmp_dir}/without-dotenv"
cp "${tmp_dir}/justfile" "${tmp_dir}/without-dotenv/justfile"
[[ "$(cd "${tmp_dir}/without-dotenv" && VALUE=from-runtime just show)" == 'from-runtime' ]]
