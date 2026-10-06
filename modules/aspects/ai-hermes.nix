# deniac.ai.hermes — Hermes Agent (Nous Research) in a bubblewrap jail.
#
# PHASE 1 (this aspect): the core jail. Hermes runs as the user inside a
# mount namespace where the system is read-only and the user's home is the
# workspace. Model/provider configuration happens in the agent's own
# ~/.hermes/config.yaml (mutable tier — back it up). Later phases mirror
# the installer's choices and are documented in docs/ai-hermes.md:
#
#   Phase 2: the gateway as a systemd user service (messaging platforms)
#   Phase 3: memory providers (MemPalace over MCP — shared with dsh)
#   TTS: deliberately OUT of scope — audio stories live in ComfyUI
#        workflows (ACE-Step & friends), not in a real-time agent TTS
#        engine. If ever wanted, declare it (vendored buildPythonPackage
#        for neutts/neucodec on nixpkgs torch) — analysis preserved in
#        the doc.
#
# Why bubblewrap, not the upstream podman container: the upstream NixOS
# module's container mode runs the container as root (its docs: "Podman's
# rootful containers require sudo"). Rootless podman is not a configuration
# of that module — it contradicts it — and on this fleet the sudoless path
# failed completely, and the sudo compromise too. Bubblewrap delivers the
# same jail with no daemon, no root, no sudo.
#
# Reproducibility model: everything the stack IS lives in Nix (hash-pinned);
# the only mutable part is what the agent LEARNED (~/.hermes: sessions,
# skills, memories, config) — backed up like precious-bulk weights, never
# rebuilt. The jail's mutable layer is the agent's experience, not its
# configuration.
#
# Isolation model: the jail protects the SYSTEM from the agent (no writes
# outside the user's home, no root, no host state), not the user from
# themselves — the user's own ~/.hermes and declared project dirs are
# deliberately read-write.
#
# Usage (per-user, Home Manager class):
#
#   den.aspects.tux.includes = [ deniac.ai.hermes ];
#   den.aspects.tux.homeManager.deniac.ai.hermes = {
#     enable = true;
#     extraReadwriteDirs = [ "/home/tux/projects" ];
#   };

{ inputs, lib, ... }:
{
  deniac.ai.hermes = {
    description = ''
      Hermes Agent (Nous Research, MIT) sandboxed with bubblewrap — a
      per-user jail where ~/.hermes (sessions, skills, memories) stays
      writable while the host system is read-only. The daemonless,
      rootless alternative to the upstream rootful podman container.
      Phase 1: the core jail; gateway service and MemPalace memory are
      documented follow-ups.
    '';

    homeManager =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.ai.hermes;

      # Everything the jail can execute: hermes itself + declared extras,
      # then the agent's own mutable venv last (its learned tool layer —
      # experience, not configuration; back it up with the rest of
      # ~/.hermes).
      jailPath =
        lib.makeBinPath ([ cfg.package ] ++ cfg.extraPackages)
        + ":\${HOME}/.hermes/venv/bin";

      envArgs =
        lib.concatStringsSep " "
          (lib.mapAttrsToList (k: v: "--setenv ${k} \"${v}\"") cfg.env);

      roBindArgs =
        lib.concatStringsSep " "
          (map (d: "--ro-bind-try ${lib.escapeShellArg d} ${lib.escapeShellArg d}") cfg.extraReadonlyDirs);

      rwBindArgs =
        lib.concatStringsSep " "
          (map (d: "--bind ${lib.escapeShellArg d} ${lib.escapeShellArg d}") cfg.extraReadwriteDirs);

      jail = pkgs.writeShellScriptBin "hermes-jailed" ''
        set -eu
        : "''${HOME:?HOME must be set (the jail binds the real home as the workspace)}"

        exec ${pkgs.bubblewrap}/bin/bwrap \
          --die-with-parent \
          --new-session \
          --dev /dev \
          --proc /proc \
          --tmpfs /tmp \
          --ro-bind /nix/store /nix/store \
          --ro-bind /etc /etc \
          --ro-bind-try /run/current-system/sw /run/current-system/sw \
          --ro-bind-try "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
          --bind "''${HOME}" "''${HOME}" \
          ${roBindArgs} \
          ${rwBindArgs} \
          --unsetenv LD_PRELOAD \
          --setenv PATH "${jailPath}" \
          ${envArgs} \
          -- ${cfg.package}/bin/hermes "$@"
      '';
    in
    {
      options.deniac.ai.hermes = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Install the bubblewrapped Hermes CLI (hermes-jailed).";
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.hermes-agent;
          defaultText = lib.literalExpression "inputs.llm-agents.packages.\${system}.hermes-agent";
          description = ''
            The hermes-agent package. Defaults to the numtide llm-agents
            input already pinned in deniac/flake.nix (the same pin that
            provides dsh) — no new input needed.
          '';
        };

        extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          example = lib.literalExpression "[ pkgs.git pkgs.jq ]";
          description = "Extra packages on the jail's PATH.";
        };

        extraReadonlyDirs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra host directories bind-mounted read-only into the jail.";
        };

        extraReadwriteDirs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "/home/tux/projects" ];
          description = ''
            Extra host directories bind-mounted read-write into the jail
            (the agent's project workspace). The user's own HOME is
            already read-write; these extend the workspace beyond it.
          '';
        };

        env = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          example = { CAMOFOX_URL = "http://localhost:9377"; };
          description = "Extra environment variables set inside the jail.";
        };
      };

      config = lib.mkIf cfg.enable {
        home.packages = [ jail ];
      };
    };
  };
}
