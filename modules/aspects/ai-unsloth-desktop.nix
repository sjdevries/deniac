# deniac.ai.unsloth-desktop — Unsloth Desktop, store-integrated (Home Manager).
#
# Installs the nixpkgs `unsloth-desktop` package (the native GUI app —
# the upstream .deb wrapped in an FHS env) into the user's environment
# and points its HuggingFace cache at the shared `ai.model-store`
# `hfCache` via `HF_HOME`, so models the Desktop downloads land in the
# shared content-addressed store — downloaded once, shared with gufo /
# Studio / ComfyUI / any other consumer.
#
# Desktop vs Studio (see docs/ai-unsloth.md for the full picture):
#   * Unsloth Desktop — native GUI app (this aspect). Runs locally under
#     the user's session; NOT a service. It wraps the same Studio
#     engine.
#   * Unsloth Studio  — the headless server form (`deniac.ai.unsloth`).
# Both consume models through the HuggingFace cache, so both integrate
# with the store the same way: point HF_HOME at it.
#
# Verified facts (2026-10-05):
#   * Downloads use the standard HF cache layout; setting HF_HOME (or
#     HF_HUB_CACHE) before launch redirects them
#     (github.com/unslothai/unsloth/issues/5182).
#   * The app's runtime lives in ~/.unsloth/studio (uv venv + PyPI
#     backend + llama.cpp binaries, bootstrapped on first run) and is
#     SEPARATE from the model cache — the store integration does not
#     touch it.
#   * The nixpkgs package is an FHS wrapper (buildFHSEnv) around the
#     upstream .deb; the FHSEnv passes the user's environment through,
#     so the session-set HF_HOME reaches the app.
#
# Requirements the aspect CANNOT set from the homeManager side:
#   * The user must be a member of the store group (default `aimodels`)
#     to write to the shared cache — that is a NixOS-side user
#     definition: `users.users.<name>.extraGroups = [ "aimodels" ];`
#     (or the user aspect's `provides.to-hosts.nixos`).
#   * The store itself is provisioned nixos-side
#     (`deniac.ai.model-store.enable = true` on the host).
#
# Usage:
#   # host: provision the store
#   den.aspects.igloo.includes = [ deniac.ai.model-store ];
#   den.aspects.igloo.nixos.deniac.ai.model-store.enable = true;
#   # user: install Desktop + share the cache
#   den.aspects.tux.includes = [ deniac.ai.model-store deniac.ai.unsloth-desktop ];
#   den.aspects.tux.homeManager.deniac.ai.unsloth-desktop.enable = true;
#   # and on the host, give the user write access to the shared cache:
#   den.aspects.tux.provides.to-hosts.nixos.users.users.tux.extraGroups = [ "aimodels" ];

{ lib, ... }:
{
  deniac.ai.unsloth-desktop = {
    description = ''
      Unsloth Desktop — the native GUI app (nixpkgs `unsloth-desktop`,
      the upstream .deb in an FHS wrapper) — installed per-user via
      Home Manager, with its HuggingFace cache pointed at the shared
      `ai.model-store` `hfCache` via `HF_HOME`. Models downloaded
      through the Desktop are shared, content-addressed, and
      deduplicated with every other store consumer. The app's own
      runtime (~/.unsloth/studio) stays per-user and untouched.

      Requires: the store provisioned nixos-side, and the user in the
      store group for write access. x86_64-linux only (upstream .deb).
      AGPL-3.0.
    '';

    homeManager =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.ai.unsloth-desktop;
      # Is the store's path surface present in THIS (homeManager) eval?
      # It is when the user aspect also includes `deniac.ai.model-store`
      # (whose homeManager class declares these options read-only).
      storeIncluded = config.deniac.ai.model-store ? hfCache;
    in
    {
      options.deniac.ai.unsloth-desktop = {
        enable = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = "Install Unsloth Desktop and point its HF cache at the shared store.";
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.unsloth-desktop;
          defaultText = lib.literalExpression "pkgs.unsloth-desktop";
          description = ''
            The unsloth-desktop package (FHS-wrapped upstream .deb,
            AGPL-3.0, x86_64-linux). Override to pin a different build.
          '';
        };

        modelsDir = lib.mkOption {
          default = config.deniac.ai.model-store.hfCache or "/var/lib/ai-models/.hf-cache";
          type = lib.types.str;
          description = ''
            Host directory set as `HF_HOME` for the user session — the
            cache Unsloth Desktop downloads into. Defaults to the shared
            `ai.model-store` `hfCache` (follows a custom store `root`);
            falls back to the canonical path when no store is included
            in this eval. Override for a standalone layout.

            Note this sets HF_HOME for the user's whole session, not
            just the app — that is the point of a shared cache (every
            HF tool the user runs dedups against the same blobs), but
            it is a session-wide effect worth knowing about.
          '';
        };
      };

      config =
        lib.mkMerge [
          (lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];
            home.sessionVariables.HF_HOME = cfg.modelsDir;
          })
          {
            # Guide the half-wired case: enabled without the store in
            # this eval means the fallback path must already exist and
            # be user-writable — usually a mistake, not a choice.
            # (Inside `config`: the den aspect shape rejects a
            # top-level `warnings`.)
            warnings = lib.optionals (cfg.enable && !storeIncluded) [
              ''
                deniac.ai.unsloth-desktop: enabled without `deniac.ai.model-store` in this user aspect — HF_HOME falls back to ${cfg.modelsDir}, which must already exist and be writable by this user. Include `deniac.ai.model-store` in the same user aspect (its homeManager class is options-only) and provision the store on the host for the shared, backed-up layout. Also remember: the user needs the store group (default `aimodels`) in its NixOS-side extraGroups to write the shared cache.
              ''
            ];
          }
        ];
    };
  };
}
