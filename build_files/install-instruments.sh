#!/usr/bin/env bash

set -euo pipefail

: "${INSTRUMENTS_ENABLED:=true}"
: "${INSTRUMENTS_RELEASE_REPOSITORY:=AeroCore-IO/booster-installer}"
: "${INSTRUMENTS_VERSION:=latest}"
: "${INSTRUMENTS_RELEASE_API_BASE:=https://api.github.com}"
: "${INSTRUMENTS_SEED_ROOT:=/usr/share/aerocore-booster-release}"

if [[ "${INSTRUMENTS_ENABLED}" != "true" ]]; then
  echo "AeroCore Booster image integration is disabled"
  exit 0
fi

case "$(uname -m)" in
  x86_64 | amd64)
    asset_suffix="_linux-x86_64.tar.gz"
    ;;
  *)
    echo "Unsupported AeroCore Booster image architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

for command in curl jq sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command is unavailable: $command" >&2
    exit 1
  }
done

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

github_curl() {
  local args=(
    --fail
    --location
    --retry 3
    --retry-delay 2
    --retry-max-time 60
    --silent
    --show-error
  )

  if [[ -s /run/secrets/GITHUB_TOKEN ]]; then
    args+=(--header "Authorization: Bearer $(</run/secrets/GITHUB_TOKEN)")
  fi

  curl "${args[@]}" "$@"
}

if [[ "${INSTRUMENTS_VERSION}" == "latest" ]]; then
  release_endpoint="releases/latest"
else
  release_endpoint="releases/tags/${INSTRUMENTS_VERSION}"
fi

release_json="$workdir/release.json"
github_curl \
  "${INSTRUMENTS_RELEASE_API_BASE%/}/repos/${INSTRUMENTS_RELEASE_REPOSITORY}/${release_endpoint}" \
  --output "$release_json"

release_tag="$(jq -er '.tag_name' "$release_json")"
mapfile -t payload_assets < <(
  jq -er --arg suffix "$asset_suffix" '
    .assets[]
    | select(
        (.name | startswith("AeroCore-Booster-v"))
        or (.name | startswith("instruments-ng_v"))
      )
    | select(.name | endswith($suffix))
    | [.name, .browser_download_url]
    | @tsv
  ' "$release_json"
)

if [[ "${#payload_assets[@]}" -ne 1 ]]; then
  echo "Expected one x86_64 Booster tarball in release $release_tag, found ${#payload_assets[@]}" >&2
  exit 1
fi

IFS=$'\t' read -r asset_name asset_url <<<"${payload_assets[0]}"
checksum_name="${asset_name}.sha256"
checksum_url="$(
  jq -er --arg name "$checksum_name" \
    '.assets[] | select(.name == $name) | .browser_download_url' \
    "$release_json"
)"

archive="$workdir/$asset_name"
checksum_file="$workdir/$checksum_name"
github_curl "$asset_url" --output "$archive"
github_curl "$checksum_url" --output "$checksum_file"

expected_checksum="$(awk 'NR == 1 { print $1 }' "$checksum_file")"
actual_checksum="$(sha256sum "$archive" | awk '{ print $1 }')"
if [[ ! "$expected_checksum" =~ ^[[:xdigit:]]{64}$ ]] ||
  [[ "${actual_checksum,,}" != "${expected_checksum,,}" ]]; then
  echo "Checksum verification failed for $asset_name" >&2
  exit 1
fi

while IFS= read -r entry; do
  case "$entry" in
    /* | ../* | */../* | */..)
      echo "Unsafe path in release archive: $entry" >&2
      exit 1
      ;;
  esac
done < <(tar -tzf "$archive")

extract_dir="$workdir/extracted"
install -d "$extract_dir"
tar --extract --gzip --file "$archive" --directory "$extract_dir" \
  --no-same-owner

if [[ -d "$extract_dir/aerocore-booster-release" ]]; then
  payload="$extract_dir/aerocore-booster-release"
elif [[ -d "$extract_dir/instruments-ng-release" ]]; then
  payload="$extract_dir/instruments-ng-release"
else
  echo "Release archive does not contain a supported payload root" >&2
  exit 1
fi

required_paths=(
  install.sh
  appimage/AppRun
  appimage/AppRun.wrapped
  sidecar/hhd-input-helper.cjs
  sidecar/vendor/hhd-input-helper/instruments_hhd_input/__init__.py
  runtime/avionics
  runtime/cabin
  runtime/wing
  runtime/node/bin/node
  python-wheelhouse
  pkg/systemd/ac-avionics.service
  pkg/systemd/ac-cabin.service
  pkg/systemd/ac-wing.service
  pkg/systemd/ac-instruments.service
  scripts/check-runtime-health.cjs
  manifest.yaml
)

for path in "${required_paths[@]}"; do
  if [[ ! -e "$payload/$path" ]]; then
    echo "Required path is missing from Booster release: $path" >&2
    exit 1
  fi
done

if [[ ! -f "$payload/pkg/aerocore-booster.sh" &&
  ! -f "$payload/pkg/instruments-ng.sh" ]]; then
  echo "Booster launcher is missing from the release payload" >&2
  exit 1
fi

# Remove the first implementation's image-owned runtime when upgrading an
# existing AeroCore OS image. The release seed itself remains immutable.
rm -rf /usr/lib/aerocore-booster
rm -f /usr/bin/aerocore-booster
for unit in ac-avionics.service ac-cabin.service ac-wing.service \
  ac-instruments.service; do
  rm -f "/usr/lib/systemd/system/$unit"
done

rm -rf "$INSTRUMENTS_SEED_ROOT"
install -d -m 0755 "$INSTRUMENTS_SEED_ROOT"
cp -a "$payload/." "$INSTRUMENTS_SEED_ROOT/"

cat >"$INSTRUMENTS_SEED_ROOT/image-release" <<EOF
RELEASE_TAG=$release_tag
ASSET_NAME=$asset_name
SHA256=$actual_checksum
EOF
chmod 0644 "$INSTRUMENTS_SEED_ROOT/image-release"

systemctl enable aerocore-instruments-setup.service

echo "Seeded AeroCore Booster $release_tag from $asset_name"
