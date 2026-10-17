# SEC-005 — Edge node disk encryption

*Written 2026-10-16. Implements `NW-010` in [17-next-work.md](../../vektor-docs/docs/17-next-work.md) and closes the one Phase 7 roadmap task that was never attempted (`09-roadmap.md`, SEC-005).*

Scripts: [`luks-provision-data-volume.sh`](../scripts/luks-provision-data-volume.sh) · [`luks-health-check.sh`](../scripts/luks-health-check.sh) · [`luks-rotate-key.sh`](../scripts/luks-rotate-key.sh)

---

## The question this answers

An edge node is a box left in a field, a vehicle, or a disaster zone. Every serious buyer in every vertical asks the same question about it, usually within the first hour: **what happens when it's captured or stolen?**

Before this, the honest answer was "everything on it is readable." §14.1 listed physical compromise as a risk with LUKS as the mitigation, and the mitigation didn't exist.

## Threat model

What we are defending against, specifically:

| Threat | Covered? | By what |
|---|---|---|
| Node is stolen powered-off; attacker pulls the disk and reads it elsewhere | **Yes** | LUKS2 on the data volume |
| Node is stolen powered-off; attacker boots it in a modified boot chain to dump the disk | **Yes**, in `tpm2` mode | PCR 7+11 policy — the key does not unseal for a different kernel/initrd |
| Attacker reads k8s Secrets out of the k3s datastore on a *running* node | **Partly** | `--secrets-encryption`, now enabled by `bootstrap-k3s-edge.sh` |
| Node is captured intact, powered on, with an operator session open | **No** | Nothing on disk helps here. This is a physical-security and session-timeout problem |
| Attacker has the node *and* the escrow key | **No** | By definition. See [Escrow](#escrow-the-part-people-get-wrong) |
| Cold-boot / DMA attack against keys in RAM on a running node | **No** | Out of scope; would need measured boot plus hardware we do not specify |

The middle row is the one to be honest about in a sales conversation: **disk encryption protects a powered-off node.** A node captured while running, by someone who knows what they are doing, is a different problem that no amount of LUKS solves.

## What is encrypted

Two layers, with very different cost and reversibility. The default is the cheaper one, because it covers the data that matters.

### Layer 1 (default): the data volume — LUKS2

`luks-provision-data-volume.sh` creates a LUKS2 volume mounted at `/var/lib/vektor`, and `bootstrap-k3s-edge.sh --data-dir` puts the node's state on it:

| What lives there | Why it matters if read |
|---|---|
| k3s datastore (`rancher/k3s`) | Every Kubernetes Secret on the node — cloud sync credentials, Keycloak client secrets, Kafka credentials |
| `edge-sync-svc`'s offline queue | Buffered operational events not yet synced upstream |
| `coa-svc`'s Postgres + Qdrant | The intelligence corpus and generated COAs — the operational picture itself |
| Docker data-root | Named volumes from `compose/docker-compose.edge.yml`: `postgres-data`, `qdrant-data`, `edge-sync-data`, `redis-data` |
| `models/` | The INT8 ONNX detector and the GGUF — trained IP |

Parameters: LUKS2, `aes-xts-plain64`, 512-bit key (AES-256 — XTS splits the key in two; this is not "AES-512", which does not exist), `argon2id` with a **pinned** memory cost.

> The pinned cost is deliberate. `cryptsetup`'s default derives from the RAM of whatever machine ran `luksFormat`, which is how you get a volume that enrolls fine on a 64 GB depot workstation and then cannot be unlocked by a memory-constrained initrd on the target. Pinning makes the cost a property of the volume, not of the machine that happened to create it.

ARM64 on the AGX Orin has the ARMv8 Crypto Extensions, so AES-XTS is hardware-accelerated. This is not a meaningful throughput cost on the Jetson.

### Layer 2 (opt-in): the rootfs — L4T `ROOTFS_ENC`

`flash-jetson.sh --encrypt-rootfs <ekb.key>`. **Read the warning the script prints.** Two things make this the second layer rather than the first:

1. **Without a burned KEK2 fuse, it protects nothing.** The flash succeeds, the rootfs is genuinely encrypted, and the key is NVIDIA's public development key. The node then passes every check you can run on it and is readable by anyone who has downloaded the BSP. This is a worse outcome than no encryption, because it looks like a control.
2. **Fuses are one-way.** A board whose EKB is lost after KEK2 is burned is scrap.

LUKS on the data volume needs no fuses, is reversible, and covers what an attacker actually wants. Start there.

### What is *not* encrypted, by design

The rootfs in the default configuration: the OS, the k3s binary, the container runtime. An attacker who reads it learns which software VEKTOR runs, which is in the public repositories anyway. **No credential, model or operational datum is supposed to live there** — and `luks-health-check.sh` exists to catch the cases where one does.

## Choosing an unlock mode

The genuine tension: a key that unlocks the volume without a human is a key that is present on, or reachable by, the node an attacker is holding. The right answer is a deployment decision, not a default we can pick for every node.

| Mode | Unattended reboot in the field | Resists disk-pull | Resists booting the intact node | Use when |
|---|---|---|---|---|
| `tpm2` (default where a TPM exists) | **Yes** | Yes | Yes — PCR policy refuses a tampered boot chain | The normal case: an unmanned node that must come back from a power cut on its own |
| `passphrase` | **No** — the node stays down until someone types it | Yes | Yes | Highest-sensitivity deployments where a node staying down is better than a node coming up |
| `keyfile` | Yes, while the token is present | Yes, *if* the token is removed after boot | No, if the token is left in | A node with a removable token an operator pulls after bring-up |

Not every AGX Orin **carrier board** exposes a TPM — check the carrier board, not the module. Without `/dev/tpmrm0` the provisioning script falls back to `passphrase` and says so loudly, because silently falling back to a mode that cannot reboot unattended is how a node is lost to a power cut three months later.

`tpm2` binds to **PCR 7** (secure-boot state) and **PCR 11** (systemd's kernel/initrd measurement). Expect a kernel or firmware update to change those and stop the node unsealing — that is the policy working, not a fault. Re-seal *before* the reboot:

```sh
sudo ./scripts/luks-rotate-key.sh --device /dev/nvme0n1p1 --rotate tpm2 --escrow /path/to/escrow.key
```

## Escrow: the part people get wrong

Every volume gets **two** keyslots: the unlock path above, and a 256-bit recovery key generated at provisioning time.

Non-negotiable: **the escrow key leaves the node.** Into Vault (`vektor-infra` already runs one) or a sealed envelope in a safe at the depot, then `shred -u` the copy on the node. `luks-health-check.sh` fails the node if it finds one still sitting there, because a recovery key on the disk it unlocks is not a recovery key — it is a spare key taped to the door.

The escrow key is also what makes rotation safe. `luks-rotate-key.sh` authenticates every rotation with it and verifies the new key opens the volume **before** wiping the old slot. The reverse order leaves a window where a failure makes the volume permanently unopenable, and that window has no undo.

A node with fewer than two keyslots is one cleared TPM away from total data loss. The health check treats that as a failure, not a warning.

## Runbooks

**Provision a new node** (at the depot, before it ships):

```sh
sudo ./scripts/luks-provision-data-volume.sh \
    --device /dev/nvme0n1p1 --yes-destroy-everything-on /dev/nvme0n1p1
# move the printed escrow key into Vault, then shred the local copy
sudo ./scripts/luks-health-check.sh --no-k3s-check
sudo ./scripts/bootstrap-k3s-edge.sh ./bundle        # defaults to --data-dir /var/lib/vektor
```

**Verify a node before it ships** — this is the gate, and it is the one step that catches the silent failure:

```sh
sudo ./scripts/luks-health-check.sh
```

The silent failure in full: the volume is encrypted, mounted and healthy, and k3s and Docker are still writing to `/var/lib/rancher` and `/var/lib/docker` on the plaintext rootfs because nothing repointed them. The node looks fully provisioned and protects nothing. The health check targets exactly this.

**After a firmware/kernel update** (TPM mode): `--rotate tpm2`, as above, before rebooting.

**Node returns from the field, treat keys as compromised:**

```sh
sudo ./scripts/luks-rotate-key.sh --device /dev/nvme0n1p1 --rotate escrow --escrow /path/to/old.key
sudo ./scripts/luks-rotate-key.sh --device /dev/nvme0n1p1 --rotate tpm2 --escrow /path/to/new.key
```

**Node is lost or presumed captured:** rotating the node's own keys does nothing for a disk already in someone else's hands. Rotate what the node *held*: its Keycloak client secret, its sync credentials, and any Kafka credentials it carried. The node's keyslots are irrelevant at that point; its credentials are not.

## What is verified, and what is not

Being precise about this, because "we have disk encryption" is exactly the kind of claim that gets repeated in a sales deck well past what was actually tested.

**Verified**, by [`tests/luks/luks-integration-test.sh`](../tests/luks/luks-integration-test.sh) — a real LUKS2 volume on a loopback device against real `cryptsetup` 2.7.0, run in CI on every PR (`.github/workflows/ci.yml`, job `luks-sec005`), **20/20 assertions passing**:

- Header is LUKS2 with `aes-xts-plain64`, a 512-bit key and `argon2id`
- Exactly two keyslots enrol; **both** the escrow key and the unlock key really open the volume, and an unrelated key is rejected
- `crypttab` references the LUKS UUID rather than a device path, and `fstab` carries `x-systemd.requires=` so the mount cannot race ahead of the mapper device
- Re-provisioning replaces its `crypttab`/`fstab` entries instead of appending duplicates, and the pre-reformat escrow key no longer opens the volume
- The escrow key is written `0400`
- The health check **rejects** an unencrypted directory — a check that passes everything is worse than no check
- The provisioner refuses to format without `--yes-destroy-everything-on`, and refuses when the confirmation device does not match

**Not verified — needs the physical board.** No GPU and no Jetson has existed in any environment this was built in (`NW-012`), and these are listed for the nightly runner in [`tests/hardware-in-the-loop/README.md`](../tests/hardware-in-the-loop/README.md):

- TPM2 sealing and PCR 7+11 unsealing across a real reboot
- L4T `ROOTFS_ENC` flashing, and the KEK2 fuse path
- AES-XTS throughput on the Orin's ARMv8 Crypto Extensions under real ingest load
- Unattended cold-boot recovery: power cut → node returns to a running cluster with no operator present

A loopback file is not a Jetson. What the test proves is that the provisioning logic, the key handling and the boot wiring are correct; what it cannot prove is that the hardware behaves as its datasheet says.

## Related

- `14-sec004-security-audit.md` §6 — the red-team step that was waiting on this: *"attempt to extract credentials/data from a captured edge node once SEC-005 exists; confirm the offline-sync intake queue doesn't leak unencrypted sensitive data to disk outside the encrypted volume."* That exercise is now runnable.
- §11.4's Samsung T7 Shield and its "AES-256 hardware encryption": **not a substitute.** It is unlocked by the drive's own firmware against a password the host supplies, it has no published independent audit, and it is outside anything this repo can verify. Second layer, never the first.
