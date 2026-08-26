#!/usr/bin/env bash
# EDGE-004: Offline PMTiles map pack generation.
#
# area.geojson -> tippecanoe (vector tiles, mbtiles) -> pmtiles convert
# (single-file archive) -> the artifact FE-001's MapLibre base map and this
# repo's edge PMTiles static server both serve directly, no network needed.
#
# Requires: tippecanoe, pmtiles (go-pmtiles) on PATH. Neither is bundled
# here — both are native binaries with their own OS packaging; install via
# your platform's package manager (e.g. `brew install tippecanoe pmtiles`)
# before running this. Verified 2026-08-26 against a real fixture
# (fixtures/area.geojson, also exercised by .github/workflows/ci.yml's
# map-pack-build job): tippecanoe has no apt package or prebuilt release on
# most Linux distros — build it from source (`libsqlite3-dev`/`zlib1g-dev` +
# `make`, a few minutes); pmtiles (protomaps/go-pmtiles) does ship a static
# Linux binary release, no build needed.
set -euo pipefail

AREA_GEOJSON="${1:?Usage: build-pmtiles-pack.sh <area.geojson> <output.pmtiles> [max-zoom]}"
OUTPUT_PMTILES="${2:?Usage: build-pmtiles-pack.sh <area.geojson> <output.pmtiles> [max-zoom]}"
MAX_ZOOM="${3:-14}"

for bin in tippecanoe pmtiles; do
  command -v "$bin" >/dev/null || { echo "error: $bin not found on PATH" >&2; exit 1; }
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

MBTILES="${WORK_DIR}/area.mbtiles"

echo "==> Building vector tiles (zoom 0-${MAX_ZOOM}) from ${AREA_GEOJSON}"
tippecanoe \
  --output="${MBTILES}" \
  --maximum-zoom="${MAX_ZOOM}" \
  --minimum-zoom=0 \
  --drop-densest-as-needed \
  --force \
  "${AREA_GEOJSON}"

echo "==> Converting to a single-file PMTiles archive"
pmtiles convert "${MBTILES}" "${OUTPUT_PMTILES}"

SIZE_MB=$(du -m "${OUTPUT_PMTILES}" | cut -f1)
echo "==> Done: ${OUTPUT_PMTILES} (${SIZE_MB} MB)"
echo "    Copy it into the edge node's map-tiles volume (see compose/docker-compose.edge.yml)"
echo "    or the k3s equivalent PVC before going offline."
