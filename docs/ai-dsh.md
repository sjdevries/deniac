# `ai.dsh` — DeepSeek Harness (dsh), per-user Home Manager aspect

Installs the [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh)
agent harness (`dsh`) into a user's environment and renders
`~/.dsh/settings.yaml` from a declarative `settings` option. The package
comes from [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix)
(`packages/dsh`, a `buildNpmPackage` of the MIT-licensed `@deepseek-ai/dsh`),
pinned as a flake input.

This is a **`homeManager`-class** aspect (not `nixos`): `~/.dsh` is
per-user state, so the package and the generated settings belong in the
user's Home Manager eval.

## Scope — Phase 1: package + settings.yaml only

The dsh *profile* is an npm-native pnpm/cordis workspace
(`~/.dsh/profiles/web/{package.json, cordis.patch.yml, node_modules}`)
whose bundle list and per-bundle config live **outside** `settings.yaml`.
Building that `node_modules` closure in Nix is a deliberate follow-up
(Phase 2). This aspect therefore **never writes under
`~/.dsh/profiles/`** — an existing imperative profile keeps working
untouched.

## Options

Declared under `deniac.ai.dsh` (homeManager class):

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Install dsh and generate `~/.dsh/settings.yaml` for this user. |
| `package` | package | `inputs.llm-agents.packages.<system>.dsh` | The dsh package. Pinned in `flake.nix` to `32f95b57` ("dsh: 0.1.5-rc.1 -> 0.1.5-rc.2") — a known-good version; upstream `main` has moved to 0.2.0-rc.2, unverified here. Override to pin a different build. |
| `settings` | attrsOf anything | `{}` | Contents of `~/.dsh/settings.yaml`, rendered via `lib.generators.toYAML`. Mirrors the harness schema: top-level timeouts, `agent`, `llm-pi-ai.providers.<name>`, `agent-default-model`. YAML comments are not carried over — keep rationale in the Nix source. |

> **Implementation note:** in the current nixpkgs (26.11pre),
> `lib.generators.toYAML` is a stub that takes an **empty** attrset and
> emits JSON. That is intentional — JSON is a strict subset of YAML 1.2 and
> dsh's parser reads the file as YAML. Do not "fix" it by passing
> `{ indent = … }`; the stub rejects unknown arguments.

## Usage

```nix
# your flake
inputs.deniac.url = "github:sjdevries/deniac";

# your den config
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

# a user aspect that carries a homeManager class:
den.aspects.alice.includes = [ deniac.ai.dsh ];

den.aspects.alice.homeManager.deniac.ai.dsh.enable = true;
den.aspects.alice.homeManager.deniac.ai.dsh.settings = {
  idle_timeout = 3600;
  "llm-pi-ai".providers.halogen = {
    api = "openai-completions";
    baseURL = "http://127.0.0.1:8731/v1";
    apiKeyEnv = "HALOGEN_API_KEY";
  };
  "agent-default-model" = { provider = "halogen"; model = "halogen-qwen3.8-flash-next"; };
};
```

Note the class is `homeManager`, not `nixos` — the options live in the
user's Home Manager evaluation.

## Provenance

The package is numtide/llm-agents.nix `packages/dsh` (buildNpmPackage of
`@deepseek-ai/dsh`, MIT), pinned to commit `32f95b57bd11604871fb663c6724da15112860ee`.
The deniac option surface, the settings.yaml rendering, and the
Phase-1 scope decision (never touch `~/.dsh/profiles/`) are deniac's.

## Tests

`flake.tests.ai-dsh` (denTest): namespace export — with the `deniac`
namespace imported from `inputs.self`, `deniac.ai.dsh` resolves to a den
aspect exposing a `homeManager` class module. A full homeManager eval
(projecting the rendered `settings.yaml` through a real user + home) lands
with the Phase-2 profile work.

Run with nix-unit:

```sh
nix run nixpkgs#nix-unit -- --flake .#.tests.ai-dsh --impure
```
