# `ai.strata` — Strata (service wrapper around an installed engine)

Runs [Niko1221/Strata](https://github.com/Niko1221/Strata) (MIT) —
which runs Qwen3.8-Flash-Next on a **discrete GPU** by tiering the
MoE's 24,576 experts across GPU VRAM + host RAM + SSD — as a systemd
service. **This is a wrapper around an installed engine, not a
container.**

## ⚠ Runtime reality (read first)

Strata is **not cleanly containerizable on AMD**, which shapes this
aspect:

- **Docker is NVIDIA-only.** Strata's `Dockerfile` is
  `FROM nvidia/cuda:13.0.0` with `STRATA_ENABLE_CUDA=ON`. There is
  **no AMD container image**.
- **The AMD path is a natively-compiled HIP/ROCm engine** produced by
  `setup.py` on your machine — **not packaged in nixpkgs**.
- **gfx1151 (Strix Halo) is WIP** — owner-confirmed in
  [Strata#612](https://github.com/Niko1221/Strata/issues/612):
  *"gfx1151 support … is in progress: we're working on a port for it
  now."* Until that lands, this aspect targets **discrete AMD GPUs
  (gfx1100+)**, **not** the Halo. (On the Halo, the unified-memory
  model makes Strata's VRAM↔RAM offload largely moot anyway — see the
  contributor's note in that issue; gufo/halogen own that job.)

So this aspect does **not** build or containerize the engine. It manages
a systemd service around a Strata install you create out-of-band with
`./setup.sh`, and wires the shared `ai.model-store` GGUF dir in via
`--gguf-dir`. A **pure-Nix path needs a Nix derivation** for the
compiled engine (or an upstream AMD image) — that's the missing piece.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Start the service. Inert by default. |
| `strataDir` | `/opt/strata` | Where you ran `./setup.sh` (holds `run-<model>.sh`). Installed out-of-band. |
| `model` | `IQ2_XS` | Model size → selects `run-<model>.sh` (`Q2_0`/`IQ2_XS`/`IQ3_XXS`/`IQ3_S`/`coder`). Must match a setup. |
| `ggufDir` | `ai.model-store.paths.gguf` → fallback `/var/lib/ai-models/gguf` | GGUF dir passed via `--gguf-dir`. Defaults to the shared store. |
| `port` | `8080` | OpenAI-compatible API port. |
| `host` | `127.0.0.1` | Bind address (loopback by default). |
| `user` | `strata` | Service user (created with `render`/`video` for GPU). |
| `extraArgs` | `[]` | Extra args appended to the run script. |

## Usage

**1. Install the engine out-of-band** (compiles the AMD HIP engine, lays
down `run-<model>.sh`), pointing at the shared store's GGUF:

```sh
git clone https://github.com/Niko1221/Strata /opt/strata
cd /opt/strata
./setup.sh --model IQ2_XS --gguf-dir /var/lib/ai-models/gguf --yes
```

**2. Enable the service:**

```nix
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

den.aspects.myhost.includes = [ deniac.ai.model-store deniac.ai.strata ];
den.aspects.myhost.nixos.deniac.ai.strata.enable = true;
```

The service runs `/opt/strata/run-IQ2_XS.sh --gguf-dir
<store>/gguf --port 8080 --host 127.0.0.1`. If the run script is
missing, it fails fast with the exact `setup.sh` command to run.

## Shared model store (batteries-included)

`ggufDir` defaults to the shared
[`ai.model-store`](./ai-model-store.md) `gguf` path, so the weights
live in the shared tree (downloaded once, backed up once) rather than a
private `Strata-data` folder. Strata builds its expert packs / MTP draft
layer from these at setup time. A custom store `root` propagates.

## The real target: a discrete-GPU box

Strata's whole design is the **VRAM↔RAM↔SSD split** — which is exactly
a discrete-GPU PC (e.g. an **AM4 + RX 7900 XTX**, gfx1100, with lots
of system RAM), **not** the unified-memory Halo. That's where Strata
shines and where this wrapper is meant to run. The Halo is the odd fit
(hence the WIP port and the contributor's "use gufo" redirect).

## Provenance

Runtime verified from the [Niko1221/Strata
README](https://github.com/Niko1221/Strata),
[`docs/INSTALL.md`](https://github.com/Niko1221/Strata/blob/main/docs/INSTALL.md)
(Docker = NVIDIA-only; AMD = compiled HIP/ROCm engine; `--gguf-dir`,
`--port`, `--host`, `run-<model>.sh`), the `Dockerfile`
(`FROM nvidia/cuda`), and [issue
#612](https://github.com/Niko1221/Strata/issues/612) (gfx1151 WIP),
retrieved 2026-10-04. The systemd service, service user, firewall
gating, and model-store wiring are deniac's.

## Tests

`flake.tests.ai-strata` (denTest, host `igloo`): namespace export;
inert-by-default; enabled (system service around the installed
`run-<model>.sh`, service user with `render`/`video`, store GGUF dir
wired, loopback → no firewall hole); model-store wiring (GGUF dir
follows the store `gguf` path; custom root propagates).
