#!/usr/bin/env bash
# SEC-005 key rotation for an already-provisioned edge node.
#
# Three real situations this exists for, in descending order of how often
# they actually happen:
#
#   1. A kernel, initrd or firmware update changed PCR 7/11, so the TPM2
#      keyslot no longer unseals and the node stopped coming back from
#      reboots unattended. This is NOT a fault — it is the PCR policy doing
#      exactly its job. Re-enrol against the new measurements:
#        luks-rotate-key.sh --device /dev/nvme0n1p1 --rotate tpm2 --escrow <key>
#      Do it BEFORE the reboot where possible; after it, you need the escrow
#      key and physical access.
#   2. A node came back from the field and its keys should be treated as
#      compromised: rotate everything, including escrow.
#   3. Scheduled escrow rotation at the depot.
#
# Rotation here means "enrol the new key, verify it opens the volume, and
# only then wipe the old slot". The order matters: wipe-then-enrol leaves a
# window where a failure makes the volume permanently unopenable, and that
# window has no undo.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: luks-rotate-key.sh --device <blockdev> --rotate <what> --escrow <keyfile> [options]

Required:
  --device <blockdev>     The LUKS container, e.g. /dev/nvme0n1p1
  --rotate <what>         tpm2 | passphrase | keyfile | escrow
  --escrow <keyfile>      The current escrow key. Every rotation authenticates
                          with it, because it is the one key guaranteed to
                          still work when the thing being rotated is broken.

Options:
  --new-keyfile <path>    New keyfile, for --rotate keyfile
  --tpm2-pcrs <list>      PCR policy to re-seal against   (default: 7+11)
  --escrow-out <path>     Where to write the new escrow key, for --rotate escrow
  --keep-old-slot         Enrol the new key but do NOT wipe the old one. Use when
                          staging a change you cannot verify on this boot.
USAGE
  exit 64
}

DEVICE=""
ROTATE=""
ESCROW=""
NEW_KEYFILE=""
TPM2_PCRS="${VEKTOR_LUKS_TPM2_PCRS:-7+11}"
ESCROW_OUT=""
KEEP_OLD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="${2:?}"; shift 2 ;;
    --rotate) ROTATE="${2:?}"; shift 2 ;;
    --escrow) ESCROW="${2:?}"; shift 2 ;;
    --new-keyfile) NEW_KEYFILE="${2:?}"; shift 2 ;;
    --tpm2-pcrs) TPM2_PCRS="${2:?}"; shift 2 ;;
    --escrow-out) ESCROW_OUT="${2:?}"; shift 2 ;;
    --keep-old-slot) KEEP_OLD=1; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "${DEVICE}" && -n "${ROTATE}" && -n "${ESCROW}" ]] || usage
[[ "${EUID}" -eq 0 ]] || { echo "error: must run as root" >&2; exit 1; }
[[ -b "${DEVICE}" ]] || { echo "error: ${DEVICE} is not a block device" >&2; exit 1; }
[[ -f "${ESCROW}" ]] || { echo "error: escrow key ${ESCROW} not found" >&2; exit 1; }
command -v cryptsetup >/dev/null 2>&1 || { echo "error: cryptsetup not on PATH" >&2; exit 1; }

cryptsetup isLuks "${DEVICE}" || { echo "error: ${DEVICE} has no LUKS header" >&2; exit 1; }

# Fail here rather than halfway through, while the volume is still openable
# by every key it had before this script ran.
echo "==> Verifying the escrow key still opens ${DEVICE} before changing anything"
if ! cryptsetup open --test-passphrase --key-file "${ESCROW}" "${DEVICE}" 2>/dev/null; then
  echo "error: the escrow key does NOT open this volume. Refusing to rotate." >&2
  echo "       Rotating without a known-good key is how a node becomes unrecoverable." >&2
  exit 1
fi
echo "    escrow key verified"

SLOTS_BEFORE="$(cryptsetup luksDump "${DEVICE}" | grep -cE '^[[:space:]]+[0-9]+: luks2' || true)"
echo "    ${SLOTS_BEFORE} keyslots enrolled before rotation"

case "${ROTATE}" in
  tpm2)
    command -v systemd-cryptenroll >/dev/null 2>&1 || { echo "error: needs systemd-cryptenroll" >&2; exit 1; }
    [[ -c /dev/tpmrm0 ]] || { echo "error: no /dev/tpmrm0 on this node" >&2; exit 1; }
    echo "==> Re-sealing a TPM2 keyslot against PCRs ${TPM2_PCRS}"
    # --wipe-slot=tpm2 removes every existing TPM2 slot in the same
    # operation that adds the new one, which is what makes this safe to run
    # repeatedly after each firmware update without accumulating dead slots.
    # The escrow key authenticates it, so a currently-unsealable TPM slot
    # does not block its own replacement.
    if [[ "${KEEP_OLD}" -eq 1 ]]; then
      systemd-cryptenroll --unlock-key-file="${ESCROW}" --tpm2-device=auto --tpm2-pcrs="${TPM2_PCRS}" "${DEVICE}"
    else
      systemd-cryptenroll --unlock-key-file="${ESCROW}" --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="${TPM2_PCRS}" "${DEVICE}"
    fi
    echo "    re-sealed. The node will unseal on the CURRENT boot measurements only."
    ;;

  passphrase)
    echo "==> Enrolling a new passphrase (you will be prompted for the new one)"
    cryptsetup luksAddKey --key-file "${ESCROW}" "${DEVICE}"
    if [[ "${KEEP_OLD}" -eq 0 ]]; then
      echo "==> Now enter the OLD passphrase so its slot can be removed"
      echo "    (if you no longer have it, re-run with --keep-old-slot and remove"
      echo "     the slot by number with: cryptsetup luksKillSlot ${DEVICE} <n>)"
      cryptsetup luksRemoveKey "${DEVICE}"
    fi
    ;;

  keyfile)
    [[ -f "${NEW_KEYFILE}" ]] || { echo "error: --rotate keyfile needs --new-keyfile <existing file>" >&2; exit 1; }
    echo "==> Enrolling the new keyfile"
    cryptsetup luksAddKey --key-file "${ESCROW}" "${DEVICE}" "${NEW_KEYFILE}"
    if ! cryptsetup open --test-passphrase --key-file "${NEW_KEYFILE}" "${DEVICE}" 2>/dev/null; then
      echo "error: the new keyfile does not open the volume after enrolment." >&2
      echo "       Old slots left intact. Nothing was removed." >&2
      exit 1
    fi
    echo "    new keyfile verified against the volume"
    ;;

  escrow)
    [[ -n "${ESCROW_OUT}" ]] || ESCROW_OUT="./vektor-escrow-$(hostname -s)-$(date -u +%Y%m%dT%H%M%SZ).key"
    echo "==> Generating and enrolling a new escrow key"
    umask 077
    NEW_ESCROW="$(mktemp)"
    # shellcheck disable=SC2329  # invoked via the trap below, not by name
    cleanup_escrow() { shred -u "${NEW_ESCROW}" 2>/dev/null || rm -f "${NEW_ESCROW}"; }
    trap cleanup_escrow EXIT
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 -w0 > "${NEW_ESCROW}"
    cryptsetup luksAddKey --key-file "${ESCROW}" "${DEVICE}" "${NEW_ESCROW}"
    if ! cryptsetup open --test-passphrase --key-file "${NEW_ESCROW}" "${DEVICE}" 2>/dev/null; then
      echo "error: the new escrow key does not open the volume. Old escrow left intact." >&2
      exit 1
    fi
    if [[ "${KEEP_OLD}" -eq 0 ]]; then
      cryptsetup luksRemoveKey "${DEVICE}" "${ESCROW}"
      echo "    old escrow key slot removed"
    fi
    install -m 0400 "${NEW_ESCROW}" "${ESCROW_OUT}"
    echo "    new escrow key written to ${ESCROW_OUT}"
    echo
    echo "    Move it off this node and destroy the old one at the depot."
    ;;

  *) echo "error: --rotate must be tpm2, passphrase, keyfile or escrow" >&2; exit 64 ;;
esac

SLOTS_AFTER="$(cryptsetup luksDump "${DEVICE}" | grep -cE '^[[:space:]]+[0-9]+: luks2' || true)"
echo
echo "==> Rotation complete. Keyslots: ${SLOTS_BEFORE} -> ${SLOTS_AFTER}"
if [[ "${SLOTS_AFTER}" -lt 2 ]]; then
  echo "    WARNING: fewer than 2 keyslots remain. This node has no recovery path." >&2
  echo "             Enrol an escrow key before it leaves the depot." >&2
fi
echo "    Verify with: ./scripts/luks-health-check.sh"
