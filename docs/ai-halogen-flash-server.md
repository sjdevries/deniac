# `ai.halogen-flash-server` — halogen-flash-server inference container

Runs [peonist-ai/halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) — a
containerised, OpenAI-compatible inference server for the
**halogen-qwen3.8-flash-next** model — as a rootful **podman** container under systemd.

- **Model:** 125B parameters + a 51B-parameter n-gram embedding table, 4-bit;
  **118 GiB** of weights (115 GiB checkpoint + 2.4 GiB quality sidecar +
  tokenizer). The weights repo is the only volume the container needs.
- **Hardware:** **gfx1151 (Strix Halo) only** — the build hard-rejects every
  other architecture. Designed for 128 GB unified-memory boards, where it
  effectively holds the machine ("give it a machine of its own").
- **First start:** downloads the weights from Hugging Face (the transfer
  resumes if interrupted). Afterwards the container opens **no outbound
  connections at all**.
- **API:** OpenAI-compatible Chat Completions **and** Responses API on the
  published `port` (default **8731**). The engine's own port (8730) is never
  published — its protocol has no authentication.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Start the container. Leave false to keep the aspect inert. |
| `image` | `ghcr.io/peonist-ai/halogen-flash-server:0.6.2` | Container image. API and engine must share a tag. |
| `port` | `8731` | Host port the API is published on. |
| `apiPort` | `8731` | Container-side API port (`HALOGEN_API_PORT`). |
| `modelsDir` | `/var/lib/halogen-models` | Host dir mounted as `/models` (rw when `download`, else ro). The default path is created by systemd as the service's StateDirectory. |
| `download` | `true` | Fetch the weights on first start (`HALOGEN_DOWNLOAD`). `false` = weights already in `modelsDir`, volume mounted read-only. |
| `modelRepo` | `peonist-ai/halogen-qwen3.8-flash-next` | Hugging Face repo `HALOGEN_DOWNLOAD` points at. |
| `env` | `{}` | Extra container environment (e.g. `HALOGEN_MAX_TOKENS_DEFAULT`, `HALOGEN_KV_POOL_POSITIONS`, `HALOGEN_HOST_RESERVE_GIB`, `HALOGEN_CK_OVERLAY`). |
| `gib` | `null` | GTT ceiling in GiB for **standalone** hosts (emitted as the `ttm` `pages_limit` modprobe option). See [GTT ceiling](#gtt-ceiling-gpu-memory). |
| `extraOptions` | `[]` | Extra `podman run` flags, appended verbatim (escape hatch). |

## Usage

```nix
# your flake
inputs.deniac.url = "github:sjdevries/deniac";

# your den config
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

den.aspects.myhost.includes = [ deniac.ai.halogen-flash-server ];

# activate:
den.aspects.myhost.nixos.deniac.ai.halogen-flash-server.enable = true;
```

Then point any OpenAI client at `http://<host>:8731/v1`. On first boot the
service downloads the 118 GiB model — allow hours on a slow link
(`TimeoutStartSec = infinity` is set for exactly this).

## GTT ceiling (GPU memory)

The 118 GiB weights must be *addressable*: the host's GTT ceiling (the `ttm`
`pages_limit` modprobe option) needs to exceed it. The kernel default is
~27 GB addressable — **the server will not start at that ceiling.**

- **Hosts that also run [`ai.amd.strix`](ai-amd-strix.md):** the ceiling comes
  from that aspect's `vram` profile (104 GiB for "128gb"). Raise it with a
  host-side override — a plain definition wins over the profile's
  `lib.mkDefault` leaves:

  ```nix
  den.aspects.myhost.nixos.hardware.amd-npu.gpuMemory.ttmSizeGiB = 120;
  den.aspects.myhost.nixos.hardware.amd-npu.gpuMemory.pagePoolSizeGiB = 120;
  ```

  **Do not** set this aspect's `gib` on such a host — both would define the
  same modprobe option and the eval would fail.
- **Standalone hosts (no ai.amd.strix):** `gib = 120;` emits
  `options ttm pages_limit=31457280` (120 GiB × 262144 4 KiB pages) via
  `boot.extraModprobeConfig`.

Upstream's own 128 GB row measures at 124 GiB (`amdgpu.gttsize=126976`
MiB); 120 GiB keeps a little more headroom for the OS. Note upstream also
sets `amdgpu.gttsize` alongside `ttm.pages_limit` — the ai.amd.strix line
deliberately avoids that combination (ROCm#5595), and so does `gib`.

**Do not run other large models in the same pool.** 118 GiB of weights plus
the KV pool leaves ~8 GiB of a 124 GiB board for everything else; nix-amd-ai
measures exactly this collision for ds4 + lemond ("give it a machine of its
own").

## Model download

`download = true` (default) sets `HALOGEN_DOWNLOAD` and mounts `modelsDir`
read-write; the first start fetches the weights (resumable), and only the
small 2.4 GiB sidecar can ever be re-fetched (when it predates the image).
`download = false` mounts read-only and the container makes zero outbound
connections — use it after

```sh
hf download peonist-ai/halogen-qwen3.8-flash-next --local-dir /var/lib/halogen-models
```

## Leaves the aspect sets

| Path | Value | Priority |
| --- | --- | --- |
| `virtualisation.podman.enable` | `true` (enables the engine + its `/etc/containers` config) | `lib.mkDefault` — a host def wins |
| `networking.firewall.allowedTCPPorts` | `[ port ]` | plain — additive (list defs concatenate), replace with `lib.mkForce` |
| `systemd.services.halogen-flash` | the service (below) | plain — sub-options merge per key (e.g. `enable = false` for installed-but-off-at-boot) |
| `boot.extraModprobeConfig` | `options ttm pages_limit=…` (only when `gib` is set) | plain — additive (lines concatenate) |

Why plain for three of four: on this nixpkgs, the module system drops a
definition whose priority loses to another module's definition of the same
option — including for list and `lines` options. Base modules
(`podman/network-socket.nix`, `udp-over-tcp.nix`, `firewall.nix`,
`network-interfaces.nix`) define `allowedTCPPorts` / `extraModprobeConfig`
plainly, so a `lib.mkDefault` here would be silently filtered out and the
port / GTT line would never reach the firewall or the kernel. Same-priority
definitions concatenate (lists, lines) or merge per key (`attrsOf`), which
is the composable behaviour wanted; `virtualisation.podman.enable` stays
`lib.mkDefault` because a host that manages podman itself should win
cleanly.

The service runs **rootful podman** (`Restart = always`,
`TimeoutStartSec = infinity`, `StateDirectory = halogen-models`) with
`SupplementaryGroups = [ render video ]` — passed into the container by
`--group-add keep-groups` for `/dev/kfd` and `/dev/dri` — plus
`--device /dev/kfd --device /dev/dri`, `--ipc=host`,
`--ulimit memlock=-1:-1`, `-p port:apiPort`, the `HALOGEN_DOWNLOAD`/`env`
flags, and the `/models` volume. `ExecStartPre` removes a leftover container
(`podman rm -f --ignore`) so an unclean stop cannot block the next start.

## Inert behaviour

With `enable = false` (default) the aspect defines nothing: no podman, no
service, no firewall hole, no modprobe option. The `gib` option is
independent of `enable` (a host may size the GTT ceiling without starting
the container).

## Host tuning (not set by the aspect)

Upstream measured host settings worth knowing about (its README "host
settings" section) — all **host-wide** decisions, so the aspect leaves them
to the host: `amd_iommu=off` (worth 13–16% of prefill, the one upstream A/B'd),
`amdgpu.vm_update_mode=0`, `amdgpu.noretry=0`, `amdgpu.sg_display=0`
(unmeasured; one unkillable-deadlock report traces to the first two — leave
them off unless you need them), and keeping the firmware UMA frame-buffer
carve-out at its minimum (a large carve-out buys nothing for this server and
costs file cache). Kernel 7.0.0+ is required (7.1.8 is the reference host);
on 6.18.x the driver refuses the read-only weight mappings the server needs.

## Provenance

Adapted from the peonist-ai/halogen-flash-server README (quickstart,
configuration, and host-settings sections), image tag `0.6.2`, retrieved
2026-09-12. The container run line follows the upstream podman quickstart
verbatim (rootful, `keep-groups`, memlock, ipc=host); the systemd service,
StateDirectory, firewall, and modprobe plumbing is deniac's.

## Tests

`flake.tests.ai-halogen-flash-server` (denTest, host `igloo`): namespace
export shape; inert-by-default; enabled (podman on, service leaves,
firewall); firewall merging with host ports; `gib` → the ttm modprobe line
(non-empty lines only, order-independent).
