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
  deniac.filesystems         # disko + ZFS layout
  deniac.state.impermanence  # …
  deniac.gaming.steam
];
```

> Example per the den v0.18.0 namespace guide — the shape is stable; exact names
> and syntax will be confirmed as the first aspects land.

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
- [ ] First aspects (starting with the software I actually use)
- [ ] Proper den tests (`denTest`)
- [ ] Per-aspect documentation
- [ ] Templates + examples

## Related

- [den](https://github.com/denful/den) — the aspect-oriented Nix framework deniac is built on
- Grown from a real NixOS home lab: NAS boxes, desktops, routers, and switches

## License

MIT — see [LICENSE](LICENSE).
