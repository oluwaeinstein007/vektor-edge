# Hardware-in-the-loop tests

§9.8: `vektor-edge`'s CI cross-compiles ARM64 on every PR, but these tests run nightly against a physical Jetson runner — not per-PR, "too slow/expensive to gate every commit." There's no such runner wired up yet (that's real lab hardware, out of scope for a repo-scaffolding pass), so this directory documents the intended shape rather than shipping tests that can only fail today.

## What belongs here, once there's a runner

- `onnxruntime-node` GPU execution-provider check on the Jetson's actual Ampere GPU (PERF-002's edge equivalent, and the direct test for Pitfall 5 — a silent CPU fallback)
- `node-llama-cpp` load test: Mistral 7B Q4_K_M actually fits and generates within the memory budget `scripts/src/check-memory-budget.ts` enforces in CI (EDGE-002, EDGE-003)
- End-to-end: flash a test unit with `scripts/flash-jetson.sh`, bootstrap with `scripts/bootstrap-k3s-edge.sh` from an airgap bundle with the network physically disconnected, confirm the 72h-offline claim (§11.1) holds
- **SEC-005 (added 2026-10-16)** — the four parts of disk encryption that a loopback device cannot test. `tests/luks/luks-integration-test.sh` covers everything else and runs in CI on every PR (20/20), so these are the remainder, not the whole job. See [`docs/sec-005-disk-encryption.md`](../../docs/sec-005-disk-encryption.md):
  - TPM2 sealing against PCR 7+11, and unsealing across a real reboot. Confirm first that this carrier board exposes a TPM at all — not every AGX Orin carrier does, and the module is not the carrier.
  - L4T `ROOTFS_ENC` flashing via `flash-jetson.sh --encrypt-rootfs`, including the KEK2 fuse path. Burn fuses on a sacrificial unit only: it is one-way.
  - AES-XTS throughput on the Orin's ARMv8 Crypto Extensions under real ingest load — the claim that encryption costs nothing meaningful on this hardware is currently an inference from the ISA, not a measurement.
  - Unattended cold-boot recovery: pull power, confirm the node returns to a running cluster with no operator present. This is the one that decides whether `tpm2` mode is actually deployable, and it cannot be faked.

## CI wiring (once a runner exists)

```yaml
# .github/workflows/ci.yml, a job gated on a schedule trigger, not pull_request:
hardware-in-the-loop:
  if: github.event_name == 'schedule'
  runs-on: [self-hosted, jetson-agx-orin]
  steps:
    - run: echo "TODO EDGE-002/EDGE-003 — needs the physical runner label above to exist first"
```
