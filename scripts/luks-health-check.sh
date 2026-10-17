#!/usr/bin/env bash
# SEC-005 verification gate: does this node ACTUALLY have its data on an
# encrypted volume, right now?
#
# This exists because "we ran the LUKS script" and "the data is encrypted"
# are different statements, and the gap between them is silent. The failure
# this is really built to catch: the encrypted volume is present, mounted and
# healthy, and k3s/docker are still writing to /var/lib/rancher and
# /var/lib/docker on the plaintext rootfs, because nothing ever repointed
# them. The node looks fully provisioned and protects nothing.
#
# Safe to run repeatedly on a live node — it only reads. Exits non-zero on
# the first real failure so it can gate the nightly hardware-in-the-loop run
# (tests/hardware-in-the-loop/README.md) and a pre-deployment depot check.
set -euo pipefail

MOUNT_POINT="${VEKTOR_LUKS_MOUNT:-/var/lib/vektor}"
MAPPER_NAME="${VEKTOR_LUKS_NAME:-vektor-data}"
STRICT_K3S=1

usage() {
  cat >&2 <<'USAGE'
Usage: luks-health-check.sh [--mount <path>] [--name <mapper>] [--no-k3s-check]

  --mount <path>    Encrypted data mount to verify   (default: /var/lib/vektor)
  --name <mapper>   Expected dm-crypt mapper name    (default: vektor-data)
  --no-k3s-check    Skip the k3s/docker data-root checks. For a depot node
                    provisioned but not yet bootstrapped.
USAGE
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mount) MOUNT_POINT="${2:?}"; shift 2 ;;
    --name) MAPPER_NAME="${2:?}"; shift 2 ;;
    --no-k3s-check) STRICT_K3S=0; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

FAILURES=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }

echo "==> SEC-005 disk-encryption health check ($(hostname -s), $(date -u +%Y-%m-%dT%H:%M:%SZ))"
echo

echo "Data volume"
if ! findmnt -n "${MOUNT_POINT}" >/dev/null 2>&1; then
  fail "${MOUNT_POINT} is not a mount point at all — the data volume is not mounted"
  SOURCE_DEV=""
else
  SOURCE_DEV="$(findmnt -n -o SOURCE --target "${MOUNT_POINT}" | head -1)"
  pass "${MOUNT_POINT} is mounted from ${SOURCE_DEV}"
fi

# The real question is not "is there a device called vektor-data" but "is the
# thing under this mount point a dm-crypt target". A bind mount, a tmpfs or a
# plain partition that happens to carry the right name all pass a naive
# name check and encrypt nothing.
if [[ -n "${SOURCE_DEV}" ]]; then
  DM_NAME="$(basename "${SOURCE_DEV}")"
  if [[ -e "/sys/class/block/$(readlink -f "${SOURCE_DEV}" | xargs basename)/dm/uuid" ]]; then
    DM_UUID="$(cat "/sys/class/block/$(readlink -f "${SOURCE_DEV}" | xargs basename)/dm/uuid")"
    if [[ "${DM_UUID}" == CRYPT-LUKS2-* ]]; then
      pass "backing device is a LUKS2 dm-crypt target (${DM_UUID%%-*}-LUKS2)"
    elif [[ "${DM_UUID}" == CRYPT-* ]]; then
      warn "backing device is dm-crypt but not LUKS2 (${DM_UUID}) — LUKS1 or plain mode"
    else
      fail "backing device is device-mapper but NOT encrypted (${DM_UUID})"
    fi
  else
    fail "${MOUNT_POINT} is backed by ${SOURCE_DEV}, which is not a device-mapper device — THE DATA ON IT IS IN CLEARTEXT"
  fi

  if [[ "${DM_NAME}" != "${MAPPER_NAME}" ]]; then
    warn "mapper is '${DM_NAME}', expected '${MAPPER_NAME}' (fine if deliberate)"
  fi
fi

echo
echo "LUKS header"
if command -v cryptsetup >/dev/null 2>&1 && [[ "${EUID}" -eq 0 ]]; then
  BACKING="$(cryptsetup status "${MAPPER_NAME}" 2>/dev/null | awk '/device:/ {print $2}' || true)"
  if [[ -n "${BACKING}" ]]; then
    CIPHER="$(cryptsetup status "${MAPPER_NAME}" | awk '/cipher:/ {print $2}')"
    KEYSIZE="$(cryptsetup status "${MAPPER_NAME}" | awk '/keysize:/ {print $2}')"
    if [[ "${CIPHER}" == "aes-xts-plain64" ]]; then
      pass "cipher ${CIPHER}"
    else
      warn "cipher is ${CIPHER}, expected aes-xts-plain64"
    fi
    if [[ "${KEYSIZE}" -ge 512 ]]; then
      pass "keysize ${KEYSIZE} bits (AES-256 under XTS)"
    else
      warn "keysize ${KEYSIZE} bits — expected 512 for AES-256-XTS"
    fi

    SLOTS="$(cryptsetup luksDump "${BACKING}" 2>/dev/null | grep -cE '^[[:space:]]+[0-9]+: luks2' || true)"
    if [[ "${SLOTS}" -ge 2 ]]; then
      pass "${SLOTS} keyslots enrolled (unlock path + escrow recovery key)"
    elif [[ "${SLOTS}" -eq 1 ]]; then
      fail "only 1 keyslot — no recovery key. Losing the TPM or the passphrase loses the data permanently"
    else
      warn "could not read keyslots from ${BACKING}"
    fi

    if cryptsetup luksDump "${BACKING}" 2>/dev/null | grep -q 'systemd-tpm2'; then
      pass "a TPM2 keyslot is enrolled (unattended boot works)"
    else
      warn "no TPM2 keyslot — this node needs a human at every boot"
    fi

    if cryptsetup status "${MAPPER_NAME}" | grep -q 'discards'; then
      warn "discards/TRIM are enabled — free-space pattern is visible on a captured disk"
    fi
  else
    warn "cryptsetup status '${MAPPER_NAME}' returned nothing — checked by mount only"
  fi
else
  warn "skipping header checks (needs root + cryptsetup); mount-level checks above still hold"
fi

if [[ "${STRICT_K3S}" -eq 1 ]]; then
  echo
  echo "Data actually living on the encrypted volume"

  # k3s. The silent failure in full: --data-dir was never passed, so every
  # Kubernetes Secret on this node sits in /var/lib/rancher/k3s/server/db on
  # the plaintext rootfs.
  if [[ -d /var/lib/rancher/k3s ]] && ! findmnt -n --target /var/lib/rancher/k3s 2>/dev/null | grep -q "${MOUNT_POINT}"; then
    if [[ -L /var/lib/rancher/k3s ]] && [[ "$(readlink -f /var/lib/rancher/k3s)" == "${MOUNT_POINT}"* ]]; then
      pass "k3s data-dir symlinked onto the encrypted volume"
    else
      fail "/var/lib/rancher/k3s is on the rootfs, NOT on ${MOUNT_POINT} — every k8s Secret on this node is in cleartext"
    fi
  elif [[ -d "${MOUNT_POINT}/rancher/k3s" ]]; then
    pass "k3s data-dir is on the encrypted volume"
  else
    warn "no k3s data directory found yet — node not bootstrapped?"
  fi

  # k3s secrets-at-rest encryption is complementary, not redundant: LUKS
  # protects a powered-off disk, --secrets-encryption protects the datastore
  # from anything that can read files on a running node.
  if [[ -f /etc/systemd/system/k3s.service ]]; then
    if grep -q 'secrets-encryption' /etc/systemd/system/k3s.service; then
      pass "k3s --secrets-encryption is on"
    else
      fail "k3s is running without --secrets-encryption (see bootstrap-k3s-edge.sh)"
    fi
  fi

  # Docker/containerd. Named volumes from compose/docker-compose.edge.yml
  # (postgres-data, qdrant-data, edge-sync-data, redis-data) live under the
  # daemon's data-root, so if that is on the rootfs the compose profile's
  # entire database state is unencrypted no matter what this volume holds.
  if command -v docker >/dev/null 2>&1; then
    DOCKER_ROOT="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
    if [[ -z "${DOCKER_ROOT}" ]]; then
      warn "docker present but not queryable (not running, or needs root)"
    elif [[ "${DOCKER_ROOT}" == "${MOUNT_POINT}"* ]]; then
      pass "docker data-root is ${DOCKER_ROOT}"
    else
      fail "docker data-root is ${DOCKER_ROOT}, not under ${MOUNT_POINT} — every named volume (postgres-data, qdrant-data, edge-sync-data) is in cleartext"
    fi
  fi
fi

echo
echo "Key hygiene"
# An escrow key left on the node it unlocks is the single most effective way
# to undo everything above.
STRAY="$(find / -xdev -maxdepth 4 -name 'vektor-escrow-*.key' 2>/dev/null | head -5 || true)"
if [[ -n "${STRAY}" ]]; then
  fail "recovery key(s) still present ON THIS NODE — this defeats the encryption entirely:"
  while IFS= read -r stray_path; do
    printf '          %s\n' "${stray_path}"
  done <<< "${STRAY}"
  echo "          Move them to the depot secrets store, then: shred -u <path>"
else
  pass "no escrow key files left on the node"
fi

echo
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "==> PASS — SEC-005 holds on this node."
else
  echo "==> FAIL — ${FAILURES} check(s) failed. This node is not SEC-005 compliant."
fi
exit $(( FAILURES > 0 ? 1 : 0 ))
