# `ai.unsloth-desktop` — Unsloth Desktop, store-integrated (Home Manager)

Installs the native **Unsloth Desktop** GUI app (nixpkgs
[`unsloth-desktop`](https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/un/unsloth-desktop/package.nix)
— the upstream `.deb` wrapped in an FHS environment) into the user's
environment and points its HuggingFace cache at the shared
[`ai.model-store`](./ai-model-store.md) `hfCache` via `HF_HOME` — so
models downloaded through the Desktop are stored **once**, shared with
gufo / Studio / ComfyUI / every other store consumer.

This is the Desktop-GUI counterpart to
[`ai.unsloth`](./ai-unsloth.md) (the headless server form). For the
Desktop/Studio/Core distinction, see that doc.

## How the store integration works

Unsloth's downloads use the standard HuggingFace cache layout and honor
`HF_HOME` when it is set before launch
([unslothai/unsloth#5182](https://github.com/unslothai/unsloth/issues/5182)).
The aspect sets `home.sessionVariables.HF_HOME` to the store's
`hfCache`, so:

- Desktop downloads land in the **shared, content-addressed** cache —
  the same blobs gufo/Studio/`hf download` use, deduplicated by hash.
- A custom store `root` propagates automatically (the aspect reads
  `deniac.ai.model-store.hfCache` from the same user aspect).
- The store's preservation story (backup tier, checksums, off-site)
  covers Desktop-downloaded weights too.

**What is NOT shared:** the app's own runtime — `~/.unsloth/studio`
(uv venv + PyPI backend + llama.cpp binaries, bootstrapped on first
run). That stays per-user, per the upstream design; the model cache and
the runtime are separate locations upstream keeps distinct
([install docs](https://unsloth.ai/docs/new/studio/install)).

**Session-wide effect:** `HF_HOME` is set for the user's whole session,
not just the app — that is the point of a shared cache (every HF tool
the user runs dedups against the same blobs), but worth knowing.

## Requirements the aspect cannot set for you

Both are NixOS-side (a homeManager module cannot create groups or
provision directories):

1. **The store must be provisioned on the host:**
   `den.aspects.<host>.nixos.deniac.ai.model-store.enable = true;`
2. **The user must be in the store group** (default `aimodels`) to
   write the shared cache:
   `users.users.<name>.extraGroups = [ "aimodels" ];` — or via the
   user aspect's `provides.to-hosts.nixos` (see the usage example).

If you enable the aspect without `deniac.ai.model-store` in the same
user aspect, the build **warns** (the fallback path must already exist
and be writable — usually a mistake, not a choice).

## Options

Declared under `deniac.ai.unsloth-desktop` (homeManager class):

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Install Unsloth Desktop and point its HF cache at the shared store. |
| `package` | `pkgs.unsloth-desktop` | The package (FHS-wrapped upstream .deb, AGPL-3.0, x86_64-linux). Override to pin a different build. |
| `modelsDir` | `ai.model-store.hfCache` → fallback `/var/lib/ai-models/.hf-cache` | Host dir set as `HF_HOME` for the user session. Defaults to the shared store cache; follows a custom store `root`. Override for a standalone layout. |

## Usage

```nix
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

# host: provision the store
den.aspects.igloo.includes = [ deniac.ai.model-store ];
den.aspects.igloo.nixos.deniac.ai.model-store.enable = true;

# user: install Desktop + share the cache.
# Include the store in the user aspect too — its homeManager class is
# options-only (the path surface) and that is what makes `modelsDir`
# follow the store's hfCache/custom root.
den.aspects.tux.includes = [ deniac.ai.model-store deniac.ai.unsloth-desktop ];
den.aspects.tux.homeManager.deniac.ai.unsloth-desktop.enable = true;

# and give the user write access to the shared cache (NixOS side):
den.aspects.tux.provides.to-hosts.nixos =
  { ... }: { users.users.tux.extraGroups = [ "aimodels" ]; };
```

Then launch `unsloth-desktop` from the desktop entry; downloaded models
appear in `http(s)://<store-root>/.hf-cache` and are shared fleet-wide.

## Caveats

- **x86_64-linux only** — the upstream ships a Linux `.deb`; nixpkgs
  marks the package accordingly.
- **AGPL-3.0** — the upstream app license (same as the Studio UI).
- **Self-updater is inert** — the in-app updater cannot replace the
  read-only store binary; update by bumping the nixpkgs package (or the
  `package` option).
- **First run bootstraps the runtime** into `~/.unsloth/studio`
  (network fetch of the PyPI backend + llama.cpp). That is per-user
  state; on impermanence hosts, persist it (or accept the re-bootstrap)
  — the aspect deliberately does not manage it.

## Provenance

Package facts from the nixpkgs `unsloth-desktop` package source
(FHS wrapper around the upstream `.deb`, runtime bootstrap note,
AGPL-3.0); cache behavior verified from
[unslothai/unsloth#5182](https://github.com/unslothai/unsloth/issues/5182)
and the [Unsloth Studio install docs](https://unsloth.ai/docs/new/studio/install)
(retrieved 2026-10-05). The store wiring (`HF_HOME` → shared
`hfCache`), the model-store `homeManager` class refactor, the
fallback warning, and the tests are deniac's.

## Tests

`flake.tests.ai-unsloth-desktop` (denTest): namespace export — the
aspect resolves with a `homeManager` class function and **no** `nixos`
class (it is per-user only). A full homeManager eval (rendered
session-vars through a real user + home) needs the home-manager input,
which this flake does not carry — same shape-only guarantee as
`ai.dsh`. The store side is covered in `flake.tests.ai-model-store`
(`test-homemanager-class`: the path surface evaluates standalone,
`hfCache` follows a custom `root`, and the hm class carries no
provisioning options).
