# deniac

An à-la-carte den aspect library for NixOS home labs — pick the pieces you want to compose your own fleet.

> **Status: early development.** The design is settled (aspect model + data-tier
> contract); the first aspects are in progress. See [Status](#status).

## What is deniac?

deniac is a public, [den](https://github.com/denful/den)-based framework for NixOS
home labs and network fleets. Instead of forking a monolithic dotfiles repo, you take
a library of tested **aspects** — each a self-contained piece of
infrastructure-as-code — and select exactly the set you want into your own den
config:

- **Aspects, not a monolith.** Domain aspects (`filesystems`, `state`, `networks`,
  `gaming`) with software sub-aspects underneath (`filesystems.zfs`,
  `state.impermanence`, `gaming.steam`). Aspects can depend on other aspects —
  `filesystems` can pull in disko + impermanence — via den's `includes` DAG.
- **A backup-agnostic data-tier contract.** Tag your data `global` / `lan` /
  `machine`; whatever backup backend you run (ZFS, btrfs, rsync, borg, …) consumes
  the tags. No opinion on backends, no runtime app in between.
- **git + Nix are the only runtime.** No separate apps (clan, vars, …) standing
  between you and your machines.

## How it works

deniac is a den flake input. Its library is exported as a den
[namespace](https://github.com/denful/den/blob/main/docs/src/content/docs/guides/namespaces.mdx)
(`deniac`), and you select aspects by name in your own aspect's `includes`:

```nix
# your flake
inputs.deniac.url = "github:sjdevries/deniac";

# your den config
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

den.aspects.my-host.includes = [
  deniac.ai.amd.strix            # AMD Strix Point/Halo local-AI stack
  deniac.ai.halogen-flash-server # halogen inference container (Strix Halo)
];

# per-aspect options, under the aspect's own prefix
den.aspects.my-host.nixos.deniac.ai.amd.strix.chipset = "strix-halo";
den.aspects.my-host.nixos.deniac.ai.amd.strix.vram    = "128gb";
den.aspects.my-host.nixos.deniac.ai.amd.strix.user    = "tux";
```

> Verified against this repo's pinned den input. Full usage of `ai.amd.strix`
> — options, chipsets, VRAM sizing, overrides — is in
> [docs/ai-amd-strix.md](docs/ai-amd-strix.md).

### The aspect model

- **Domain aspects** — a feature area: `state`, `filesystems`, `networks`, `gaming`, …
- **Sub-aspects** — the specific software under a domain: `filesystems.zfs`,
  `gaming.steam` (den's `provides` mechanism).
- **Composition** — aspects compose via `includes` (a DAG), so one aspect can
  depend on others.
- **Context-aware** — aspects can be host/user-parametric (den's `__functor`
  pattern), so the same aspect adapts to where it is applied.

### Data tiers

A shared declarative contract, not backup settings: the data owner tags paths, and
any backend consumes the tags.

| Tier      | Meaning                                                        |
| --------- | -------------------------------------------------------------- |
| `global`  | Backed up to all NAS hosts — on-site **and** remote            |
| `lan`     | Backed up to LAN NAS hosts only (big local data, no off-site)  |
| `machine` | Local only — never to a NAS (Steam defaults here, overridable) |

Path scheme: `persistent.<domain>.<host>.<user>.<tier>.<aspect>`

## Status

- [x] Design — aspect model, data-tier contract, public/private split
- [x] Aspects shipped (each with a `denTest` suite, docs, and a usage example):
    - [`ai.amd.strix`](docs/ai-amd-strix.md) — AMD Strix Point/Halo local-AI
          stack (wraps nix-amd-ai)
    - [`ai.halogen-flash-server`](docs/ai-halogen-flash-server.md) — halogen
          inference container (Strix Halo only, rootful podman)
    - [`ai.model-store`](docs/ai-model-store.md) — shared AI model store
          (filesystem substrate, no service)
    - [`ai.gufo`](docs/ai-gufo.md) — gufo
          inference container (open counterpart, rootless podman)
    - [`ai.comfyui`](docs/ai-comfyui.md) — ComfyUI via comfyui-nix
          (`rocmChannel` escape hatch for new AMD GPUs)
    - [`ai.dsh`](docs/ai-dsh.md) — DeepSeek Harness, per-user Home Manager
          aspect (package + `~/.dsh/settings.yaml`)
    - [`ai.unsloth`](docs/ai-unsloth.md) — Unsloth Studio consumer,
          store-wired
    - [`ai.unsloth-desktop`](docs/ai-unsloth-desktop.md) — Unsloth
          Desktop (native GUI app), store-integrated via `HF_HOME`
          (Home Manager)
    - [`ai.strata`](docs/ai-strata.md) — strata inference consumer,
          store-wired
    - [`ai.ace-step`](docs/ai-ace-step.md) — ACE-Step music generation
          (official ComfyUI nodes: text2music, cover/remix, repaint)
- [x] Declarative model registry + [`deniac-model-add`](docs/deniac-model-add.md)
          helper (CivitAI/HF → model-store config entry)
- [x] Proper den tests (`denTest`) — all ten suites, green under nix-unit
- [x] Per-aspect documentation — `docs/ai-*.md`
- [ ] More aspects (the rest of the software I actually use)
- [ ] Templates + examples

## Related

- [den](https://github.com/denful/den) — the aspect-oriented Nix framework deniac is built on
- Grown from a real NixOS home lab: NAS boxes, desktops, routers, and switches

## License

MIT — see [LICENSE](LICENSE).
