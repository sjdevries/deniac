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

> **Status of this contract:** documented, **not yet implemented.** No
> `global` / `lan` / `machine` enum exists in the codebase and nothing
> consumes the tags yet. It is a design commitment, not a mechanism.
> Backup intelligence cannot be retrofitted — a backup layer can only read
> tiers that an aspect declared — so wiring this is a precondition on every
> future aspect that owns mutable state, not a later feature.

### The compartment shape

Aspects that run software in isolation — an agent, a desktop app as a VM, a
build sandbox — all need the same four things. `lib/compartment.nix` holds
that shape so each aspect supplies only what is genuinely app-specific:

| Declares | Meaning |
| --- | --- |
| `enforcement` | **how it is contained** — `bwrap` (mount namespace) or `munix` (KVM microVM) |
| `binds` | **what it may touch** — a default-DENY allowlist; the real home is never bound |
| `stateDirExpr` | **where its state lives** — materialised at activation, not baked into the closure |
| `command` | **what actually runs** inside |

Two properties are load-bearing and shared by every compartment:

- **The closure is the visibility allowlist.** A guest sees only what its
  closure contains, which is what makes `enforcement = "munix"` a real
  boundary rather than a suggestion. It also forces the secret rule: a
  secret baked at build time would be visible to everything that can see
  the closure, so secrets are read from their decrypted runtime path at
  launch and never enter the store.
- **Declared vs learned reconciles at activation.** The closure declares,
  the state dir accumulates, and a preserve-learned deep merge keeps the
  two from clobbering each other. This is what makes an immutable closure
  compatible with mutable user settings.

`ai.hermes` is the reference implementation: it fills the two app-shaped
holes (what gets rendered into the state dir, and `hermes -p <name>`) and
inherits the rest.

> **Naming.** `enforcement` is how a compartment is contained. `tier` is
> where its data is backed up. These are deliberately different words:
> "set the tier to `munix`" and "set the tier to `lan`" are both
> grammatically natural and mean unrelated things, and picking wrong
> produces no error. `ai.strata` also uses "tiering" for MoE experts
> across VRAM/RAM/SSD, which is prose about memory hierarchy rather than a
> configurable axis, so it does not collide.

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
          aspect (package only)
    - [`ai.unsloth`](docs/ai-unsloth.md) — Unsloth Studio consumer,
          store-wired
    - [`ai.unsloth-desktop`](docs/ai-unsloth-desktop.md) — Unsloth
          Desktop (native GUI app), store-integrated via `HF_HOME`
          (Home Manager)
    - [`ai.strata`](docs/ai-strata.md) — strata inference consumer,
          store-wired
    - [`ai.ace-step`](docs/ai-ace-step.md) — ACE-Step music generation
          (official ComfyUI nodes: text2music, cover/remix, repaint)
    - [`ai.hermes`](docs/ai-hermes.md) — Hermes Agent in role-compartment
          jails (researcher/coder/reviewer/creator), default-deny bind via
          bubblewrap or KVM microVM (munix); declared stack + backed-up memory
- [x] Declarative model registry + [`deniac-model-add`](docs/deniac-model-add.md)
          helper (CivitAI/HF → model-store config entry)
- [x] Proper den tests (`denTest`) — all eleven suites, green under nix-unit
- [x] Per-aspect documentation — `docs/ai-*.md`
- [x] **Compartment shape** — `lib/compartment.nix`: the four declared
          things (enforcement / binds / state dir / command) shared by
          every isolated-app aspect. Extracted from `ai.hermes`, which is
          now a thin adapter over it. `ai.hermes` 10/10 under nix-unit.
- [ ] **Backup-tier contract wired** — the `global` / `lan` / `machine`
          enum is documentation only. Needs implementing, plus a check
          that no aspect declares mutable state without a tier. Until
          then, "backup-agnostic" is a promise rather than a mechanism.
- [ ] **Secrets into a compartment** — the runtime-injection path exists
          (`secretEnvAssignments`) but the general key-distribution story
          across VMs is undesigned. The one thing the aspect model does
          not yet answer.
- [ ] More aspects (the rest of the software I actually use)
- [ ] Templates + examples

## Related

- [den](https://github.com/denful/den) — the aspect-oriented Nix framework deniac is built on
- Grown from a real NixOS home lab: NAS boxes, desktops, routers, and switches

## License

MIT — see [LICENSE](LICENSE).
