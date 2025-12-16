#!/bin/bash
#
# Copyright (C) 2025 Venkata Atchuta Bheemeswara Sarma Darbha
# SPDX-License-Identifier: Apache-2.0
#
# Create an RK3588 GPT AOSP image for Kinhank X5 Pro with super.img dynamic partitions
# - Writes U-Boot at sector 64
# - Creates GPT with named partitions matching Kinhank stock firmware layout
# - Copies boot.img and super.img (dynamic partitions)
# - Creates metadata/userdata ext4 and sets proper GPT & fs labels
# - Uses kpartx to map partitions and cleans up reliably
#
set -euo pipefail
IFS=$'\n\t'

# Helper: print error and cleanup
exit_with_error() {
  echo "ERROR: $*" >&2
  cleanup || true
  exit 1
}

cleanup() {

  if [ -n "${LOOPDEV:-}" ]; then
    if sudo kpartx -l "${IMAGE_PATH}" >/dev/null 2>&1; then
      sudo kpartx -d "${IMAGE_PATH}" || true
    fi
  fi
}

trap cleanup EXIT


: "${TARGET_PRODUCT:?TARGET_PRODUCT environment variable is not set. Run lunch first.}"
: "${ANDROID_PRODUCT_OUT:?ANDROID_PRODUCT_OUT environment variable is not set. Run lunch first.}"


# Check for required partition images (super.img is auto-generated with dynamic partitions)
for PART in boot super; do
  if [ ! -f "${ANDROID_PRODUCT_OUT}/${PART}.img" ]; then
    exit_with_error "Missing partition image: ${ANDROID_PRODUCT_OUT}/${PART}.img — run 'make bootimage systemimage vendorimage productimage' to generate super.img"
  fi
done

UBOOT_BIN=device/opi/opi5_pro-kernel/u-boot-rockchip.bin
if [ ! -f "${UBOOT_BIN}" ]; then
  exit_with_error "Missing U-Boot: ${UBOOT_BIN}"
fi

VERSION=Kinhank_X5Pro_aosp
DATE=$(date +%Y%m%d)
TARGET=$(echo "${TARGET_PRODUCT}" | sed 's/^aosp_//')
IMGNAME=${VERSION}-${DATE}-${TARGET}_super.img
IMGSIZE=19456MiB
IMAGE_PATH="${ANDROID_PRODUCT_OUT}/${IMGNAME}"

if [ -f "${IMAGE_PATH}" ]; then
  exit_with_error "${IMAGE_PATH} already exists!"
fi

echo "Creating image file ${IMAGE_PATH} (${IMGSIZE})..."
sudo fallocate -l "${IMGSIZE}" "${IMAGE_PATH}"
sync

echo "Writing U-Boot to sector 64..."
# write u-boot binary to offset 64*512 = sector 64
sudo dd if="${UBOOT_BIN}" of="${IMAGE_PATH}" seek=64 bs=512 conv=notrunc status=progress
sync

echo "Partitioning image using sfdisk (GPT) with explicit partition NAMES..."


# Partition layout matching Kinhank X5 Pro stock firmware
# From stock: super partition is mmcblk2p14 with 4096000 blocks (512 bytes each) = 8192000 sectors
PART_TABLE=$(cat <<EOF
label: gpt
unit: sectors

# Partition 1: boot - 64MB (131072 sectors at 512 bytes/sector)
${IMAGE_PATH}1 : start=32768, size=131072, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="boot"

# Partition 2: super - ~4GB dynamic partition container (8192000 sectors = 4194304000 bytes)
# This contains system, system_ext, vendor, vendor_dlkm, odm, odm_dlkm, product
${IMAGE_PATH}2 : start=163840, size=8192000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="super"

# Partition 3: metadata - 16MB (32768 sectors)
${IMAGE_PATH}3 : start=8355840, size=32768, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="metadata"

# Partition 4: userdata - rest of disk
${IMAGE_PATH}4 : start=8388608, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="userdata"
EOF
)

# Use a temporary file for sfdisk input so variable interpolation is safe
echo "${PART_TABLE}" | sudo sfdisk "${IMAGE_PATH}"
sync

echo "Mapping partitions using kpartx..."

KPARTX_OUT=$(sudo kpartx -av "${IMAGE_PATH}")
echo "${KPARTX_OUT}"

LOOPDEV=$(echo "${KPARTX_OUT}" | awk '/add map/ {dev=$3} END { sub(/p[0-9]+$/, "", dev); print dev }')
if [ -z "${LOOPDEV}" ]; then
  exit_with_error "kpartx failed to map partitions or to return a loop device name."
fi
echo "Mapped image as /dev/mapper/${LOOPDEV}p* (base loop: ${LOOPDEV})"

# Wait for device nodes to appear
sleep 1
if [ ! -b "/dev/mapper/${LOOPDEV}p1" ]; then
  echo "Waiting a bit longer for /dev/mapper/${LOOPDEV}p1 to appear..."
  sleep 1
fi
if [ ! -b "/dev/mapper/${LOOPDEV}p1" ]; then
  exit_with_error "Device mapper nodes not found (e.g. /dev/mapper/${LOOPDEV}p1). Check kpartx output."
fi

# --- Copy images into partitions ---
echo "Writing boot image to p1..."
sudo dd if="${ANDROID_PRODUCT_OUT}/boot.img" of="/dev/mapper/${LOOPDEV}p1" bs=1M conv=notrunc status=progress

echo "Writing super.img to p2 (contains system/vendor/product/etc dynamic partitions)..."
# super.img contains all dynamic partitions: system, system_ext, vendor, vendor_dlkm, odm, odm_dlkm, product
sudo dd if="${ANDROID_PRODUCT_OUT}/super.img" of="/dev/mapper/${LOOPDEV}p2" bs=1M conv=notrunc status=progress

sync

# --- Create metadata and userdata filesystems ---
# Note: super partition (p2) already contains a complete super.img with dynamic partition metadata
# We don't try to label it - it has its own internal structure managed by lpmake
echo "Creating metadata and userdata partitions..."

# Create/format metadata and userdata partitions
sudo mkfs.ext4 -F -L metadata "/dev/mapper/${LOOPDEV}p3"
sudo mkfs.ext4 -F -L userdata "/dev/mapper/${LOOPDEV}p4"
sync

# Final sanity: list by-name symlinks
echo "Partition mapping summary (kpartx):"
sudo ls -l /dev/mapper/"${LOOPDEV}"* || true

# Unmap now that we have set labels
sudo kpartx -d "${IMAGE_PATH}" || true
# fix ownership
sudo chown "${USER}:${USER}" "${IMAGE_PATH}"

echo "✅ Created ${IMAGE_PATH} with super.img dynamic partitions for Kinhank X5 Pro."
echo "Partitions: boot, super (4GB with system/vendor/product/etc), metadata, userdata"
echo "You can now write this image to your SD/eMMC/NVMe and boot on Kinhank X5 Pro."


sudo sgdisk -p "${IMAGE_PATH}"
exit 0
