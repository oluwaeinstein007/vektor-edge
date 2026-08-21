# vektor-edge

k3s edge bootstrap, Jetson flashing/provisioning, edge Docker Compose overlays, offline map-pack build tooling, and hardware-in-the-loop tests for [VEKTOR](../vektor-docs/VEKTOR-PRD.md)'s Tactical Edge Node (§11.4). See §9.2, §9.8, Pitfall 2.

## What's here vs. what lands later

This repo is the edge node's *bootstrap and ops tooling* — get a bare Jetson to a running cluster, keep it offline-capable, generate the map data it needs. The actual application code that runs on that cluster (edge-profile `coa-svc`, `cv-inference-svc`, `field-pwa`, IndexedDB sync — EDGE-005/EDGE-006) is built and published from `vektor-platform`; this repo only consumes those images (`compose/docker-compose.edge.yml`'s placeholder tags become real once each service's own roadmap task lands).

```
scripts/
  flash-jetson.sh              Wraps NVIDIA's L4T flash.sh — see its own prerequisites section
  provision-offline-bundle.sh  Run online, once, at a staging depot — builds the airgap install bundle
  bootstrap-k3s-edge.sh        Run on the Jetson itself, fully offline, from that bundle
  memory-budget.json           §11.4's per-component memory budgets, machine-readable
  src/check-memory-budget.ts   EDGE-007's actual CI gate — the enforcement point Pitfall 2 promises
  tests/                       node --test suite for the above
compose/docker-compose.edge.yml  Lighter-weight alternative to full k3s, for dev-laptop testing
map-packs/build-pmtiles-pack.sh  EDGE-004 — GeoJSON -> tippecanoe -> pmtiles, one offline archive
tests/hardware-in-the-loop/      Documented, not yet runnable — no physical Jetson CI runner exists yet
```

`scripts/` is TS (`@vektor/edge-scripts`), not shell — everything else in this repo's top-level `scripts/` is genuinely a shell/provisioning concern (§9.2: "Shell / TS / Ansible"), but the budget-check is real program logic, so it's built the same way as every other TS package in the project (`tsc` → `dist/`, see its own `package.json`).

## Why the bootstrap flow is two scripts, not one

`bootstrap-k3s-edge.sh` never touches the network — per §11.1, a field-deployed edge node may have zero connectivity for the entire 72h window it's rated for, so anything that `curl`s a package mid-bootstrap is a bug, not a convenience. `provision-offline-bundle.sh` does the online part once, ahead of time, at a staging depot; the resulting bundle is what actually ships to the field.

## Local development

```bash
./scripts/provision-offline-bundle.sh ./bundle   # online, once
# copy ./bundle to the target device, then, on that device:
sudo ./scripts/bootstrap-k3s-edge.sh ./bundle

# exercise the EDGE-007 gate:
cd scripts && pnpm install && pnpm test
pnpm check-budget example-observed.json
```
