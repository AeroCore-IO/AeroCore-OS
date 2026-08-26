#!/usr/bin/env bash

set -euo pipefail

target_root=${1:?usage: configure-target-gpt-root.sh TARGET_ROOT}

source_device="$(findmnt --nofsroot -no SOURCE --target "${target_root}")"
# For a Btrfs subvolume, findmnt decorates the backing device with the
# subvolume path (for example, /dev/vda3[/root]).  lsblk and the partition
# validation below require the undecorated block-device path.
source_device="${source_device%%\[*}"
# Anaconda can bind-mount the target at /mnt/sysroot.  In that case findmnt's
# human-readable SOURCE is "root", even though the mounted filesystem still
# has the real target partition's device number.  Resolve that number through
# lsblk before requiring a partition-backed source.
if [[ ! "${source_device}" =~ ^/dev/ ]]; then
  source_maj_min="$(findmnt -no MAJ:MIN --target "${target_root}")"
  source_device="$(lsblk -nrpo NAME,MAJ:MIN | awk -v wanted="${source_maj_min}" '$2 == wanted { print $1; exit }')"
fi

case "${source_device}" in
  /dev/*[0-9]) ;;
  *)
    echo "Could not resolve a partition-backed target root: ${source_device}" >&2
    exit 1
    ;;
esac

parent_device="$(lsblk -no PKNAME "${source_device}")"
partition_number="$(lsblk -no PARTN "${source_device}")"
if [[ -z "${parent_device}" || -z "${partition_number}" ]]; then
  echo "Could not resolve parent disk and partition number for ${source_device}" >&2
  exit 1
fi

disk="/dev/${parent_device}"
root_type_guid="4f68bce3-e8cd-4db1-96e7-fbcaf984b709"
echo "Setting ${source_device} (partition ${partition_number} on ${disk}) to GPT root-x86-64 type ${root_type_guid}"
sgdisk --typecode="${partition_number}:${root_type_guid}" "${disk}"
partprobe "${disk}" || true
