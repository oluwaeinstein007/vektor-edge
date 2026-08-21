# Hardware-in-the-loop tests

§9.8: `vektor-edge`'s CI cross-compiles ARM64 on every PR, but these tests run nightly against a physical Jetson runner — not per-PR, "too slow/expensive to gate every commit." There's no such runner wired up yet (that's real lab hardware, out of scope for a repo-scaffolding pass), so this directory documents the intended shape rather than shipping tests that can only fail today.

## What belongs here, once there's a runner

- `onnxruntime-node` GPU execution-provider check on the Jetson's actual Ampere GPU (PERF-002's edge equivalent, and the direct test for Pitfall 5 — a silent CPU fallback)
- `node-llama-cpp` load test: Mistral 7B Q4_K_M actually fits and generates within the memory budget `scripts/src/check-memory-budget.ts` enforces in CI (EDGE-002, EDGE-003)
- End-to-end: flash a test unit with `scripts/flash-jetson.sh`, bootstrap with `scripts/bootstrap-k3s-edge.sh` from an airgap bundle with the network physically disconnected, confirm the 72h-offline claim (§11.1) holds

## CI wiring (once a runner exists)

```yaml
# .github/workflows/ci.yml, a job gated on a schedule trigger, not pull_request:
hardware-in-the-loop:
  if: github.event_name == 'schedule'
  runs-on: [self-hosted, jetson-agx-orin]
  steps:
    - run: echo "TODO EDGE-002/EDGE-003 — needs the physical runner label above to exist first"
```
