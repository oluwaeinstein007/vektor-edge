#!/usr/bin/env bash
# SEC-005 integration test: runs scripts/luks-provision-data-volume.sh for
# real, against a real LUKS2 volume on a loopback device, and asserts on the
# real cryptsetup output — not on a mock.
#
# It needs root and a kernel with dm-crypt, which is exactly what a GitHub
# ubuntu-latest runner provides, so this is wired into CI rather than being
# aspirational (.github/workflows/ci.yml, job `luks-sec005`). It SKIPS
# cleanly (exit 0, loudly) on a workstation without root or cryptsetup, the
# same convention coa-svc's edge test uses for its GGUF fixture: a developer
# without the prerequisites gets a skip, CI gets a real run.
#
# A loopback file is not a Jetson. What this proves is that the provisioning
# script produces a correctly-parameterised LUKS2 volume with a working
# escrow path and idempotent crypttab/fstab handling. What it cannot prove
# is TPM2 sealing or L4T rootfs encryption — those need the real board, and
# tests/hardware-in-the-loop/README.md lists them for the nightly runner.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROVISION="${REPO_ROOT}/scripts/luks-provision-data-volume.sh"
HEALTH="${REPO_ROOT}/scripts/luks-health-check.sh"

skip() { echo "SKIP: $*" >&2; echo "      (this test needs root + cryptsetup + dm-crypt; CI runs it for real)" >&2; exit 0; }

[[ "${EUID}" -eq 0 ]] || skip "not running as root"
command -v cryptsetup >/dev/null 2>&1 || skip "cryptsetup not installed"
command -v losetup >/dev/null 2>&1 || skip "losetup not available"
modprobe dm_crypt 2>/dev/null || true
[[ -e /dev/mapper/control ]] || skip "no /dev/mapper/control — dm-crypt unavailable in this kernel"

PASSED=0
FAILED=0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  \033[32mPASS\033[0m  %s\n' "${desc}"; PASSED=$((PASSED + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s\n' "${desc}"; FAILED=$((FAILED + 1))
  fi
}
check_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if grep -qF -- "${needle}" <<< "${haystack}"; then
    printf '  \033[32mPASS\033[0m  %s\n' "${desc}"; PASSED=$((PASSED + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s\n        expected to find: %s\n' "${desc}" "${needle}"; FAILED=$((FAILED + 1))
  fi
}

WORK="$(mktemp -d)"
LOOP=""
MAPPER="vektor-test-$$"
MOUNT="${WORK}/mnt"

# shellcheck disable=SC2329  # invoked via the trap below, not by name
cleanup() {
  mountpoint -q "${MOUNT}" 2>/dev/null && umount "${MOUNT}" || true
  cryptsetup close "${MAPPER}" 2>/dev/null || true
  [[ -n "${LOOP}" ]] && losetup -d "${LOOP}" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

echo "==> Setting up a 96MiB loopback device"
# 96MiB: LUKS2's default data offset is 16MiB, ext4 needs its own minimum,
# and anything smaller makes mkfs.ext4 fail for reasons unrelated to what
# is being tested.
truncate -s 96M "${WORK}/data.img"
LOOP="$(losetup --find --show "${WORK}/data.img")"
echo "    ${LOOP}"

# keyfile mode: the only unlock mode that is fully non-interactive, so it is
# what the test exercises. tpm2 needs real hardware; passphrase needs a tty.
dd if=/dev/urandom of="${WORK}/unlock.key" bs=32 count=1 2>/dev/null
chmod 0400 "${WORK}/unlock.key"

echo "==> Running luks-provision-data-volume.sh for real"
# --pbkdf-memory 32768 (32MiB): the production default is 1GiB, which is
# correct on a 64GB Jetson and absurd on a CI runner doing this twice.
# Passing it here also exercises the flag.
"${PROVISION}" \
  --device "${LOOP}" \
  --yes-destroy-everything-on "${LOOP}" \
  --name "${MAPPER}" \
  --mount "${MOUNT}" \
  --unlock-mode keyfile \
  --keyfile "${WORK}/unlock.key" \
  --escrow-out "${WORK}/escrow.key" \
  --etc-dir "${WORK}/etc" \
  --pbkdf-memory 32768 > "${WORK}/provision.log" 2>&1 || {
    echo "provisioning script failed:" >&2; cat "${WORK}/provision.log" >&2; exit 1; }

echo
echo "LUKS2 header parameters"
DUMP="$(cryptsetup luksDump "${LOOP}")"
# Field/value are tab-separated in cryptsetup's output, so match on the
# parsed value rather than on a guessed run of whitespace.
LUKS_VERSION="$(awk -F'[[:space:]]+' '/^Version:/ {print $2; exit}' <<< "${DUMP}")"
if [[ "${LUKS_VERSION}" == "2" ]]; then
  printf '  \033[32mPASS\033[0m  %s\n' "header is LUKS2"; PASSED=$((PASSED + 1))
else
  printf '  \033[31mFAIL\033[0m  %s\n' "header version is '${LUKS_VERSION}', expected 2"; FAILED=$((FAILED + 1))
fi
check_contains "cipher is aes-xts-plain64"     "${DUMP}" "aes-xts-plain64"
check_contains "key is 512-bit (AES-256-XTS)"  "${DUMP}" "512 bits"
check_contains "PBKDF is argon2id"             "${DUMP}" "argon2id"
check_contains "volume is labelled VEKTOR_DATA" "${DUMP}" "VEKTOR_DATA"

SLOT_COUNT="$(grep -cE '^[[:space:]]+[0-9]+: luks2' <<< "${DUMP}" || true)"
if [[ "${SLOT_COUNT}" -eq 2 ]]; then
  printf '  \033[32mPASS\033[0m  %s\n' "exactly 2 keyslots: unlock path + escrow"; PASSED=$((PASSED + 1))
else
  printf '  \033[31mFAIL\033[0m  %s\n' "expected 2 keyslots, found ${SLOT_COUNT}"; FAILED=$((FAILED + 1))
fi

echo
echo "Both keys really unlock the volume"
# The assertion that matters most. An escrow key that was written to a file
# but never actually enrolled would pass every check above and leave the
# node unrecoverable the day the TPM is cleared.
umount "${MOUNT}"
cryptsetup close "${MAPPER}"
check "escrow key opens the volume" cryptsetup open --key-file "${WORK}/escrow.key" "${LOOP}" "${MAPPER}"
cryptsetup close "${MAPPER}" 2>/dev/null || true
check "unlock keyfile opens the volume" cryptsetup open --key-file "${WORK}/unlock.key" "${LOOP}" "${MAPPER}"
cryptsetup close "${MAPPER}" 2>/dev/null || true

WRONG="${WORK}/wrong.key"
dd if=/dev/urandom of="${WRONG}" bs=32 count=1 2>/dev/null
if cryptsetup open --key-file "${WRONG}" "${LOOP}" "${MAPPER}" >/dev/null 2>&1; then
  printf '  \033[31mFAIL\033[0m  %s\n' "an unrelated key opened the volume — the volume is not actually protected"; FAILED=$((FAILED + 1))
  cryptsetup close "${MAPPER}" 2>/dev/null || true
else
  printf '  \033[32mPASS\033[0m  %s\n' "an unrelated key is rejected"; PASSED=$((PASSED + 1))
fi

echo
echo "crypttab / fstab wiring"
CRYPTTAB="$(cat "${WORK}/etc/crypttab")"
FSTAB="$(cat "${WORK}/etc/fstab")"
LUKS_UUID="$(blkid -s UUID -o value "${LOOP}")"
check_contains "crypttab names the mapper"        "${CRYPTTAB}" "${MAPPER}"
check_contains "crypttab references the LUKS UUID, not the device path" "${CRYPTTAB}" "UUID=${LUKS_UUID}"
check_contains "crypttab points at the keyfile"   "${CRYPTTAB}" "${WORK}/unlock.key"
check_contains "fstab mounts the mapper"          "${FSTAB}" "/dev/mapper/${MAPPER}"
# Without x-systemd.requires, systemd may attempt the mount before the
# mapper device exists and services start writing to an empty unencrypted
# directory. See the provisioning script's comment at the fstab write.
check_contains "fstab orders the mount after cryptsetup" "${FSTAB}" "x-systemd.requires=systemd-cryptsetup@${MAPPER}.service"

echo
echo "Re-provisioning is idempotent, not additive"
# A second provisioning run must replace this node's crypttab/fstab lines.
# Appending a duplicate is how a reprovisioned node fails to boot.
"${PROVISION}" \
  --device "${LOOP}" \
  --yes-destroy-everything-on "${LOOP}" \
  --name "${MAPPER}" \
  --mount "${MOUNT}" \
  --unlock-mode keyfile \
  --keyfile "${WORK}/unlock.key" \
  --escrow-out "${WORK}/escrow2.key" \
  --etc-dir "${WORK}/etc" \
  --pbkdf-memory 32768 > "${WORK}/provision2.log" 2>&1 || {
    echo "second provisioning run failed:" >&2; cat "${WORK}/provision2.log" >&2; exit 1; }

CRYPTTAB_LINES="$(grep -c "^${MAPPER} " "${WORK}/etc/crypttab" || true)"
FSTAB_LINES="$(grep -c "^/dev/mapper/${MAPPER} " "${WORK}/etc/fstab" || true)"
if [[ "${CRYPTTAB_LINES}" -eq 1 && "${FSTAB_LINES}" -eq 1 ]]; then
  printf '  \033[32mPASS\033[0m  %s\n' "one crypttab and one fstab entry after two runs"; PASSED=$((PASSED + 1))
else
  printf '  \033[31mFAIL\033[0m  %s\n' "duplicate entries: crypttab=${CRYPTTAB_LINES} fstab=${FSTAB_LINES}"; FAILED=$((FAILED + 1))
fi

# The old escrow key must NOT open the reformatted volume — luksFormat
# generates a new master key, and a stale escrow key that still worked would
# mean the reformat did not really happen.
if cryptsetup open --key-file "${WORK}/escrow.key" "${LOOP}" "${MAPPER}" >/dev/null 2>&1; then
  printf '  \033[31mFAIL\033[0m  %s\n' "the pre-reformat escrow key still opens the volume"; FAILED=$((FAILED + 1))
  cryptsetup close "${MAPPER}" 2>/dev/null || true
else
  printf '  \033[32mPASS\033[0m  %s\n' "the pre-reformat escrow key no longer opens the volume"; PASSED=$((PASSED + 1))
fi

echo
echo "Escrow key file permissions"
ESCROW_MODE="$(stat -c '%a' "${WORK}/escrow2.key")"
if [[ "${ESCROW_MODE}" == "400" ]]; then
  printf '  \033[32mPASS\033[0m  %s\n' "escrow key is mode 0400"; PASSED=$((PASSED + 1))
else
  printf '  \033[31mFAIL\033[0m  %s\n' "escrow key is mode ${ESCROW_MODE}, expected 400"; FAILED=$((FAILED + 1))
fi

echo
echo "Health check catches an unencrypted volume"
# Point the health check at a plain directory. If it passes that, it would
# pass a node whose data volume was never encrypted at all, which makes it
# worse than no check.
PLAIN="${WORK}/plain"
mkdir -p "${PLAIN}"
if "${HEALTH}" --mount "${PLAIN}" --name "${MAPPER}" --no-k3s-check >/dev/null 2>&1; then
  printf '  \033[31mFAIL\033[0m  %s\n' "health check PASSED an unencrypted directory"; FAILED=$((FAILED + 1))
else
  printf '  \033[32mPASS\033[0m  %s\n' "health check rejects an unencrypted directory"; PASSED=$((PASSED + 1))
fi

echo
echo "Guard rails"
if "${PROVISION}" --device "${LOOP}" >/dev/null 2>&1; then
  printf '  \033[31mFAIL\033[0m  %s\n' "formatted without --yes-destroy-everything-on"; FAILED=$((FAILED + 1))
else
  printf '  \033[32mPASS\033[0m  %s\n' "refuses to format without --yes-destroy-everything-on"; PASSED=$((PASSED + 1))
fi
if "${PROVISION}" --device "${LOOP}" --yes-destroy-everything-on /dev/sdz >/dev/null 2>&1; then
  printf '  \033[31mFAIL\033[0m  %s\n' "formatted when the confirmation device did not match"; FAILED=$((FAILED + 1))
else
  printf '  \033[32mPASS\033[0m  %s\n' "refuses when the confirmation device does not match"; PASSED=$((PASSED + 1))
fi

echo
echo "==> ${PASSED} passed, ${FAILED} failed"
exit $(( FAILED > 0 ? 1 : 0 ))
