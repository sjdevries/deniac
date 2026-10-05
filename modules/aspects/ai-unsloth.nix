# deniac.ai.unsloth — Unsloth Studio as a rootless podman service.
#
# Runs Unsloth Studio — the headless web-UI *server* form of
# unslothai/unsloth — as a rootless podman container under a systemd
# *user* service, using the AMD ROCm image (`unsloth/unsloth-rocm`).
#
# Three forms, one server:
#   * Unsloth Desktop — native GUI app (Windows/macOS/Linux). NOT a
#     service; it wraps the same engine. Not what this aspect runs.
#   * Unsloth Studio  — the web-UI server (`unsloth studio`). THIS
#     aspect. The form you actually run headless on a NixOS host.
#   * Unsloth Core    — the pip package (code-based).
#
# Batteries-included: the HuggingFace cache is mounted from the shared
# `ai.model-store`'s `hfCache`, so models Studio downloads are shared
# with gufo / ComfyUI / any other store consumer (content-addressed,
# downloaded once). The service user joins the store group for read-write
# access to that cache.
#
# License: Unsloth is dual-licensed Apache-2.0 (core) + AGPL-3.0
# (Studio UI). The image is pulled from Docker Hub, not built here.
#
# SECURITY: Studio ships server-side tools ON by default. This aspect
# binds the published ports to `host` (default loopback 127.0.0.1) —
# do NOT expose it to a network without a password (`passwordFile`) and
# without knowing the tools are reachable.
#
# Usage:
#   den.aspects.igloo.includes = [ deniac.ai.model-store deniac.ai.unsloth ];
#   den.aspects.igloo.nixos.deniac.ai.unsloth.enable = true;
#   den.aspects.igloo.nixos.deniac.ai.unsloth.passwordFile =
#     config.age.secrets.unsloth-studio.path;   # file: UNSLOTH_STUDIO_PASSWORD=...

{ lib, ... }:
{
  deniac.ai.unsloth = {
    description = ''
      Unsloth Studio (the headless web-UI server of unslothai/unsloth) as
      a rootless podman container under a systemd user service, using the
      AMD ROCm image `unsloth/unsloth-rocm`. Studio runs and trains LLMs
      / diffusion / audio models and serves an OpenAI-compatible API plus
      a JupyterLab backend.

      Batteries-included sharing: the HuggingFace cache is mounted from
      the shared `ai.model-store` `hfCache`, so weights Studio pulls are
      shared with every other store consumer. The service user joins the
      store group for read-write cache access.

      NOTE: this is the Studio SERVER, not the Desktop GUI app (which is
      not a service). Bind defaults to loopback — Studio ships server-side
      tools on; set `passwordFile` before exposing it.
    '';

    nixos =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.ai.unsloth;
      podman = config.virtualisation.podman.package;
      # Single predicate for "this bind is reachable beyond the box".
      # Shared by the firewall hole and the safety warning so the two can
      # never disagree about what counts as exposed.
      isLoopback = cfg.host == "127.0.0.1" || cfg.host == "localhost";
      # The shared store group (follows the store's `group` if included,
      # else the canonical `aimodels`). The service user joins it so the
      # mounted HF cache is read-write.
      storeGroup = config.deniac.ai.model-store.group or "aimodels";
      # Pass the admin password via a podman --env-file (KEY=VALUE) so it
      # never appears on the command line / process list.
      envFileArg =
        if cfg.passwordFile != null
        then "--env-file ${lib.escapeShellArg cfg.passwordFile}"
        else "";
      runner = pkgs.writeShellScriptBin "unsloth-run" ''
        #!${pkgs.runtimeShell}
        set -eu
        exec ${podman}/bin/podman run --rm --name unsloth \
          --userns=keep-id:uid=1000,gid=1000 \
          --device /dev/kfd --device /dev/dri \
          --group-add keep-groups \
          --ipc=host \
          -p ${cfg.host}:${toString cfg.port}:8000 \
          -p ${cfg.host}:${toString cfg.jupyterPort}:8888 \
          -v ${lib.escapeShellArg (cfg.modelsDir + ":/workspace/.cache/huggingface")} \
          -v ${lib.escapeShellArg (cfg.studioDataDir + ":/opt/unsloth-studio")} \
          ${envFileArg} \
          ${lib.escapeShellArg cfg.image} \
          unsloth studio -H 0.0.0.0 -p 8000 ${toString cfg.serveArgs}
      '';
    in
    {
      options.deniac.ai.unsloth = {
        enable = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = "Start the Studio container. Inert by default.";
        };

        image = lib.mkOption {
          default = "unsloth/unsloth-rocm:latest";
          type = lib.types.str;
          description = ''
            Container image. `unsloth/unsloth-rocm` is the AMD ROCm
            build; the NVIDIA build is `unsloth/unsloth`. Pin to a
            `sha-<rev>` tag for reproducibility.
          '';
        };

        host = lib.mkOption {
          default = "127.0.0.1";
          type = lib.types.str;
          description = ''
            Host-side bind address for the published ports. Loopback by
            default — Studio ships server-side tools ON, so only set a
            routable address with a `passwordFile` in place.
          '';
        };

        port = lib.mkOption {
          default = 8000;
          type = lib.types.port;
          description = "Host port for the Studio web UI / OpenAI-compatible API.";
        };

        jupyterPort = lib.mkOption {
          default = 8888;
          type = lib.types.port;
          description = "Host port for the JupyterLab backend.";
        };

        modelsDir = lib.mkOption {
          default = config.deniac.ai.model-store.hfCache or "/var/lib/ai-models/.hf-cache";
          type = lib.types.str;
          description = ''
            Host dir mounted as the container's HuggingFace cache
            (`/workspace/.cache/huggingface`). Defaults to the shared
            `ai.model-store` `hfCache` so downloads are shared across
            consumers; falls back to the canonical path with no store.
          '';
        };

        studioDataDir = lib.mkOption {
          default = "/var/lib/unsloth-studio";
          type = lib.types.str;
          description = ''
            Host dir for persistent Studio state
            (`/opt/unsloth-studio`): settings, installed models index,
            chat history. Provision on a persisted mount.
          '';
        };

        passwordFile = lib.mkOption {
          default = null;
          type = lib.types.nullOr lib.types.str;
          description = ''
            Path to an env-file (KEY=VALUE) containing
            `UNSLOTH_STUDIO_PASSWORD=<secret>`, passed to the container
            via `--env-file` so the password never hits the command line.
            Point at a sops/agenix-managed secret. Strongly recommended
            before exposing Studio beyond loopback.
          '';
        };

        user = lib.mkOption {
          default = "unsloth";
          type = lib.types.str;
          description = "Unprivileged rootless service user (created with linger).";
        };

        serveArgs = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.str;
          description = "Extra `unsloth studio` args, appended verbatim.";
        };
      };

      config =
        lib.mkMerge [
          {
            # Safety net for the "exposed without a password" footgun.
            # Studio ships server-side tools ON by default (JupyterLab,
            # code execution), so a routable bind with no `passwordFile`
            # means anyone who can reach the port can run code on this
            # box. The aspect cannot enforce the secret (only the host
            # knows where it lives), but it refuses to let the
            # combination pass silently: the build prints a loud warning
            # naming the fix. (Inside `config` — this den aspect shape
            # does not accept a top-level `warnings`.)
            warnings = lib.optionals (cfg.enable && !isLoopback && cfg.passwordFile == null) [
              ''
                deniac.ai.unsloth: Studio is exposed on ${cfg.host}:${toString cfg.port} (JupyterLab on ${toString cfg.jupyterPort}) with NO passwordFile set — the server-side tools (JupyterLab, code execution) are ON by default, so this is remote code execution for anyone who can reach the port. Set `deniac.ai.unsloth.passwordFile` to a sops/agenix-managed env-file containing `UNSLOTH_STUDIO_PASSWORD=<secret>`, or keep the bind on loopback (the default).
              ''
            ];
          }
          (lib.mkIf cfg.enable {
            virtualisation.podman.enable = lib.mkDefault true;

            # Ensure the shared store group exists (mkDefault: the store's
            # own definition wins when it is included).
            users.groups.${storeGroup} = lib.mkDefault { };

            users.groups.${cfg.user} = lib.mkDefault { };
            users.users.${cfg.user} = lib.mkDefault {
              isSystemUser = true;
              group = cfg.user;
              # render/video for /dev/kfd + /dev/dri; storeGroup for the
              # shared HF cache.
              extraGroups = [ "render" "video" storeGroup ];
              linger = true;
            };

            # Publish the ports only when bound to a routable address;
            # loopback needs no firewall hole. Same `isLoopback`
            # predicate the safety warning uses.
            networking.firewall.allowedTCPPorts =
              lib.optionals (!isLoopback) [ cfg.port cfg.jupyterPort ];

            systemd.user.services.unsloth = {
              wantedBy = [ "default.target" ];
              serviceConfig = {
                Restart = "always";
                RestartSec = "5s";
                # Model load + first-time setup can take minutes.
                TimeoutStartSec = "infinity";
                ExecStartPre = "${podman}/bin/podman rm -f --ignore unsloth";
                ExecStart = "${runner}/bin/unsloth-run";
              };
            };
          })
        ];
    };
  };
}
