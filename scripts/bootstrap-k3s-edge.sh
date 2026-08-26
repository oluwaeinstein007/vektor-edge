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

BUNDLE_DIR="${1:?Usage: bootstrap-k3s-edge.sh <path-to-airgap-bundle-dir>}"
K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"

if [[ ! -f "${BUNDLE_DIR}/k3s" || ! -f "${BUNDLE_DIR}/k3s-airgap-images-arm64.tar.zst" ]]; then
  echo "error: ${BUNDLE_DIR} doesn't look like a bundle from provision-offline-bundle.sh" >&2
  echo "       (expected k3s and k3s-airgap-images-arm64.tar.zst)" >&2
  exit 1
fi

echo "==> Installing k3s binary"
install -m 0755 "${BUNDLE_DIR}/k3s" /usr/local/bin/k3s

echo "==> Staging airgapped container images"
mkdir -p /var/lib/rancher/k3s/agent/images/
cp "${BUNDLE_DIR}/k3s-airgap-images-arm64.tar.zst" /var/lib/rancher/k3s/agent/images/

echo "==> Installing k3s as a single-node server (no ZTS/traefik — vektor-edge doesn't need either)"
INSTALL_K3S_SKIP_DOWNLOAD=true \
INSTALL_K3S_VERSION="${K3S_VERSION}" \
INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --write-kubeconfig-mode 644" \
"${BUNDLE_DIR}/install.sh"

echo "==> Waiting for node to be Ready"
until k3s kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  sleep 2
done

echo "==> k3s edge node ready. Deploy vektor-backend's edge-profile Helm"
echo "    releases from the same bundle next — see README.md."
