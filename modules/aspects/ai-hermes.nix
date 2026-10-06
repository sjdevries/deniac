# deniac.ai.hermes — Hermes Agent (Nous Research) in a bubblewrap jail.
#
# Hermes is a self-improving agent whose mutable state (~/.hermes: sessions,
# skills, memories, and a pip/npm layer it owns) must stay writable, while
# the HOST system must stay protected. The upstream NixOS module's answer
# is a rootful podman container — which on this fleet proved unusable
# rootless (the module runs the container as root by design; sudoless
# podman is not a configuration of it, and even the sudo compromise did
# not work). Bubblewrap gives the same jail with no daemon, no root, and
# no sudo: the agent runs as the user, inside a mount namespace where the
# system is read-only and the home directory is the workspace.
#
# TTS strategy (the lesson from the old python311.withPackages [neutts]
# wrapper, which rotted when nixpkgs dropped neutts):
#   - DECLARE in Nix what is stable: espeak-ng, ffmpeg, socket paths.
#   - PIP-INSTALL in the jail what is mutable: `pip install neutts` into
#     ~/.hermes/venv (neutts lives on PyPI; nixpkgs churn cannot break
#     the agent's Python layer anymore).
# The jail's mutable layer IS the TTS configuration strategy.
#
# Isolation model: the jail protects the SYSTEM from the agent (no writes
# outside the user's home, no root, no host state), not the user from
# themselves — the agent's own ~/.hermes, ~/.npm and declared project
# dirs are deliberately read-write.
#
# Usage (per-user, Home Manager class):
#
#   den.aspects.tux.includes = [ deniac.ai.hermes ];
#   den.aspects.tux.homeManager.deniac.ai.hermes = {
#     enable = true;
#     tts.enable = true;
#     extraReadwriteDirs = [ "/home/tux/projects" ];
#   };
#
# Then bootstrap the mutable TTS layer once, inside the jail:
#
#   hermes-jailed bash -c 'python3 -m venv ~/.hermes/venv &&
#     ~/.hermes/venv/bin/pip install neutts soundfile'
#
# (v1 scope: the interactive jail binary. The gateway as a systemd user
# service and the MemPalace memory provider over MCP are documented
# follow-ups — see docs/ai-hermes.md.)

{ inputs, lib, ... }:
{
  deniac.ai.hermes = {
    description = ''
      Hermes Agent (Nous Research, MIT) sandboxed with bubblewrap — a
      per-user jail where ~/.hermes (sessions, skills, memories, and the
      agent's own pip layer) stays writable while the host system is
      read-only. The daemonless alternative to the upstream rootful
      podman container: no sudo, no container image, no root. TTS is
      split by mutability: espeak-ng/ffmpeg declared in Nix, neutts
      pip-installed into the jail's ~/.hermes/venv.
    '';

    homeManager =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.ai.hermes;

      # Everything the jail can execute: hermes itself + declared extras
      # + the mutable venv (last, so `pip install`ed CLIs win).
      jailPath =
        lib.makeBinPath ([ cfg.package ] ++ cfg.extraPackages)
        + ":''${HOME}/.hermes/venv/bin";

      # TTS wiring: stable pieces declared in Nix; the heavy voice model
      # (neutts) is expected in the mutable venv, not here.
      ttsPackages = [ pkgs.espeak-ng pkgs.ffmpeg ];
      ttsEnv = {
        ESPEAK_DATA_PATH = "${pkgs.espeak-ng}/share/espeak-ng-data";
        PULSE_SERVER = "unix:''${XDG_RUNTIME_DIR}/pulse/native";
      };

      envArgs =
        lib.concatStringsSep " "
          (lib.mapAttrsToList (k: v: "--setenv ${k} \"${v}\"") (cfg.env // ttsEnv));

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
          example = { HERMES_MODEL = "qwen/qwen3.6-27b"; };
          description = "Extra environment variables set inside the jail.";
        };

        tts.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Declare the stable TTS pieces: espeak-ng + ffmpeg on the
            jail PATH, ESPEAK_DATA_PATH and PULSE_SERVER wired to the
            user's audio socket. The heavy voice model (neutts, PyPI)
            is installed ONCE into the mutable ~/.hermes/venv — see the
            bootstrap command in docs/ai-hermes.md.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        home.packages = [ jail ] ++ lib.optionals cfg.tts.enable ttsPackages;
      };
    };
  };
}
