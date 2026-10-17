#!/usr/bin/env bash
# EDGE-001: k3s edge node config + offline bootstrap scripts.
#
# Unlike vektor-infra's dev/prod clusters, this targets a Jetson AGX Orin
# that may be provisioning with NO internet reachable at all (§11.4: 72h
# offline is a first-class requirement, not a degraded mode) — so unlike
# vektor-infra/scripts/bootstrap-k3s-dev.sh, this does NOT `curl | sh` from
# get.k3s.io. It installs from a pre-staged airgap bundle instead. Build
# that bundle (while online, e.g. at a staging depot before field deploy)
# with provision-offline-bundle.sh in this same directory.
set -euo pipefail

BUNDLE_DIR="${1:?Usage: bootstrap-k3s-edge.sh <path-to-airgap-bundle-dir> [--data-dir <path>] [--allow-unencrypted]}"
shift
K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"

# SEC-005. k3s' default data dir is /var/lib/rancher/k3s on the plaintext
# rootfs, and its sqlite datastore holds every Kubernetes Secret on the node
# in the clear. Putting it on the LUKS volume that
# luks-provision-data-volume.sh created is the entire point of that script;
# a node bootstrapped with the default path has an encrypted volume sitting
# next to an unencrypted copy of everything worth stealing.
DATA_DIR="${VEKTOR_EDGE_DATA_DIR:-/var/lib/vektor}"
ALLOW_UNENCRYPTED="${VEKTOR_EDGE_ALLOW_UNENCRYPTED:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir) DATA_DIR="${2:?}"; shift 2 ;;
    --allow-unencrypted) ALLOW_UNENCRYPTED=1; shift ;;
    *) echo "error: unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [[ ! -f "${BUNDLE_DIR}/k3s" || ! -f "${BUNDLE_DIR}/k3s-airgap-images-arm64.tar.zst" ]]; then
  echo "error: ${BUNDLE_DIR} doesn't look like a bundle from provision-offline-bundle.sh" >&2
  echo "       (expected k3s and k3s-airgap-images-arm64.tar.zst)" >&2
  exit 1
fi

# Checking this BEFORE anything is installed: a node that gets all the way
# to a running cluster and only then reports it is unencrypted will, in
# practice, be shipped anyway.
echo "==> Checking the data directory is on an encrypted volume (SEC-005)"
DATA_SOURCE="$(findmnt -n -o SOURCE --target "${DATA_DIR}" 2>/dev/null | head -1 || true)"
DATA_ENCRYPTED=0
if [[ -n "${DATA_SOURCE}" ]]; then
  DATA_SYS="/sys/class/block/$(basename "$(readlink -f "${DATA_SOURCE}")")/dm/uuid"
  if [[ -r "${DATA_SYS}" ]] && grep -q '^CRYPT-' "${DATA_SYS}"; then
    DATA_ENCRYPTED=1
  fi
fi

if [[ "${DATA_ENCRYPTED}" -eq 1 ]]; then
  echo "    ${DATA_DIR} is on ${DATA_SOURCE} (dm-crypt) — ok"
elif [[ "${ALLOW_UNENCRYPTED}" -eq 1 ]]; then
  echo "    WARNING: ${DATA_DIR} is NOT on an encrypted volume, continuing because" >&2
  echo "             --allow-unencrypted was passed. Do not ship this node." >&2
else
  cat >&2 <<EOF
error: ${DATA_DIR} is not on an encrypted volume.

       Every Kubernetes Secret this node holds would be written to a
       plaintext disk, which is the exact failure SEC-005 exists to prevent.

       Provision the data volume first:
         ./scripts/luks-provision-data-volume.sh --device <blockdev> \\
             --yes-destroy-everything-on <blockdev>

       For a throwaway lab node where this genuinely does not matter, pass
       --allow-unencrypted.
EOF
  exit 1
fi

mkdir -p "${DATA_DIR}/rancher/k3s"

echo "==> Installing k3s binary"
install -m 0755 "${BUNDLE_DIR}/k3s" /usr/local/bin/k3s

echo "==> Staging airgapped container images"
mkdir -p /var/lib/rancher/k3s/agent/images/
cp "${BUNDLE_DIR}/k3s-airgap-images-arm64.tar.zst" /var/lib/rancher/k3s/agent/images/

echo "==> Installing k3s as a single-node server (no ZTS/traefik — vektor-edge doesn't need either)"
# --secrets-encryption is defence in depth alongside LUKS, not a duplicate of
# it: LUKS protects a powered-off disk that has been pulled or stolen, while
# secrets-encryption protects the datastore from anything able to read files
# on a node that is running. A captured node is usually one or the other,
# rarely neither.
INSTALL_K3S_SKIP_DOWNLOAD=true \
INSTALL_K3S_VERSION="${K3S_VERSION}" \
INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --write-kubeconfig-mode 644 --secrets-encryption --data-dir ${DATA_DIR}/rancher/k3s" \
"${BUNDLE_DIR}/install.sh"

echo "==> Waiting for node to be Ready"
until k3s kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  sleep 2
done

echo "==> Verifying SEC-005 end to end on the running node"
if [[ -x "$(dirname "${BASH_SOURCE[0]}")/luks-health-check.sh" ]]; then
  "$(dirname "${BASH_SOURCE[0]}")/luks-health-check.sh" --mount "${DATA_DIR}" || {
    echo "warning: the SEC-005 health check did not pass — see above before shipping this node." >&2
  }
fi

echo "==> k3s edge node ready (data dir ${DATA_DIR}/rancher/k3s, secrets encrypted at rest)."
echo "    Deploy vektor-backend's edge-profile Helm releases from the same"
echo "    bundle next — see README.md."
