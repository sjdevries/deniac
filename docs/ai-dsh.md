# `ai.dsh` — DeepSeek Harness (dsh), per-user Home Manager aspect

Installs the [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh)
agent harness (`dsh`) into a user's environment. The package comes from
[numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix)
(`packages/dsh`, a `buildNpmPackage` of the MIT-licensed `@deepseek-ai/dsh`),
pinned as a flake input.

This is a **`homeManager`-class** aspect (not `nixos`): `~/.dsh` is
per-user state, so the package belongs in the user's Home Manager eval.

## Scope — Phase 1: the package only

The aspect ships the **package and nothing else**. It deliberately owns **no
settings file**.

dsh 0.2.x removed `~/.dsh/settings.yaml` as a configuration surface. The
settings service treats a file at that path as a **one-shot legacy
migration**: once the Loader settles, `importLegacyDocument`
(`@deepseek-ai/dsh-settings`) renames it to `settings.yaml.imported` and
pushes each of its sections into the **active profile's** Cordis patch. It
is never read again as live config.

That makes a home-manager-owned `settings.yaml` actively harmful rather
than merely stale: each `home-manager switch` recreates the path, each
boot re-imports it, and every re-import **clobbers** whatever changed
through the dsh UI in between — the file is re-applied, not merged once.

The durable declarative home for dsh config is the **profile patch layer**:
`~/.dsh/profiles/<name>/cordis.patch.yml`, a list of per-entry config
patches applied after the bundle patches. That profile is an npm-native
pnpm/cordis workspace (`package.json`, `cordis.patch.yml`,
`node_modules`) whose closure this aspect does **not** build or write
(Phase-2 work). So the aspect writes neither `settings.yaml` nor anything
under `~/.dsh/profiles/` — an existing imperative profile keeps working
untouched.

## Options

Declared under `deniac.ai.dsh` (homeManager class):

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Install dsh for this user. |
| `package` | package | `inputs.llm-agents.packages.<system>.dsh` | The dsh package. Pinned in `flake.nix` to `0784674` (llm-agents `main`, 2026-10-26) = dsh 0.2.1-rc.3 — verified building and starting on this box. (Was held at 0.1.5-rc.2 because dsh 0.1.6+ crashed at boot with `node-addon-require-builtin unsupported`, llm-agents#9994; fixed upstream by `e442eb67`.) Note this input is shared with hermes-agent — bumping it moves both. Override to pin a different build. |

## Usage

```nix
# your flake
inputs.deniac.url = "github:sjdevries/deniac";

# your den config
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

# a user aspect that carries a homeManager class:
den.aspects.tux.includes = [ deniac.ai.dsh ];

den.aspects.tux.homeManager.deniac.ai.dsh.enable = true;
```

Note the class is `homeManager`, not `nixos` — the options live in the
user's Home Manager evaluation. Providers, the default model, and every
other runtime setting are configured in the user's
`~/.dsh/profiles/<name>/cordis.patch.yml`, not through this aspect.

## Provenance

The package is numtide/llm-agents.nix `packages/dsh` (buildNpmPackage of
`@deepseek-ai/dsh`, MIT), pinned to commit
`0784674971b3ee4681aea5b5e9641c75faf7e846`. The deniac option surface
and the Phase-1 scope decisions (ship the package only; never write
`~/.dsh/settings.yaml` or `~/.dsh/profiles/`) are deniac's.

## Tests

`flake.tests.ai-dsh` (denTest): namespace export — with the `deniac`
namespace imported from `inputs.self`, `deniac.ai.dsh` resolves to a den
aspect exposing a `homeManager` class module. A full homeManager eval
(projecting the installed package through a real user + home) lands with
the Phase-2 profile work.

Run with nix-unit:

```sh
nix run nixpkgs#nix-unit -- --flake .#.tests.ai-dsh --impure
```
