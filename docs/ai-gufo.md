# `ai.gufo` — gufo inference container (rootless podman)

Runs [gufo-org/gufo](https://github.com/gufo-org/gufo) — an
**open-source (MIT)**, OpenAI-compatible local inference engine for AMD
Strix Halo (`gfx1151`) — as a **rootless** podman container under a
systemd *user* service. The image comes from
[gufo-org/toolboxes](https://github.com/gufo-org/toolboxes), built from
pinned Nix derivations.

This is the open counterpart to the closed
[`ai.halogen-flash-server`](./ai-halogen-flash-server.md). Default
model: **Qwen3.8 Flash-Next** (Unsloth `UD-Q4_K_XL`) + shared `Q8_0`
MTP predictor — the closest open analogue to `halogen-qwen3.8-flash-next`.

## ⚠ Memory contention — read before enabling

gufo, `ai.halogen-flash-server`, and `ai.comfyui` all draw from the
**same ~124 GiB unified memory pool** on a 128 GB Strix Halo. They are
**not** meant to be resident together at full size:

- halogen (118 GiB) + ComfyUI **OOMs** the box.
- gufo at full Flash-Next context behaves the same way.

**Run at most one large LLM per boot.** The aspects all default to
`enable = false`, so nothing contends until you turn it on. To run
ComfyUI for image/video generation, keep the LLM off — or point gufo's
`model` at a **smaller GGUF** that leaves room. gufo supports many
models, so a smaller target can coexist with image gen where the 118 GiB
Flash-Next cannot. (This constraint lifts with a bigger box — more RAM,
or a second "Medusa Halo" box as a separate AI host.)

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Start the container. Leave false to keep the aspect inert. |
| `image` | `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest` | Container image. Pin to `X.Y.Z` or `sha-<rev>` for reproducibility. |
| `port` | `8080` | Host port the OpenAI-compatible API is published on. |
| `apiPort` | `8080` | Container-side port gufo binds (`gufo serve --port`). |
| `modelsDir` | `ai.model-store.paths.llm` → fallback `/var/lib/ai-models/llm` | Host dir mounted **read-only** as `/models`. Defaults to the shared [`ai.model-store`](./ai-model-store.md) `llm` subdir (batteries-included sharing); falls back to the canonical path when no store is included. Pre-populated; gufo does not download. |
| `model` | `/models/qwen3.8-flash-next/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf` | Target GGUF (first shard; loader discovers the rest). |
| `speculative` | `"mtp"` | `"mtp"` (shared predictor) or `"off"` (plain AR). |
| `mtpModel` | `/models/qwen3.8-flash-next/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf` | Shared MTP predictor (used when `speculative = "mtp"`). |
| `sessions` | `1` | `gufo serve --sessions` — concurrent generations (memory cost). |
| `context` | `0` | `gufo serve --context` — per-session context; 0 = native (262144). |
| `cacheDisk` | `false` | `gufo --cache-disk` restart-safe prompt cache (in the container user's home). |
| `user` | `"gufo"` | Unprivileged service user (created: system user, `render`/`video`, linger). |
| `gib` | `null` | GTT ceiling in GiB for **standalone** hosts (`ttm pages_limit`). |
| `serveArgs` | `[]` | Extra `gufo serve` args, appended verbatim. |
| `extraOptions` | `[]` | Extra `podman run` flags, appended verbatim. |

## Usage

```nix
# your flake
inputs.deniac.url = "github:sjdevries/deniac";

# your den config
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

den.aspects.myhost.includes = [ deniac.ai.gufo ];

# activate:
den.aspects.myhost.nixos.deniac.ai.gufo.enable = true;
# standalone host — size the GTT ceiling (skip if ai.amd.strix owns it):
den.aspects.myhost.nixos.deniac.ai.gufo.gib = 124;
```

Then point any OpenAI client at `http://<host>:8080/v1`.

### Shared model store (batteries-included)

By default `modelsDir` resolves to the shared
[`ai.model-store`](./ai-model-store.md) `llm` subdir
(`deniac.ai.model-store.paths.llm`), so when you include the store the
two connect automatically — and gufo follows a custom store `root`.
Include both and gufo reads the shared tree with no override:

```nix
den.aspects.myhost.includes = [ deniac.ai.model-store deniac.ai.gufo ];
den.aspects.myhost.nixos.deniac.ai.gufo.enable = true;
# modelsDir is now <store-root>/llm — nothing else to set
```

With no store included, `modelsDir` falls back to the canonical
`/var/lib/ai-models/llm`. Override `modelsDir` for a standalone
(non-shared) layout. The same pattern drops onto any future consumer
(unsloth-desktop, …): each defaults to its store subdir.

### Pre-staging the weights

gufo has **no in-container download** (unlike halogen). Fetch the model
out-of-band into the store's `llm` dir (or your `modelsDir`) before
first start, matching the `model` / `mtpModel` layout:

```sh
hf download unsloth/Qwen3.8-Flash-Next-GGUF \
  --include "UD-Q4_K_XL/*" "MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf" \
  --local-dir /var/lib/ai-models/llm/qwen3.8-flash-next
```

The `/models` mount is always read-only, so the container opens no
outbound connections for weights.

## Rootless topology

The container runs as the unprivileged `user` (default `gufo`), created
by the aspect as a system user in the `render` and `video` groups with
**lingering** enabled, so its systemd user manager (and the service)
starts at boot. `--userns=keep-id:uid=1000,gid=1000` maps the
container's `1000:1000` to this user; `--group-add keep-groups` carries
`render`/`video` in for `/dev/kfd` and `/dev/dri`. This matches gufo's
documented rootless quickstart (needs `crun` as the OCI runtime).

> **Note:** this differs from `ai.halogen-flash-server`, which runs
> **rootful**. If you standardise the fleet on one topology, pick one
> deliberately per host.

## GTT ceiling

Same contract as the halogen aspect. On a **standalone** host, set `gib`
(e.g. `124` for a 128 GB Strix Halo) — it emits
`options ttm pages_limit=<gib*262144>`. **Do not** set `gib` on a host
that also runs `deniac.ai.amd.strix` with a `vram` profile: both write
`ttm pages_limit` to `boot.extraModprobeConfig` (`types.lines`), which
concatenates silently and resolves by module ordering. On such hosts size
the ceiling through `hardware.amd-npu.gpuMemory.ttmSizeGiB` instead.

## Provenance

Adapted from the gufo quickstart and server contract
([`docs/SERVER.md`](https://github.com/gufo-org/gufo/blob/main/docs/SERVER.md))
and the [gufo-org/toolboxes](https://github.com/gufo-org/toolboxes)
image layout, retrieved 2026-10-04. The container run line follows the
upstream rootless podman quickstart (`keep-id`, `keep-groups`, memlock);
the systemd user service, linger, firewall, and modprobe plumbing is
deniac's. Model weights are Unsloth GGUF and are not bundled.

## Tests

`flake.tests.ai-gufo` (denTest, host `igloo`): namespace export shape;
inert-by-default; enabled (podman on, rootless user service with linger
+ `render`/`video`, **read-only** `/models` mount, firewall hole);
firewall merging with host ports; `gib` → the ttm modprobe line;
**model-store wiring** (with `ai.model-store` included, `modelsDir`
resolves to the store's `llm` path and the runner mounts it read-only;
a custom store `root` propagates to gufo).
