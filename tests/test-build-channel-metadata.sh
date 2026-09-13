#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The build recipe's positional tag must be authoritative for channel
# metadata. This protects `just build ... testing` from stale dotenv values.
grep -Fqx '        "--build-arg" "IMAGE_BRANCH={{ tag }}"' "${repo_root}/Justfile"
grep -Fqx '        "--build-arg" "VERSION_TAG={{ tag }}"' "${repo_root}/Justfile"
grep -Fqx '        "--build-arg" "VERSION_PRETTY={{ tag }}"' "${repo_root}/Justfile"
grep -Fqx '        LABELS+=("--label" "org.opencontainers.image.version={{ tag }}-${GIT_SHA}")' "${repo_root}/Justfile"
grep -Fqx '  "image-tag": "$IMAGE_BRANCH_NORMALIZED",' "${repo_root}/build_files/image-info"

if grep -Fq '  "image-tag": "stable",' "${repo_root}/build_files/image-info"; then
  echo 'image-info must not hard-code stable as the image tag' >&2
  exit 1
fi

echo 'Build channel metadata checks passed'
