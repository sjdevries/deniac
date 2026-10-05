# deniac.ai.dsh — DeepSeek Harness (dsh) as a per-user Home Manager aspect.
#
# Installs the `dsh` agent harness (npm `@deepseek-ai/dsh`, via the numtide
# `llm-agents` flake input pinned in flake.nix) into the user's environment
# and renders `~/.dsh/settings.yaml` from the `settings` option.
#
# Provenance: the package is numtide/llm-agents.nix `packages/dsh`
# (buildNpmPackage of @deepseek-ai/dsh, MIT). Pinned to commit 32f95b57
# ("dsh: 0.1.5-rc.1 -> 0.1.5-rc.2") — a known-good version; `main` has
# since moved to 0.2.0-rc.2, unverified against this fleet.
#
# SCOPE (Phase 1): the package + settings.yaml ONLY. The dsh *profile* is an
# npm-native pnpm/cordis workspace (`~/.dsh/profiles/web/{package.json,
# cordis.patch.yml,node_modules}`) whose bundle list and per-bundle config
# live outside settings.yaml. Building that node_modules closure in Nix is a
# deliberate follow-up (Phase 2). This aspect therefore NEVER writes under
# `~/.dsh/profiles/`, so an existing imperative profile keeps working
# untouched.
#
# Why a `homeManager` class (not `nixos`): `~/.dsh` is per-user state, so the
# package and the generated settings belong in the user's Home Manager eval.
# The class module is a plain home-manager module (gets `pkgs`, `config`,
# `lib`); the `deniac` namespace resolves in it exactly as in a `nixos` class.
#
# Usage (a user aspect that carries a homeManager class):
#
#   den.aspects.tux.includes = [ deniac.ai.dsh ];
#   den.aspects.tux.homeManager.deniac.ai.dsh.enable = true;
#   den.aspects.tux.homeManager.deniac.ai.dsh.settings = {
#     idle_timeout = 3600;
#     "llm-pi-ai".providers.halogen = {
#       api = "openai-completions";
#       baseURL = "http://127.0.0.1:8731/v1";
#       apiKeyEnv = "HALOGEN_API_KEY";
#     };
#     "agent-default-model" = { provider = "halogen"; model = "halogen-qwen3.8-flash-next"; };
#   };

{ inputs, lib, ... }:
{
  deniac.ai.dsh = {
    description = ''
      DeepSeek Harness (dsh) — the open-source agent harness — installed
      per-user via Home Manager. Provides the `dsh` package (numtide
      llm-agents, pinned to a known-good commit) and renders
      `~/.dsh/settings.yaml` from the `settings` option. The npm-native
      profile (bundle list + cordis.patch.yml + node_modules) is out of
      scope: this aspect never writes `~/.dsh/profiles/`, so an existing
      profile is preserved.
    '';

    homeManager =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.ai.dsh;
      # NOTE: in this nixpkgs (26.11pre) `lib.generators.toYAML` is the
      # stub `{ }: lib.strings.toJSON` — it takes an EMPTY attrset (passing
      # `{ indent = … }` throws "unexpected argument 'indent'") and emits
      # JSON. That is fine: JSON is a strict subset of YAML 1.2, and dsh's
      # parser reads the file as YAML, so the structure is identical. Do
      # not "fix" this by adding an indent option — the stub rejects it.
      yaml = v: lib.generators.toYAML { } v;
    in
    {
      options.deniac.ai.dsh = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Install dsh and generate ~/.dsh/settings.yaml for this user.";
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.dsh;
          defaultText = lib.literalExpression "inputs.llm-agents.packages.\${system}.dsh";
          description = ''
            The dsh package. Defaults to the numtide llm-agents input pinned
            in deniac/flake.nix (dsh 0.1.5-rc.2). Override to pin a
            different build.
          '';
        };

        settings = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          example = {
            idle_timeout = 3600;
            "llm-pi-ai".providers.halogen = {
              api = "openai-completions";
              baseURL = "http://127.0.0.1:8731/v1";
              apiKeyEnv = "HALOGEN_API_KEY";
            };
            "agent-default-model" = {
              provider = "halogen";
              model = "halogen-qwen3.8-flash-next";
            };
          };
          description = ''
            Contents of ~/.dsh/settings.yaml, rendered as YAML via
            lib.generators.toYAML. The structure mirrors the harness schema:
            top-level timeouts, `agent`, `llm-pi-ai.providers.<name>`, and
            `agent-default-model`. YAML comments are not carried over — keep
            any rationale in the Nix source.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        home.packages = [ cfg.package ];
        home.file.".dsh/settings.yaml".text = yaml cfg.settings;
      };
    };
  };
}
