#!/usr/bin/env bash
# Builds the airgap bundle bootstrap-k3s-edge.sh installs from. Run this
# once, online, at a staging depot — not on the Jetson itself, which per
# §11.4 may never see the internet in the field.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"
OUT_DIR="${1:-./bundle}"

mkdir -p "${OUT_DIR}"
BASE_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}"

echo "==> Downloading k3s ${K3S_VERSION} (arm64) into ${OUT_DIR}"
curl -sSL -o "${OUT_DIR}/k3s" "${BASE_URL}/k3s-arm64"
curl -sSL -o "${OUT_DIR}/k3s-airgap-images-arm64.tar.zst" "${BASE_URL}/k3s-airgap-images-arm64.tar.zst"
curl -sSL -o "${OUT_DIR}/install.sh" "https://get.k3s.io"
chmod +x "${OUT_DIR}/k3s" "${OUT_DIR}/install.sh"

echo "==> Bundle ready at ${OUT_DIR}. Copy it to the Jetson (Samsung T7 Shield"
echo "    SSD per §11.4, or over the Peplink LAN before it goes fully offline)"
echo "    and run bootstrap-k3s-edge.sh <bundle-dir> there."
