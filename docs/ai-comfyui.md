# `ai.comfyui` — ComfyUI (wraps comfyui-nix)

Runs [ComfyUI](https://github.com/comfyanonymous/ComfyUI) — the
node-graph image/video generation UI — as a NixOS service by wrapping
the [comfyui-nix](https://github.com/utensils/comfyui-nix) NixOS module
(a pinned flake input) with a small `deniac.ai.comfyui` option surface
that maps onto `services.comfyui.*`.

## Pin — upstream (migrated 2026-11-08)

The `comfyui-nix` flake input points at **upstream
`github:utensils/comfyui-nix`**:

```nix
comfyui-nix.url = "github:utensils/comfyui-nix";
```

This used to be the `sjdevries` fork's `feat/rocm-nightly-channel`
branch, while the `rocmChannel` change was being proven on real gfx1151
hardware. That work merged upstream — **PR #112** (`rocmChannel` + the
`rocm72` wheel set) and **PR #115** (the safer attention default) — and
the pin moved back to upstream on 2026-11-08.

**One interface change came with the merge:** the fork's `rocmNightly`
value does **not** exist upstream. Upstream's `rocmChannel` enum is
exactly `"rocm71" | "rocm72"`. `rocmNightly` has been removed from the
aspect's enum to match, so passing it now fails at eval rather than
silently selecting a wheel set. For gfx1151 the answer is `rocm72`,
which is a *stable* wheel set — the nightly escape hatch is no longer
needed on Strix Halo.

## Why the `rocmChannel` knob exists

AMD's stable pytorch.org ROCm wheels lag new-GPU ISA support by months —
gfx1030 (5700XT), gfx1100 (7900XTX) and gfx1151 (Strix Halo) each
needed a newer wheel set than the then-default before the stable wheels
carried their ISA. `rocmChannel` makes that a deliberate per-host choice
rather than inheriting whatever the default happens to be:

| Value | Use |
| --- | --- |
| `rocm71` | Stable ROCm 7.1 wheels (default). |
| `rocm72` | Stable ROCm 7.2 (torch 2.14.x) — **first stable whose HSA runtime (Ext 1.15 + gfx11-generic ISA) runs on gfx1151**; `rocm71` SEGVs at the first kernel launch there. |

The enum mirrors upstream's exactly. There is no nightly value: after the
`rocm72` merge, every AMD GPU targeted here is covered by a stable wheel
set.

No effect unless `gpuSupport = "rocm"`.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Enable the ComfyUI service. |
| `gpuSupport` | `"none"` | GPU backend: `none` / `cuda` / `rocm` / `xpu`. |
| `rocmChannel` | `"rocm71"` | ROCm wheel set when `gpuSupport = "rocm"` (see table). |
| `port` | `8188` | Port ComfyUI listens on. |
| `dataDir` | `/var/lib/comfyui` | ComfyUI data dir (models, input, output, custom nodes). |
| `user` | `"comfyui"` | Account the service runs as. |
| `openFirewall` | `false` | Open the firewall for the port. |

Everything comfyui-nix offers beyond these (`extraArgs`,
`extraPythonPackages`, `customNodes`, `listenAddress`, …) can still be
set directly on the host via `services.comfyui.*`.

## Usage

```nix
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

den.aspects.igloo.includes = [ deniac.ai.comfyui ];

# a host running ComfyUI on a Strix Halo iGPU:
den.aspects.igloo.nixos.deniac.ai.comfyui = {
  enable = true;
  gpuSupport = "rocm";
  rocmChannel = "rocm72";   # gfx1151 (Strix Halo) needs >= rocm72
  user = "tux";
};
```

## Shared model store — follow-up (not yet bridged)

Unlike `ai.gufo` / `ai.unsloth` / `ai.strata` (which have a clean
model-path knob that defaults to the shared
[`ai.model-store`](./ai-model-store.md)), comfyui-nix's `dataDir` is
**monolithic** — models, input, output, and custom_nodes all live under
one directory. So a clean **model-only** bridge into the store isn't
available through the current comfyui-nix interface.

Two paths for the bridge (deliberately deferred):
- **Coarse:** point `dataDir` at the store root — one shared tree, but
  disposable output/input land in the archive mount too.
- **Clean:** needs a comfyui-nix-side model-path / `extra_model_paths.yaml`
  option so ComfyUI's model categories map onto the store's subdirs
  (`image` / `video` / `loras` / `vae` / `text_encoders`) without
  dragging output along.

This is the piece that ties into the broader "Stability-Matrix-style"
shared-model goal — see the model-store doc.

## Provenance

Wraps the upstream [comfyui-nix](https://github.com/utensils/comfyui-nix)
NixOS module. The `rocmChannel` + `rocm72` wheel-set work and the safer
attention default originated on a `sjdevries` fork for gfx1151 hardware
validation and **merged upstream in PRs #112 and #115**; the deniac input
was re-pointed to upstream on 2026-11-08 and the option surface verified
against upstream `main` the same day. The `deniac.ai.comfyui` option
surface and the `rocmChannel` mapping are deniac's. ComfyUI model weights
are not bundled.

## Tests

`flake.tests.ai-comfyui` (denTest, host `igloo`): namespace export;
inert-by-default (wrapped service off, defaults hold); enabled with
`rocm` + `rocm72` mapping onto `services.comfyui.*`; custom user
mapping through; **`rocmNightly` is rejected** — this guards the
migration and goes red if the value is ever re-added to the enum without
upstream carrying it; and the `rocm72` →
`rocmUsePyTorchAttention = true` coupling holds.
