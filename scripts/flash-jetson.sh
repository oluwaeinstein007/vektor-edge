#!/usr/bin/env bash
# Flashes a Jetson AGX Orin Industrial (§11.4) from a Linux host via NVIDIA's
# L4T BSP flash.sh over USB. This wraps that tool; it does not replace it —
# see prerequisites below, most of which are physical/manual and can't be
# scripted.
#
# Prerequisites (manual, do these first):
#   1. Download & extract the Jetson Linux BSP + sample root filesystem for
#      this board's L4T version from NVIDIA's Jetson Download Center into
#      L4T_DIR (this script does not fetch it — it's gated behind NVIDIA's
#      developer program login, no anonymous URL to curl).
#   2. Put the Jetson into Force Recovery Mode (hold REC, tap RST, release
#      REC — exact button behavior is Jetson AGX Orin Industrial-carrier-
#      board-specific, check the carrier board's own manual).
#   3. Connect the Jetson to this host via USB-C.
#
# SEC-005 note — rootfs encryption is OPTIONAL here and deliberately so.
# See docs/sec-005-disk-encryption.md for why the data volume
# (luks-provision-data-volume.sh) is the default protection and this is the
# second, heavier layer.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: flash-jetson.sh <l4t-bsp-dir> [board-config] [--encrypt-rootfs <ekb.key>]

  --encrypt-rootfs <ekb.key>   Flash with L4T rootfs encryption (ROOTFS_ENC=1),
                               unlocked by the EKB derived from the board's
                               fuse-burned KEK2. READ THE WARNING THIS PRINTS
                               BEFORE USING IT — it involves burning fuses,
                               which cannot be undone.
USAGE
  exit 64
}

L4T_DIR="${1:?Usage: flash-jetson.sh <l4t-bsp-dir> [board-config] [--encrypt-rootfs <ekb.key>]}"
shift
BOARD_CONFIG="jetson-agx-orin-devkit-industrial"
EKB_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --encrypt-rootfs) EKB_KEY="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) BOARD_CONFIG="$1"; shift ;;
  esac
done

if [[ ! -x "${L4T_DIR}/flash.sh" ]]; then
  echo "error: ${L4T_DIR}/flash.sh not found — did you extract the L4T BSP there?" >&2
  exit 1
fi

echo "==> Verifying the Jetson is visible in recovery mode over USB"
if ! lsusb | grep -q "0955:"; then # NVIDIA vendor ID
  echo "error: no NVIDIA device found on USB. Is the board in Force Recovery Mode?" >&2
  exit 1
fi

if [[ -n "${EKB_KEY}" ]]; then
  [[ -f "${EKB_KEY}" ]] || { echo "error: EKB key file ${EKB_KEY} not found" >&2; exit 1; }
  [[ -x "${L4T_DIR}/tools/kernel_flash/l4t_initrd_flash.sh" ]] || {
    echo "error: rootfs encryption needs tools/kernel_flash/l4t_initrd_flash.sh," >&2
    echo "       which ships with L4T r35 and later. Plain flash.sh cannot do it." >&2
    exit 1; }

  cat >&2 <<'WARNING'

  ============================ READ THIS ============================
  L4T rootfs encryption derives its key from the board's KEK2 fuse.

  If you have NOT burned KEK2, the flash will still succeed and the
  rootfs will still be "encrypted" — with NVIDIA's default development
  key, which is public. That produces a node that looks encrypted to
  every check you can run on it and protects nothing at all against
  anyone who has read the BSP.

  If you HAVE burned KEK2: fuses are one-way. The board can never be
  returned to an unfused state, the key cannot be read back out, and a
  board whose EKB is lost is scrap. Escrow the EKB before you flash.

  This is why luks-provision-data-volume.sh is the default and this is
  the opt-in second layer: LUKS on the data volume needs no fuses, is
  reversible, and covers the data an attacker actually wants.
  ===================================================================

WARNING
  read -r -p "  Type FUSED to confirm KEK2 is burned and the EKB is escrowed: " confirm
  [[ "${confirm}" == "FUSED" ]] || { echo "aborted." >&2; exit 1; }

  echo "==> Flashing ${BOARD_CONFIG} with rootfs encryption (20-40 minutes)"
  cd "${L4T_DIR}"
  sudo ROOTFS_ENC=1 ./tools/kernel_flash/l4t_initrd_flash.sh \
    --showlogs \
    -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
    -i "${EKB_KEY}" \
    "${BOARD_CONFIG}" internal
else
  echo "==> Flashing ${BOARD_CONFIG} (this takes 10-20 minutes, do not disconnect USB)"
  echo "    Rootfs will NOT be encrypted. The data volume is protected separately"
  echo "    by scripts/luks-provision-data-volume.sh — run it after first boot."
  cd "${L4T_DIR}"
  sudo ./flash.sh "${BOARD_CONFIG}" mmcblk0p1
fi

echo "==> Flash complete. First boot will run the Ubuntu OEM setup — create the"
echo "    local admin account, then:"
echo "      1. ./scripts/luks-provision-data-volume.sh --device <data-disk> ...  (SEC-005)"
echo "      2. sudo ./scripts/bootstrap-k3s-edge.sh <bundle>"
