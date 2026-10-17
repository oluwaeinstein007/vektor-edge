#!/usr/bin/env bash
# SEC-005: LUKS2 full-disk encryption for the edge node's data volume.
#
# Run this ONCE, at the staging depot, on the node itself, before
# bootstrap-k3s-edge.sh — see docs/sec-005-disk-encryption.md for the threat
# model and the key-management decision this script implements.
#
# THIS IS DESTRUCTIVE. It formats the target block device. It refuses to run
# without --yes-destroy-everything-on and a device that isn't mounted.
#
# Why a data volume rather than the rootfs: on a Jetson, encrypting the
# rootfs is not a cryptsetup problem at all — it is an L4T flash-time
# problem (ROOTFS_ENC + a fuse-burned KEK, see flash-jetson.sh) and burning
# fuses is irreversible. The data volume is where everything an attacker
# actually wants lives: k3s' sqlite datastore (every Kubernetes Secret on
# the node, in cleartext unless k3s --secrets-encryption is on),
# edge-sync-svc's offline intake queue, coa-svc's Postgres + Qdrant corpus,
# and the models. §11.4's storage is a Samsung T7 Shield — note that its
# "AES-256 hardware encryption" is NOT a substitute for this: it is unlocked
# by the drive's own firmware and a password the host supplies, it has no
# published independent audit, and it is outside anything this repo can
# verify. Treat it as a second layer, never the first.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: luks-provision-data-volume.sh --device <blockdev> --yes-destroy-everything-on <blockdev> [options]

Required:
  --device <blockdev>                   e.g. /dev/nvme0n1p1. The device to encrypt.
  --yes-destroy-everything-on <dev>     Must exactly match --device. Deliberate friction.

Options:
  --name <mapper-name>      dm-crypt mapper name          (default: vektor-data)
  --mount <path>            Mount point for the volume    (default: /var/lib/vektor)
  --unlock-mode <mode>      tpm2 | passphrase | keyfile   (default: tpm2 if a TPM
                            is present and usable, else passphrase)
  --keyfile <path>          Required for --unlock-mode keyfile. Should live on
                            removable media that is pulled after boot.
  --tpm2-pcrs <list>        PCR policy for tpm2 mode      (default: 7+11)
  --escrow-out <path>       Where to write the recovery key
                            (default: ./vektor-escrow-<hostname>-<date>.key)
  --allow-discards          Pass --allow-discards to LUKS. Better SSD lifetime,
                            but leaks the used/free block pattern to anyone
                            holding the powered-off disk. Off by default.
  --pbkdf-memory <kib>      argon2id memory cost          (default: 1048576 = 1GiB)
  --etc-dir <path>          Where crypttab/fstab live      (default: /etc). Point
                            it at a chroot when provisioning an image rather
                            than the running node.

Every option can also be given as an env var: VEKTOR_LUKS_DEVICE, _NAME,
_MOUNT, _UNLOCK_MODE, _KEYFILE, _TPM2_PCRS, _ESCROW_OUT, _ALLOW_DISCARDS,
_PBKDF_MEMORY.
USAGE
  exit 64
}

DEVICE="${VEKTOR_LUKS_DEVICE:-}"
CONFIRM_DEVICE=""
MAPPER_NAME="${VEKTOR_LUKS_NAME:-vektor-data}"
MOUNT_POINT="${VEKTOR_LUKS_MOUNT:-/var/lib/vektor}"
UNLOCK_MODE="${VEKTOR_LUKS_UNLOCK_MODE:-}"
KEYFILE="${VEKTOR_LUKS_KEYFILE:-}"
TPM2_PCRS="${VEKTOR_LUKS_TPM2_PCRS:-7+11}"
ESCROW_OUT="${VEKTOR_LUKS_ESCROW_OUT:-}"
ALLOW_DISCARDS="${VEKTOR_LUKS_ALLOW_DISCARDS:-0}"
# 1GiB: cryptsetup's default is derived from the RAM of whatever machine ran
# luksFormat, which is how you end up with a volume that enrolls fine on a
# 64GB depot workstation and then cannot be unlocked by a memory-constrained
# initrd on the target. Pin it so the cost is a property of the volume, not
# of the machine that happened to create it.
PBKDF_MEMORY="${VEKTOR_LUKS_PBKDF_MEMORY:-1048576}"
ETC_DIR="${VEKTOR_LUKS_ETC_DIR:-/etc}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="${2:?}"; shift 2 ;;
    --yes-destroy-everything-on) CONFIRM_DEVICE="${2:?}"; shift 2 ;;
    --name) MAPPER_NAME="${2:?}"; shift 2 ;;
    --mount) MOUNT_POINT="${2:?}"; shift 2 ;;
    --unlock-mode) UNLOCK_MODE="${2:?}"; shift 2 ;;
    --keyfile) KEYFILE="${2:?}"; shift 2 ;;
    --tpm2-pcrs) TPM2_PCRS="${2:?}"; shift 2 ;;
    --escrow-out) ESCROW_OUT="${2:?}"; shift 2 ;;
    --allow-discards) ALLOW_DISCARDS=1; shift ;;
    --pbkdf-memory) PBKDF_MEMORY="${2:?}"; shift 2 ;;
    --etc-dir) ETC_DIR="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "${DEVICE}" ]] || { echo "error: --device is required" >&2; usage; }

if [[ "${CONFIRM_DEVICE}" != "${DEVICE}" ]]; then
  echo "error: --yes-destroy-everything-on must repeat --device exactly." >&2
  echo "       This formats ${DEVICE} and everything on it is gone." >&2
  exit 64
fi

[[ "${EUID}" -eq 0 ]] || { echo "error: must run as root (cryptsetup needs it)" >&2; exit 1; }

for tool in cryptsetup blkid lsblk mkfs.ext4; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "error: ${tool} not found on PATH. On the L4T rootfs:" >&2
    echo "       apt-get install -y cryptsetup-bin e2fsprogs util-linux" >&2
    exit 1
  }
done

[[ -b "${DEVICE}" ]] || { echo "error: ${DEVICE} is not a block device" >&2; exit 1; }

# Refusing on a mounted device is not paranoia: the single most common way to
# destroy a working node is to point this at the rootfs partition because
# lsblk output was read off by one line.
if findmnt --source "${DEVICE}" >/dev/null 2>&1; then
  echo "error: ${DEVICE} is currently mounted. Unmount it first, and be certain" >&2
  echo "       it is the data disk and not the rootfs:" >&2
  findmnt --source "${DEVICE}" >&2
  exit 1
fi

if [[ -z "${UNLOCK_MODE}" ]]; then
  if [[ -c /dev/tpmrm0 ]] && command -v systemd-cryptenroll >/dev/null 2>&1; then
    UNLOCK_MODE=tpm2
  else
    UNLOCK_MODE=passphrase
    echo "note: no /dev/tpmrm0 (or no systemd-cryptenroll) — defaulting to passphrase mode." >&2
    echo "      An unattended reboot in the field will NOT come back up on its own." >&2
    echo "      See docs/sec-005-disk-encryption.md §'Choosing an unlock mode'." >&2
  fi
fi

case "${UNLOCK_MODE}" in
  tpm2)
    command -v systemd-cryptenroll >/dev/null 2>&1 || {
      echo "error: --unlock-mode tpm2 needs systemd-cryptenroll (systemd >= 248)" >&2; exit 1; }
    [[ -c /dev/tpmrm0 ]] || {
      echo "error: --unlock-mode tpm2 but no /dev/tpmrm0. Not every AGX Orin carrier" >&2
      echo "       board exposes a TPM; check the carrier board, not the module." >&2
      exit 1; }
    ;;
  passphrase) ;;
  keyfile)
    [[ -n "${KEYFILE}" && -f "${KEYFILE}" ]] || {
      echo "error: --unlock-mode keyfile needs --keyfile <existing file>" >&2; exit 1; }
    ;;
  *) echo "error: --unlock-mode must be tpm2, passphrase or keyfile" >&2; exit 64 ;;
esac

if [[ -z "${ESCROW_OUT}" ]]; then
  ESCROW_OUT="./vektor-escrow-$(hostname -s)-$(date -u +%Y%m%dT%H%M%SZ).key"
fi

echo "==> SEC-005 provisioning plan"
echo "    device       ${DEVICE}  ($(lsblk -ndo SIZE "${DEVICE}" | tr -d ' '))"
echo "    mapper       /dev/mapper/${MAPPER_NAME}"
echo "    mount        ${MOUNT_POINT}"
echo "    unlock mode  ${UNLOCK_MODE}"
echo "    escrow key   ${ESCROW_OUT}"
echo "    discards     $([[ "${ALLOW_DISCARDS}" == "1" ]] && echo "allowed (leaks free-space pattern)" || echo "disabled")"
echo

# The escrow key is generated first and enrolled as the FIRST keyslot. If the
# TPM is later cleared, the board is replaced, or someone forgets the
# passphrase, this file is the only way the node's data is ever readable
# again. It must leave the node — see the doc's escrow section.
echo "==> Generating a 256-bit recovery (escrow) key"
umask 077
ESCROW_TMP="$(mktemp)"
trap 'shred -u "${ESCROW_TMP}" 2>/dev/null || rm -f "${ESCROW_TMP}"' EXIT
dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 -w0 > "${ESCROW_TMP}"

echo "==> cryptsetup luksFormat (LUKS2, aes-xts-plain64, argon2id)"
# --key-size 512 is a 512-bit XTS key, i.e. AES-256 — XTS splits the key in
# two. This is AES-256, not AES-512, which does not exist.
cryptsetup luksFormat \
  --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --hash sha256 \
  --pbkdf argon2id \
  --pbkdf-memory "${PBKDF_MEMORY}" \
  --label VEKTOR_DATA \
  --batch-mode \
  --key-file "${ESCROW_TMP}" \
  "${DEVICE}"

echo "==> Enrolling the ${UNLOCK_MODE} unlock path as an additional keyslot"
case "${UNLOCK_MODE}" in
  tpm2)
    # PCR 7 is secure-boot state, PCR 11 is systemd's kernel/initrd
    # measurement. Binding to them means the key only unseals for THIS boot
    # chain: pulling the disk and reading it in another machine fails, and so
    # does booting a tampered initrd. It does NOT stop someone who powers the
    # intact node on — that is what the login/k8s credentials are for, and
    # why this is one layer rather than the whole answer.
    systemd-cryptenroll \
      --unlock-key-file="${ESCROW_TMP}" \
      --tpm2-device=auto \
      --tpm2-pcrs="${TPM2_PCRS}" \
      "${DEVICE}"
    ;;
  passphrase)
    echo "    You will be prompted for the passphrase to enrol now."
    cryptsetup luksAddKey --key-file "${ESCROW_TMP}" "${DEVICE}"
    ;;
  keyfile)
    cryptsetup luksAddKey --key-file "${ESCROW_TMP}" "${DEVICE}" "${KEYFILE}"
    ;;
esac

echo "==> Opening the volume and making a filesystem"
cryptsetup open --key-file "${ESCROW_TMP}" "${DEVICE}" "${MAPPER_NAME}"
mkfs.ext4 -q -L vektor-data "/dev/mapper/${MAPPER_NAME}"
mkdir -p "${MOUNT_POINT}"
mount "/dev/mapper/${MAPPER_NAME}" "${MOUNT_POINT}"

# The directory layout bootstrap-k3s-edge.sh and the compose overlay expect
# to find on the encrypted volume. Creating them here means the "is the data
# actually on the encrypted volume" question has one answer, checkable by
# luks-health-check.sh, rather than depending on what each service was
# configured with.
mkdir -p \
  "${MOUNT_POINT}/rancher/k3s" \
  "${MOUNT_POINT}/docker" \
  "${MOUNT_POINT}/edge-sync" \
  "${MOUNT_POINT}/postgres" \
  "${MOUNT_POINT}/qdrant" \
  "${MOUNT_POINT}/models"
chmod 0700 "${MOUNT_POINT}"

UUID="$(blkid -s UUID -o value "${DEVICE}")"
CRYPTTAB_OPTS="luks"
[[ "${ALLOW_DISCARDS}" == "1" ]] && CRYPTTAB_OPTS="${CRYPTTAB_OPTS},discard"
case "${UNLOCK_MODE}" in
  tpm2)       CRYPTTAB_KEY="none"; CRYPTTAB_OPTS="${CRYPTTAB_OPTS},tpm2-device=auto" ;;
  passphrase) CRYPTTAB_KEY="none" ;;
  keyfile)    CRYPTTAB_KEY="${KEYFILE}" ;;
esac

echo "==> Writing ${ETC_DIR}/crypttab and ${ETC_DIR}/fstab entries"
# Idempotent: a re-run replaces this node's entries rather than appending a
# second copy, which is what turns a reprovision into an unbootable node.
mkdir -p "${ETC_DIR}"
touch "${ETC_DIR}/crypttab" "${ETC_DIR}/fstab"
sed -i "/^${MAPPER_NAME}[[:space:]]/d" "${ETC_DIR}/crypttab"
printf '%s UUID=%s %s %s\n' "${MAPPER_NAME}" "${UUID}" "${CRYPTTAB_KEY}" "${CRYPTTAB_OPTS}" >> "${ETC_DIR}/crypttab"

sed -i "\#^/dev/mapper/${MAPPER_NAME}[[:space:]]#d" "${ETC_DIR}/fstab"
# x-systemd.requires pins the ordering that is otherwise a race: without it
# systemd is free to try the mount before cryptsetup has produced the mapper
# device, and the node comes up with an empty unencrypted directory where the
# data volume should be — which looks like data loss and is worse, because
# services will happily start writing into it.
printf '/dev/mapper/%s %s ext4 defaults,nofail,x-systemd.requires=systemd-cryptsetup@%s.service 0 2\n' \
  "${MAPPER_NAME}" "${MOUNT_POINT}" "${MAPPER_NAME}" >> "${ETC_DIR}/fstab"

systemctl daemon-reload 2>/dev/null || true

install -m 0400 "${ESCROW_TMP}" "${ESCROW_OUT}"

cat <<EOF

==> Done. ${DEVICE} is LUKS2-encrypted and mounted at ${MOUNT_POINT}.

    NEXT, AND DO NOT SKIP IT:

    1. Move ${ESCROW_OUT} OFF this node, now. Into the depot's secrets
       manager (Vault — vektor-infra already runs one) or a sealed envelope
       in a safe. A recovery key sitting on the disk it unlocks is not a
       recovery key.
         shred -u ${ESCROW_OUT}      # after it is safely elsewhere

    2. Verify:    ./scripts/luks-health-check.sh --mount ${MOUNT_POINT}
    3. Bootstrap: ./scripts/bootstrap-k3s-edge.sh <bundle> --data-dir ${MOUNT_POINT}

EOF
