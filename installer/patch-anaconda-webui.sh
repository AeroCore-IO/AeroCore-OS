#!/usr/bin/env bash

set -euo pipefail

bundle="${1:-/usr/share/cockpit/anaconda-webui/index.js.gz}"
broken='n===0?r(new Error(X2("Password is too weak"))):o('
fixed='n===0&&!e?r(new Error(X2("Password is too weak"))):o('
fixed_sed='n===0\&\&!e?r(new Error(X2("Password is too weak"))):o('

if [[ ! -f "${bundle}" ]]; then
  echo "Anaconda WebUI bundle not found: ${bundle}" >&2
  exit 1
fi

webui_js="$(mktemp)"
patched_js="$(mktemp)"
patched_bundle="$(mktemp)"
trap 'rm -f "${webui_js}" "${patched_js}" "${patched_bundle}"' EXIT

gzip -dc "${bundle}" > "${webui_js}"

fixed_count="$( (grep -oF "${fixed}" "${webui_js}" || true) | wc -l | tr -d ' ')"
if [[ "${fixed_count}" == "1" ]]; then
  echo "Anaconda WebUI weak-password handling is already fixed"
  exit 0
fi

broken_count="$( (grep -oF "${broken}" "${webui_js}" || true) | wc -l | tr -d ' ')"
if [[ "${broken_count}" != "1" ]]; then
  echo "Unexpected Anaconda WebUI password helper; refusing an unsafe patch" >&2
  echo "Expected one weak-password rejection, found ${broken_count}" >&2
  exit 1
fi

sed "s|${broken}|${fixed_sed}|" "${webui_js}" > "${patched_js}"

fixed_count="$( (grep -oF "${fixed}" "${patched_js}" || true) | wc -l | tr -d ' ')"
if [[ "${fixed_count}" != "1" ]] || grep -Fq "${broken}" "${patched_js}"; then
  echo "Failed to patch Anaconda WebUI weak-password handling" >&2
  exit 1
fi

gzip -n -9 -c "${patched_js}" > "${patched_bundle}"
chmod 0644 "${patched_bundle}"
mv -f "${patched_bundle}" "${bundle}"

echo "Patched Anaconda WebUI weak-password handling"
