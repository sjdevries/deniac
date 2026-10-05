# `ai.comfyui` — ComfyUI (wraps comfyui-nix)

Runs [ComfyUI](https://github.com/comfyanonymous/ComfyUI) — the
node-graph image/video generation UI — as a NixOS service by wrapping
the [comfyui-nix](https://github.com/utensils/comfyui-nix) NixOS module
(a pinned flake input) with a small `deniac.ai.comfyui` option surface
that maps onto `services.comfyui.*`.

## ⚠ Fork pin — TEMPORARY (read this)

The `comfyui-nix` flake input is **currently pinned to the `sjdevries`
fork's `feat/rocm-nightly-channel` branch**, not upstream
`utensils/comfyui-nix`:

```nix
comfyui-nix.url = "github:sjdevries/comfyui-nix/feat/rocm-nightly-channel";
```

This is deliberate: the fork carries the **rocmNightly / rocm72 wheel-channel
change** being tested on real gfx1151 hardware. **Once the upstream
rocm7.2 PR merges, re-point the input to `github:utensils/comfyui-nix`**
and drop the fork. The aspect code itself is unchanged by the re-point —
only the input URL moves.

## Why the `rocmChannel` knob exists

AMD's stable pytorch.org ROCm wheels lag new-GPU ISA support by months —
gfx1030 (5700XT), gfx1100 (7900XTX) and gfx1151 (Strix Halo) all
needed AMD's nightly channel before the stable wheels carried their ISA.
`rocmChannel` is the escape hatch:

| Value | Use |
| --- | --- |
| `rocm71` | Stable ROCm 7.1 wheels (default). |
| `rocm72` | Stable ROCm 7.2 — **first stable whose HSA runtime (Ext 1.15 + gfx11-generic ISA) runs on gfx1151**; `rocm71` SEGVs at the first kernel launch there. |
| `rocmNightly` | AMD's gfx1151 nightly wheels, for AMD GPUs ahead of any stable wheel. |

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
  rocmChannel = "rocm72";   # or "rocmNightly" ahead of stable
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

Wraps the [comfyui-nix](https://github.com/utensils/comfyui-nix) NixOS
module (currently the `sjdevries` fork for the rocmNightly/rocm72
change). The `deniac.ai.comfyui` option surface, the `rocmChannel`
mapping, and the fork-pin note are deniac's. ComfyUI model weights are
not bundled.

## Tests

`flake.tests.ai-comfyui` (denTest, host `igloo`): namespace export;
inert-by-default (wrapped service off, defaults hold); enabled with
`rocm` + `rocm72` mapping onto `services.comfyui.*`; the `rocmNightly`
escape hatch + custom user mapping through.
