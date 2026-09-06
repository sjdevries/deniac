# `ai.amd.strix` — AMD Strix Point / Strix Halo local AI stack

A den aspect for AMD "Strix" APUs: **Strix Point** (Ryzen AI 300 series) and
**Strix Halo** (Ryzen AI Max 300). It brings up the local-AI stack documented
by the [nix-amd-ai](https://github.com/noamsto/nix-amd-ai) project, wrapped as
a single deniac aspect with two explicit knobs — *which chip* and *how much
VRAM* — so you can include it on a host and tune individual backends from
there.

When active, the aspect configures:

- the **XDNA NPU driver** (the Strix Point/Halo NPU) and the **FastFlowLM**
  inference runtime for it;
- **Lemonade** — an OpenAI-compatible local API server
  (`localhost:13305` by default) — plus **image generation** (sd-cpp backend);
- optionally, the **GPU memory (GTT) ceiling** raised to the sensible maximum
  for the board's memory size (see [VRAM ceiling](#vram-ceiling)).

The GPU backends — **ROCm** and **Vulkan** — are **on** by default (the
llamacpp/sd-cpp GPU paths); a host that wants them off overrides the relevant
leaf (see [Overrides](#overrides)). **vLLM** stays **off** by default: it is
experimental upstream, and a host opts in with `enableVllm = true` (needs
ROCm + Lemonade). The `ds4` (DeepSeek V4) server is also off by default: it
requires a model selection a host must supply, and upstream marks it Strix
Halo-only.

Everything the aspect sets sits under `hardware.amd-npu` with
`lib.mkDefault` priority, so it never wins against an explicit host definition
and never blocks you from overriding any single leaf.

## Options

Declared under `deniac.ai.amd.strix`:

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `chipset` | `nullOr (enum ["strix-point" "strix-halo"])` | `null` | Which Strix family this host is; drives the upstream `gpuTarget` (`gfx1150` / `gfx1151`). `null` leaves the whole aspect **inert** (`hardware.amd-npu` disabled). |
| `vram` | `nullOr (enum ["32gb" "64gb" "128gb"])` | `null` | The GPU-memory (GTT) ceiling — "the maximum that is sensible for AI workloads" on a board of that unified-memory size. `null` leaves the kernel default untouched. See [VRAM ceiling](#vram-ceiling). |
| `user` | `nullOr str` | `null` | The local account to run Lemonade (lemond) as. Required to activate — until both `chipset` and `user` are set, the stack stays inert. |

`chipset` and `vram` are **independent axes**: the chip family does not
follow from the RAM size (see [Chipsets](#chipsets)), and the GTT ceiling is a
sizing choice on top of an active stack. A host that sets `vram` (or `user`)
without `chipset` gets a build-time warning that the aspect is still inert.

## Chipsets

| `chipset` | Family | iGPU target | Examples | Memory sizes |
| --- | --- | --- | --- | --- |
| `strix-point` | Ryzen AI 300 | `gfx1150` | Ryzen AI 9 HX 370 (Radeon 880M) | up to 64 GB |
| `strix-halo` | Ryzen AI Max 300 | `gfx1151` | Ryzen AI Max+ 395 (Radeon 8060S) | 32 / 64 / 128 GB |

**RAM size does not determine the chip family.** Strix Halo ships in 32, 64
*and* 128 GB; a 64 GB board can be either family (and so can a 32 GB one, for
Point). Both families solder their memory (LPDDR5X), which is what makes the
unified-memory pool usable as VRAM. Pick the chipset by the CPU, not the RAM
stick count — `lscpu` / `lspci -nn | grep -i vga` will show you.

Upstream `gpuTarget` is "the host's actual iGPU" — it drives the gfx1151
CWSR-kernel warning and the default for the vLLM GPU target — so getting this
wrong on a Halo board (or a Point board) mis-targets the ROCm backends.

## VRAM ceiling

`vram` sets the **GTT pool** — how much of the unified memory the iGPU may
*address* — via the upstream `gpuMemory.ttmSizeGiB` + `gpuMemory.pagePoolSizeGiB`
pair (emitted as `ttm` `pages_limit` + `page_pool_size` modprobe options).
It raises what is addressable, not what is consumed — no power cost.

| `vram` | Sets both leaves to | Guidance |
| --- | --- | --- |
| `null` (default) | — (kernel default, ~27 GB addressable) | Already covers 17–22 GB models; upstream calls the pair a no-op on a 64 GB Strix Point host. |
| `32gb` | `24` / `24` | ≈ the kernel default; ~8 GB left for CPU/OS. |
| `64gb` | `56` / `56` | Comfortable for ~50 GB models; ~8 GB left for CPU/OS. |
| `128gb` | `120` / `120` | 75 GiB+ models. The OS margin gets thin — upstream's measured Halo host used 96 GiB ("comfortable to ~70 GB models"), 120 is the larger row of its headroom table. |

Headroom rules (from the nix-amd-ai README, which measured these on a 128 GB
Halo host):

- **Leave RAM headroom** — don't set `ttmSizeGiB` to your full physical RAM;
  the OS and CPU models still live in that pool.
- **Do not also set `amdgpu.gttsize`** (kernel modprobe) — the two collide
  (upstream cites ROCm#5595); the pair this option emits is the one place it
  should be set.
- Upstream requires `pagePoolSizeGiB <= ttmSizeGiB`; this aspect sets them
  equal, which is the configuration upstream's numbers were measured from.

### Targeting a specific model size

The enum gives sensible defaults, not the whole range. To size the pool for a
specific model, override the two leaves directly on the host (they are
`lib.mkDefault`, so a plain definition wins):

```nix
# e.g. a 70B-class model (~45-55 GB by quant, + KV/context headroom):
den.aspects.igloo.nixos.hardware.amd-npu.gpuMemory.ttmSizeGiB = 64;
den.aspects.igloo.nixos.hardware.amd-npu.gpuMemory.pagePoolSizeGiB = 64;
```

Rule of thumb: ceiling ≈ model size (quantized) + context/KV headroom, with
8–32 GiB left for the OS/CPU depending on how dedicated the box is.

## Leaves the aspect sets

With the aspect active, the `hardware.amd-npu` value is:

| Leaf | Value |
| --- | --- |
| `enable` | `true` |
| `enableNPU` | `true` |
| `enableFastFlowLM` | `true` |
| `enableLemonade` | `true` |
| `enableImageGen` | `true` (sd-cpp backend, ~150 MB — upstream default) |
| `enableROCm` / `enableVulkan` | `true` (a host can opt out) |
| `enableVllm` | `false` (host opt-in; needs ROCm + Lemonade) |
| `exclusiveInference` | `false` |
| `ds4.enable` | `false` (needs `ds4.model`; upstream: Strix Halo / gfx1151 only) |
| `gpuTarget` | `gfx1150` (`strix-point`) / `gfx1151` (`strix-halo`) |
| `gpuMemory.ttmSizeGiB` / `.pagePoolSizeGiB` | `null` (kernel default) unless `vram` is set, then `24`/`56`/`120` |
| `lemonade.user` | the aspect's `user` option |
| `lemonade.host` / `.port` | `localhost` / `13305` |
| `lemonade.autoStart` | `true` |
| `lemonade.flashAttn` | `"on"` |
| `lemonade.models` | `[ ]` (host lists models to keep downloaded) |
| `lemonade.pruneUnlistedModels` | `false` |
| `lemonade.customModels` | `{ }` |

Leaves the aspect **does not set** (upstream defaults apply; override directly
if you want): `vllmGpuTarget` (defaults to `gpuTarget`), `lemonade.cacheDir`
(`null`), `lemonade.settings` (`{}`), `lemonade.desktopApp.enable`
(`true` — set `false` on headless hosts to skip the desktop-app build),
`lemonade.allowedOrigins` (`[]`), `ds4.model` / `ds4.user`.

## Usage

```nix
# your flake
inputs.deniac.url = "github:sjdevries/deniac";

# your den config
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

den.aspects.igloo.includes = [ deniac.ai.amd.strix ];

# activate: pick the chip + the account running Lemonade, size the VRAM
den.aspects.igloo.nixos.deniac.ai.amd.strix.chipset = "strix-halo";
den.aspects.igloo.nixos.deniac.ai.amd.strix.vram    = "128gb";
den.aspects.igloo.nixos.deniac.ai.amd.strix.user    = "tux";

# optional host-side overrides (any leaf, at any depth):
den.aspects.igloo.nixos.hardware.amd-npu.enableROCm      = false;  # drop the ROCm backends
den.aspects.igloo.nixos.hardware.amd-npu.lemonade.models = [ "gpt-oss-120b" ];
```

<aside>

**Shorter form.** `den.aspects.<host>.nixos.` is den's per-host, per-class
addressing — not removable, and not redundant. At the den level, `deniac` is a
*value reference* (that's how `includes = [ deniac.ai.amd.strix ]` resolves);
the `deniac.ai.amd.strix.*` options only exist inside a NixOS evaluation. The
shortest per-host form is the function form, where the prefix appears once:

```nix
den.aspects.igloo.nixos = { ... }: {
  deniac.ai.amd.strix.chipset = "strix-halo";
  deniac.ai.amd.strix.vram    = "128gb";
  deniac.ai.amd.strix.user    = "tux";
};
```

And if the setting is host-independent, `den.default` applies it to every
host, user, and home — dropping the host name entirely:

```nix
den.default.nixos.deniac.ai.amd.strix.chipset = "strix-halo";
```

</aside>

The account in `user` must also be a member of the `video` and `render`
groups for NPU access — the nix-amd-ai module handles the driver, but group
membership is a host concern.

## Overrides

Every leaf is declared with `lib.mkDefault`, so a plain host definition wins
and only that path changes — the rest of the `hardware.amd-npu` subtree
survives. This is why the aspect spreads its value to each leaf rather than
`mkDefault`-ing one big attrset: overriding `lemonade.models` replaces just
that list, not the whole `lemonade` block.

The GPU backends are on by default; to drop one, override the leaf directly:

```nix
den.aspects.igloo.nixos.hardware.amd-npu.enableROCm = false;   # llamacpp/sd-cpp GPU backends
den.aspects.igloo.nixos.hardware.amd-npu.enableVulkan = false;
```

To turn on vLLM (off by default — experimental upstream), override the leaf:

```nix
den.aspects.igloo.nixos.hardware.amd-npu.enableVllm = true;  # needs ROCm + Lemonade
```

DeepSeek V4 server (upstream: gfx1151 / Strix Halo only, needs a model path):

```nix
den.aspects.igloo.nixos.hardware.amd-npu.ds4.enable = true;
den.aspects.igloo.nixos.hardware.amd-npu.ds4.model  = "/path/to/deepseek-v4.gguf";
```

## Kernel requirements

- **NPU**: the `amdxdna` driver needs kernel **≥ 6.14** (upstream assertion).
- **gfx1151 (Strix Halo) + ROCm backends**: kernel **≥ 6.18.4** (or the CWSR
  fix backported) — below that, ROCm can miscalculate VGPR counts and crash
  `llamacpp:rocm`, `sd-cpp:rocm`, and `vllm:rocm`. Upstream warns rather than
  asserts; if you run an older kernel, verify the backport on the host:
  `grep -E "cwsr_size|ctl_stack_size" /sys/class/kfd/kfd/topology/nodes/*/properties`.
- The NPU needs IOMMU on (`amd_iommu=off` kills it — `amdxdna` needs IOMMU for
  PASID).

## Out of scope: other AMD hardware

The aspect is scoped to the two Strix families above. For other AMD AI
hardware, use [nix-amd-ai](https://github.com/noamsto/nix-amd-ai) directly
(its GPU half is chip-independent) — or plain nixpkgs:

- **Hawk Point** (Ryzen 8000, e.g. Ryzen 9 8945HS; Radeon 780M / `gfx1103`)
  has **no XDNA-2 NPU** — set `enableNPU = false` there and use the GPU half
  (Vulkan with RADV recommended; upstream has not tested ROCm on actual Hawk
  Point hardware — the documented fallback is
  `HSA_OVERRIDE_GFX_VERSION = "11.0.0"`).
- **Krackan Point** (Ryzen AI 7 350 / 5 340, PCI `1022:17f0` rev `0x20`) has
  an XDNA-2 NPU but upstream has not been able to get it working — model load
  fails with `DRM_IOCTL_AMDXDNA_CREATE_HWCTX` (upstream #79).
- **Discrete GPU via a PCIe expander** (e.g. a Radeon 7900 XTX or RX 9700
  alongside a Ryzen APU) is a different machine shape: the NPU half of this
  aspect doesn't apply to the card, and the APU's unified-memory GTT sizing is
  the wrong lever. Drive the dGPU's ROCm stack directly; community
  experimentation with this setup (e.g. Level1Techs' Ryzen AI + dGPU
  experiments) is not what this aspect targets.

## Inert behaviour

With `chipset = null` (the default), the aspect contributes nothing to
`hardware.amd-npu`: the upstream `nix-amd-ai` module keeps its own
`enable = false` default and the required `lemonade.user` option is never
forced. This is deliberate — a host that includes the aspect but hasn't
declared its chip should not fail to build, and a host that set `vram`/`user`
by mistake gets a warning rather than a silent no-op.

## Provenance

This aspect wraps [noamsto/nix-amd-ai](https://github.com/noamsto/nix-amd-ai),
pinned at `7a739c04c33e9abf9a8ccd39fd81d65cebb5f449`, as a deniac aspect
(option surface, defaults, and the GTT headroom values). The `vram` enum maps
to the headroom table in nix-amd-ai's README ("GPU memory headroom": measured
on a 128 GB Strix Halo host — 96 GiB general use / ~120 GiB for 75 GiB+
models). den is pinned at
`c7ef3f11126f24878f5c69527b4230f51c839803`.

## Tests

Six `denTest` cases live in `modules/tests/ai-amd-strix.nix` and are exposed
as `flake.tests.ai-amd-strix`:

| Test | Asserts |
| --- | --- |
| `test-namespace-export` | `deniac.ai.amd.strix` resolves to a den aspect (has a `nixos` component). |
| `test-strix-point` | `chipset = "strix-point"` enables the stack, targets `gfx1150`, enables the GPU backends (ROCm + Vulkan), leaves the GTT at the kernel default, and sets the Lemonade leaves. |
| `test-strix-halo-128gb` | `chipset = "strix-halo"` + `vram = "128gb"` targets `gfx1151` and raises the GTT pair to 120 GiB. |
| `test-strix-halo-64gb` | `chipset = "strix-halo"` + `vram = "64gb"` — the vram axis is independent of the chipset axis (a 64 GB Halo board) — GTT pair at 56 GiB. |
| `test-user-required` | `chipset` + `vram` without `user` leaves the aspect inert (`enable = false`). |
| `test-inert-by-default` | Nothing set leaves `hardware.amd-npu` at its upstream disabled default and the aspect's options at their `null` defaults. |

Run them with nix-unit (the engine den's CI uses):

```sh
nix run nixpkgs#nix-unit -- --flake .#.tests.ai-amd-strix --impure
```
