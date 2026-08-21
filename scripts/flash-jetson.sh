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
set -euo pipefail

L4T_DIR="${1:?Usage: flash-jetson.sh <l4t-bsp-dir> [board-config]}"
BOARD_CONFIG="${2:-jetson-agx-orin-devkit-industrial}"

if [[ ! -x "${L4T_DIR}/flash.sh" ]]; then
  echo "error: ${L4T_DIR}/flash.sh not found — did you extract the L4T BSP there?" >&2
  exit 1
fi

echo "==> Verifying the Jetson is visible in recovery mode over USB"
if ! lsusb | grep -q "0955:"; then # NVIDIA vendor ID
  echo "error: no NVIDIA device found on USB. Is the board in Force Recovery Mode?" >&2
  exit 1
fi

echo "==> Flashing ${BOARD_CONFIG} (this takes 10-20 minutes, do not disconnect USB)"
cd "${L4T_DIR}"
sudo ./flash.sh "${BOARD_CONFIG}" mmcblk0p1

echo "==> Flash complete. First boot will run the Ubuntu OEM setup — create the"
echo "    local admin account, then run bootstrap-k3s-edge.sh."
