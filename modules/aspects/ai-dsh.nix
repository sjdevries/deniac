# deniac.ai.dsh — DeepSeek Harness (dsh) as a per-user Home Manager aspect.
#
# Installs the `dsh` agent harness (npm `@deepseek-ai/dsh`, via the numtide
# `llm-agents` flake input pinned in flake.nix) into the user's environment.
# The aspect ships the PACKAGE ONLY — it owns no settings file (see SCOPE).
#
# Provenance: the package is numtide/llm-agents.nix `packages/dsh`
# (buildNpmPackage of @deepseek-ai/dsh, MIT). Pinned to commit 0784674
# (llm-agents main, 2026-10-26) = dsh 0.2.1-rc.3.
#
# Upgrade history: we were held at 0.1.5-rc.2 because dsh 0.1.6+ crashed at
# boot with `node-addon-require-builtin unsupported: Unsupported/no-getter`
# (llm-agents#9994, root NixOS/nixpkgs#565667 — the addon decodes V8
# machine code, which nixpkgs' leaf-frame-pointer Node breaks). That bug is
# now FIXED upstream: e442eb67 ("dsh: avoid node-addon-require-builtin")
# replaced the shim with plain require() under --expose-internals, and it is
# merged into llm-agents' dsh package on main. Bumped 2026-10-26; dsh
# 0.2.1-rc.3 verified building AND starting (web boot, token issued) on this
# box at this pin.
#
# SHARED-INPUT WARNING: the `llm-agents` input also provides hermes-agent
# (deniac.ai.hermes). Bumping it moves BOTH. This bump took hermes
# 0.8.4 -> 0.22.5 (deliberate, user-approved; both verified building +
# starting). Do not bump this input casually — re-verify hermes too.
#
# SCOPE (Phase 1): the package ONLY — no settings file.
#
# dsh 0.2.x REMOVED `~/.dsh/settings.yaml` as a configuration surface. The
# settings service treats a file at that path as a ONE-SHOT legacy
# migration: once the Loader settles, `importLegacyDocument`
# (@deepseek-ai/dsh-settings) renames it to `settings.yaml.imported` and
# pushes each of its sections into the ACTIVE PROFILE's Cordis patch. It is
# never read again as live config.
#
# That makes a home-manager-owned `settings.yaml` actively harmful: every
# `home-manager switch` recreates the path, every boot re-imports it, and
# each re-import CLOBBERS whatever changed through the dsh UI in between
# (the file is re-applied, not merged-once). This aspect therefore writes no
# settings file at all.
#
# The durable declarative home for dsh config is the profile patch layer —
# `~/.dsh/profiles/<name>/cordis.patch.yml`, a list of per-entry config
# patches applied after the bundle patches. That is an npm-native
# pnpm/cordis workspace (`package.json`, `cordis.patch.yml`,
# `node_modules`) whose closure this aspect deliberately does NOT build or
# write (Phase-2 work). So: package only here, profile patch owned by the
# user's profile (or Phase 2), never `~/.dsh/settings.yaml`.
#
# Why a `homeManager` class (not `nixos`): `~/.dsh` is per-user state, so
# the package belongs in the user's Home Manager eval. The class module is a
# plain home-manager module (gets `pkgs`, `config`, `lib`); the `deniac`
# namespace resolves in it exactly as in a `nixos` class.
#
# Usage (a user aspect that carries a homeManager class):
#
#   den.aspects.tux.includes = [ deniac.ai.dsh ];
#   den.aspects.tux.homeManager.deniac.ai.dsh.enable = true;

{ inputs, lib, ... }:
{
  deniac.ai.dsh = {
    description = ''
      DeepSeek Harness (dsh) — the open-source agent harness — installed
      per-user via Home Manager. Provides the `dsh` package (numtide
      llm-agents, pinned to a known-good commit). Configuration is NOT
      owned here: dsh 0.2.x treats `~/.dsh/settings.yaml` as a one-shot
      legacy migration that is renamed away on first boot, so this aspect
      writes no settings file. Live config lives in the user's profile
      patch (`~/.dsh/profiles/<name>/cordis.patch.yml`), which this
      aspect never touches — an existing imperative profile keeps working
      untouched.
    '';

    homeManager =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.ai.dsh;
    in
    {
      options.deniac.ai.dsh = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Install dsh for this user.";
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.dsh;
          defaultText = lib.literalExpression "inputs.llm-agents.packages.\${system}.dsh";
          description = ''
            The dsh package. Defaults to the numtide llm-agents input pinned
            in deniac/flake.nix (dsh 0.2.1-rc.3). Override to pin a
            different build.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        home.packages = [ cfg.package ];
      };
    };
  };
}
