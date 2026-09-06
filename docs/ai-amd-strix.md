# `ai.amd.strix` — AMD Strix Point / Strix Halo local AI stack

A den aspect for AMD "Strix" APUs: **Strix Point** (Ryzen AI 300 series,
64 GB unified memory) and **Strix Halo** (Ryzen AI Max, 128 GB). It brings up
the local-AI stack documented by the [nix-amd-ai](https://github.com/noamsto/nix-amd-ai)
project, wrapped as a single deniac aspect so you can include it on a host and
opt in to individual backends from there.

When active, the aspect configures:

- **XDNA NPU driver** (the Strix Point/Halo NPU) and the
  **FastFlowLM** inference runtime for it.
- **Lemonade** — an OpenAI-compatible local API server
  (`localhost:13305` by default) — plus **image generation** (sd-cpp backend).
- The **GPU memory (GTT) pool** sizing appropriate to the board (see
  [Profiles](#profiles)).

It deliberately keeps the heavier backends — **ROCm**, **Vulkan**, and
**vLLM** — **off** by default. A host that wants them opts in by overriding the
relevant leaf (see [Overrides](#overrides)). The `ds4` (DeepSeek V4) server is
also off by default: it requires a model selection a host must supply.

Everything the aspect sets sits under `hardware.amd-npu` with
`lib.mkDefault` priority, so it never wins against an explicit host definition
and never blocks you from overriding any single leaf.

## Options

Declared under `deniac.ai.amd.strix`:

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `profile` | `nullOr (enum ["64gb" "128gb"])` | `null` | The unified-memory board. `null` leaves the whole aspect **inert** (`hardware.amd-npu` disabled). |
| `user` | `nullOr str` | `null` | The local account to run Lemonade (lemond) as. Required whenever a profile is set — until it is, the stack stays inert. |

Set both to activate; leave `profile` as `null` to keep the aspect inert on a
host that shouldn't run the stack.

## Profiles

| Profile | Board | GPU target | GTT (GPU memory) pool |
| --- | --- | --- | --- |
| `64gb` | Strix Point, 64 GB | `gfx1150` | Kernel default (≈27 GB) — already covers 17–22 GB models, so `gpuMemory` stays unset. |
| `128gb` | Strix Halo, 128 GB | `gfx1151` | Raised to **96 GiB** via `ttm` `pages_limit` + `page_pool_size` (the pair nix-amd-ai measured on a Halo host; leaves ≈32 GB for CPU/OS). |

With a profile active, the resulting `hardware.amd-npu` value is:

| Leaf | Value |
| --- | --- |
| `enable` | `true` |
| `enableNPU` | `true` |
| `enableFastFlowLM` | `true` |
| `enableLemonade` | `true` |
| `enableImageGen` | `true` |
| `enableROCm` / `enableVulkan` / `enableVllm` | `false` (host opt-in) |
| `exclusiveInference` | `false` |
| `ds4.enable` | `false` (needs `ds4.model`, host opt-in) |
| `gpuTarget` | `gfx1150` (64gb) / `gfx1151` (128gb) |
| `gpuMemory.ttmSizeGiB` / `.pagePoolSizeGiB` | unset (64gb) / `96` / `96` (128gb) |
| `lemonade.host` | `localhost` |
| `lemonade.port` | `13305` |
| `lemonade.autoStart` | `true` |
| `lemonade.flashAttn` | `"on"` |
| `lemonade.models` | `[]` (host lists models to keep downloaded) |
| `lemonade.pruneUnlistedModels` | `false` |
| `lemonade.customModels` | `{ }` |
| `lemonade.user` | the aspect's `user` option |

## Usage

```nix
# your flake
inputs.deniac.url = "github:sjdevries/deniac";

# your den config
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

den.aspects.igloo.includes = [ deniac.ai.amd.strix ];

# activate: pick a board + the account running Lemonade
den.aspects.igloo.nixos.deniac.ai.amd.strix.profile = "128gb";
den.aspects.igloo.nixos.deniac.ai.amd.strix.user    = "tux";

# optional host-side overrides (any leaf, at any depth):
den.aspects.igloo.nixos.hardware.amd-npu.enableROCm       = true;   # GPU backends
den.aspects.igloo.nixos.hardware.amd-npu.lemonade.models  = [ "gpt-oss-120b" ];
```

The account in `user` must also be a member of the `video` and `render` groups
for NPU access — the nix-amd-ai module handles the driver, but group
membership is a host concern.

## Overrides

Every leaf is declared with `lib.mkDefault`, so a plain host definition wins
and only that path changes — the rest of the `hardware.amd-npu` subtree
survives. This is why the aspect spreads its value to each leaf rather than
`mkDefault`-ing one big attrset: overriding `lemonade.models` replaces just
that list, not the whole `lemonade` block.

To turn on a backend, override the leaf directly (it is `false` by default):

```nix
den.aspects.igloo.nixos.hardware.amd-npu.enableVllm = true;  # needs ROCm + Lemonade
```

## Inert behaviour

With `profile = null` (the default), the aspect contributes nothing to
`hardware.amd-npu`: the upstream `nix-amd-ai` module keeps its own
`enable = false` default and the required `lemonade.user` option is never
forced. This is deliberate — a host that includes the aspect but hasn't chosen
a board should not fail to build.

## Provenance

This aspect wraps [noamsto/nix-amd-ai](https://github.com/noamsto/nix-amd-ai),
pinned at
`7a739c04c33e9abf9a8ccd39fd81d65cebb5f449`, as a deniac aspect (option
surface, profiles, and defaults). The `64gb`/`128gb` profiles are the two
board configurations nix-amd-ai's own README documents; the 96 GiB GTT pair is
the value it measured on a Strix Halo host. den is pinned at
`c7ef3f11126f24878f5c69527b4230f51c839803`.

## Tests

Five `denTest` cases live in `modules/tests/ai-amd-strix.nix` and are exposed
as `flake.tests.ai-amd-strix`:

| Test | Asserts |
| --- | --- |
| `test-namespace-export` | `deniac.ai.amd.strix` resolves to a den aspect (has a `nixos` component). |
| `test-64gb` | Profile `64gb` enables the stack, targets `gfx1150`, keeps backends off, and sets the Lemonade leaves. |
| `test-128gb` | Profile `128gb` targets `gfx1151` and raises the GTT pair to 96 GiB. |
| `test-user-required` | A profile without a user leaves the aspect inert (`enable = false`). |
| `test-inert-by-default` | No profile / user leaves `hardware.amd-npu` at its upstream disabled default. |

Run them with nix-unit (the engine den's CI uses):

```sh
nix run nixpkgs#nix-unit -- --flake .#.tests.ai-amd-strix --impure
```
