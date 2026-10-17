# vektor-edge

k3s edge bootstrap, Jetson flashing/provisioning, edge Docker Compose overlays, offline map-pack build tooling, and hardware-in-the-loop tests for [VEKTOR](../vektor-docs/VEKTOR-PRD.md)'s Tactical Edge Node (§11.4). See §9.2, §9.8, Pitfall 2.

## What's here vs. what lands later

This repo is the edge node's *bootstrap and ops tooling* — get a bare Jetson to a running cluster, keep it offline-capable, generate the map data it needs. The actual application code that runs on that cluster is built and published from `vektor-backend` (services/packages) and `vektor-web` (the frontend, split out of the former `vektor-platform`); this repo only consumes those images. As of Phase 6 (EDGE-002/003/006), `coa-svc`, `cv-inference-svc`, and `edge-sync-svc` all have real Dockerfiles in `vektor-backend` (`services/*/Dockerfile`, ARM64 cross-compiled for the Jetson) — `compose/docker-compose.edge.yml` builds them locally rather than pulling a placeholder tag, since no CI/registry pipeline publishes a real `:edge-latest` yet. `field-pwa` **now exists** (corrected 2026-10-16): it is a real Vite app in `vektor-web/apps/field-pwa` with `src/lib` and `src/components`, and `vektor-web` commit `38262f2` added browser camera capture to it. This README previously said no FE-xxx task had created it; that was true when written and isn't now. Its compose entry still points at a placeholder image, so replacing that with a real build is the remaining step — see `EDGE-001` and the note in `vektor-docs/docs/16-system-status.md`.

```
scripts/
  flash-jetson.sh              Wraps NVIDIA's L4T flash.sh — see its own prerequisites section
  provision-offline-bundle.sh  Run online, once, at a staging depot — builds the airgap install bundle
  bootstrap-k3s-edge.sh        Run on the Jetson itself, fully offline, from that bundle
  luks-provision-data-volume.sh  SEC-005 — encrypts the data volume. Run once, before bootstrap
  luks-health-check.sh           SEC-005 — "is this node ACTUALLY encrypted, right now?" Ship gate
  luks-rotate-key.sh             SEC-005 — re-seal after a firmware update, rotate a compromised key
  memory-budget.json           §11.4's per-component memory budgets, machine-readable
  src/check-memory-budget.ts   EDGE-007's actual CI gate — the enforcement point Pitfall 2 promises
  tests/                       node --test suite for the above
compose/docker-compose.edge.yml  Lighter-weight alternative to full k3s, for dev-laptop testing
map-packs/build-pmtiles-pack.sh  EDGE-004 — GeoJSON -> tippecanoe -> pmtiles, one offline archive
map-packs/fixtures/area.geojson  Real fixture .github/workflows/ci.yml's map-pack-build job builds against
docs/sec-005-disk-encryption.md  SEC-005 threat model, unlock-mode decision, escrow policy, runbooks
tests/luks/                      Real LUKS2-on-loopback integration test; runs in CI, 20/20 passing
tests/hardware-in-the-loop/      Documented, not yet runnable — no physical Jetson CI runner exists yet
```

`scripts/` is TS (`@vektor/edge-scripts`), not shell — everything else in this repo's top-level `scripts/` is genuinely a shell/provisioning concern (§9.2: "Shell / TS / Ansible"), but the budget-check is real program logic, so it's built the same way as every other TS package in the project (`tsc` → `dist/`, see its own `package.json`).

## Why the bootstrap flow is two scripts, not one

`bootstrap-k3s-edge.sh` never touches the network — per §11.1, a field-deployed edge node may have zero connectivity for the entire 72h window it's rated for, so anything that `curl`s a package mid-bootstrap is a bug, not a convenience. `provision-offline-bundle.sh` does the online part once, ahead of time, at a staging depot; the resulting bundle is what actually ships to the field.

## Disk encryption (SEC-005)

An edge node is a box left in a field, a vehicle or a disaster zone, so "what happens when it's captured" is the first question every serious buyer asks. [`docs/sec-005-disk-encryption.md`](docs/sec-005-disk-encryption.md) is the full answer — threat model, what is and isn't covered, how to choose an unlock mode, and the escrow policy. The short version:

```bash
# once, at the depot, before the node ships:
sudo ./scripts/luks-provision-data-volume.sh \
    --device /dev/nvme0n1p1 --yes-destroy-everything-on /dev/nvme0n1p1
# move the printed escrow key into Vault, then shred the local copy

# the ship gate — run it before the node leaves:
sudo ./scripts/luks-health-check.sh
```

`bootstrap-k3s-edge.sh` now **refuses to bootstrap onto an unencrypted data directory** (`--allow-unencrypted` for throwaway lab nodes) and enables k3s `--secrets-encryption`. Both exist because of the same silent failure: an encrypted volume sitting next to a `/var/lib/rancher/k3s` full of cleartext Kubernetes Secrets, on a node that looks fully provisioned.

Rootfs encryption is opt-in and separate (`flash-jetson.sh --encrypt-rootfs`) — read the warning it prints before using it, because without a burned KEK2 fuse it protects nothing while looking like it does.

## Local development

```bash
./scripts/provision-offline-bundle.sh ./bundle   # online, once
# copy ./bundle to the target device, then, on that device:
sudo ./scripts/bootstrap-k3s-edge.sh ./bundle

# exercise the SEC-005 test (skips cleanly without root/cryptsetup; CI runs it real):
sudo ./tests/luks/luks-integration-test.sh

# exercise the EDGE-007 gate:
cd scripts && pnpm install && pnpm test
pnpm check-budget example-observed.json

# build the map pack fixture (needs tippecanoe + pmtiles on PATH — see
# map-packs/build-pmtiles-pack.sh's header comment for how to get both):
./map-packs/build-pmtiles-pack.sh map-packs/fixtures/area.geojson /tmp/area.pmtiles

# dev-laptop compose overlay (needs vektor-proto checked out as a sibling of
# vektor-backend — see services/*/Dockerfile's header comments for why):
export VEKTOR_EDGE_NODE_ID=dev-laptop-1
docker compose -f compose/docker-compose.edge.yml build
```
