# deniac.ai.halogen-flash-server — halogen-flash-server container.
#
# Runs peonist-ai/halogen-flash-server — a containerised, OpenAI-compatible
# inference server for the halogen-qwen3.8-flash-next model (118 GiB of
# weights, AMD gfx1151 / Strix Halo only) — as a rootful podman container
# under systemd. The first start downloads the model into `modelsDir`;
# afterwards the container opens no outbound connections at all.
#
# Provenance: adapted from the upstream quickstart and host-settings
# sections (github.com/peonist-ai/halogen-flash-server README, image tag
# 0.6.2). A reference copy of that README is kept in the private sister
# repo's research/ dir; this public repo does not link it.
#
# Usage (on a gfx1151 host):
#
#   den.aspects.myhost.includes = [ deniac.ai.halogen-flash-server ];
#   den.aspects.myhost.nixos.deniac.ai.halogen-flash-server.enable = true;
#
# The image hard-rejects every architecture but gfx1151, and the host's GTT
# (GPU-memory) ceiling must be able to address the 118 GiB weights. On a
# host that also runs `deniac.ai.amd.strix`, that ceiling comes from there —
# raise it with a host-side override (e.g.
# `hardware.amd-npu.gpuMemory.ttmSizeGiB = 120`); `gib` is the standalone
# form of that lever for hosts that do not run ai.amd.strix.

{ lib, ... }:
{
  deniac.ai.halogen-flash-server = {
    description = ''
      halogen-flash-server — containerised OpenAI-compatible local
      inference (halogen-qwen3.8-flash-next, 118 GiB weights) for AMD
      Strix Halo (gfx1151). Runs the upstream container image under
      rootful podman as a systemd service; the first start downloads the
      model into `modelsDir`. The API is published on `port` (default
      8731); the engine port is never published (its protocol has no
      authentication).

      Set `enable = true` to activate; leave it false to keep the aspect
      inert. The image hard-rejects every architecture but gfx1151, and
      the host's GTT (GPU-memory) ceiling must be able to address the
      weights — see `gib` (standalone hosts) or `deniac.ai.amd.strix`
      (hosts running the Strix AI stack).
    '';

    nixos =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.ai.halogen-flash-server;

      # The image runs rootful: GPU access (/dev/kfd and /dev/dri, both
      # root:render mode 0660) reaches the container through the service's
      # supplementary groups, passed on by podman's `--group-add
      # keep-groups`.
      podman = config.virtualisation.podman.package;

      # The container's run line, as a script: ExecStart must be a single
      # command, and the flags are assembled from the aspect options.
      runner = pkgs.writeShellScriptBin "halogen-flash-run" ''
        set -euo pipefail
        exec ${podman}/bin/podman run --rm \
          --name halogen-flash-server \
          -p ${toString cfg.port}:${toString cfg.apiPort} \
          --device /dev/kfd \
          --device /dev/dri \
          --group-add keep-groups \
          --ipc=host \
          --ulimit memlock=-1:-1 \
          ${lib.optionalString cfg.download "-e HALOGEN_DOWNLOAD=${lib.escapeShellArg cfg.modelRepo}"} \
          ${lib.concatMapStringsSep " " (k: "-e ${lib.escapeShellArg (k + "=" + cfg.env."${k}")}") (lib.attrNames cfg.env)} \
          -v ${lib.escapeShellArg (cfg.modelsDir + ":+/models" + lib.optionalString (!cfg.download) ":ro")} \
          ${lib.escapeShellArg cfg.image} \
          ${lib.concatStringsSep " " cfg.extraOptions}
      '';
    in
    {
      options.deniac.ai.halogen-flash-server = {
        enable = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = ''
            Start the halogen-flash-server container. The image only runs
            on gfx1151 (Strix Halo) — the build hard-rejects other
            architectures — and needs the model weights (118 GiB) in
            `modelsDir` plus a GTT ceiling that can address them.
          '';
        };

        image = lib.mkOption {
          default = "ghcr.io/peonist-ai/halogen-flash-server:0.6.2";
          type = lib.types.str;
          description = ''
            The container image to run. The API and engine must come from
            the same tag: an API from before 0.5.0 in front of a newer
            engine sends an image as a placeholder with no pixels behind
            it, and the model describes a picture it never received.
          '';
        };

        port = lib.mkOption {
          default = 8731;
          type = lib.types.port;
          description = ''
            Host port the OpenAI-compatible API is published on. The
            firewall hole for this port is added with `lib.mkDefault`, so
            a host's own `services.firewall.allowedTCPPorts` wins.
          '';
        };

        apiPort = lib.mkOption {
          default = 8731;
          type = lib.types.port;
          description = ''
            Container-side API port (the image's `HALOGEN_API_PORT`). The
            engine's own port (default 8730) is never published — its
            protocol has no authentication.
          '';
        };

        modelsDir = lib.mkOption {
          default = "/var/lib/halogen-models";
          type = lib.types.str;
          description = ''
            Host directory mounted as the container's `/models` volume —
            the only mount the container needs (the weights repo carries
            the tokenizer). With `download = true` it is mounted
            read-write (the weights are downloaded into it on first
            start); otherwise read-only.

            The default path is created by systemd as the service's
            StateDirectory, so it needs no host setup. A non-default path
            must already exist; the service still creates
            /var/lib/halogen-models as its StateDirectory (unused in
            that case, harmless).
          '';
        };

        download = lib.mkOption {
          default = true;
          type = lib.types.bool;
          description = ''
            true (default): set `HALOGEN_DOWNLOAD` so the first start
            fetches the weights from Hugging Face (118 GiB — the transfer
            resumes if interrupted) and mount the volume read-write.
            false: the weights are already in `modelsDir` (e.g. fetched
            with `hf download peonist-ai/halogen-qwen3.8-flash-next
            --local-dir <modelsDir>`); the container then opens no
            outbound connections at all, and the volume is mounted
            read-only.
          '';
        };

        modelRepo = lib.mkOption {
          default = "peonist-ai/halogen-qwen3.8-flash-next";
          type = lib.types.str;
          description = ''
            The Hugging Face repo `HALOGEN_DOWNLOAD` points at (weights +
            tokenizer).
          '';
        };

        env = lib.mkOption {
          default = { };
          type = lib.types.attrsOf lib.types.str;
          description = ''
            Extra environment variables for the container. The levers
            that matter (upstream "Configuration" section):
            `HALOGEN_MAX_TOKENS_DEFAULT` (per-request budget),
            `HALOGEN_REASONING_EFFORT`, `HALOGEN_KV_POOL_POSITIONS`
            (concurrent-conversation pool), `HALOGEN_HOST_RESERVE_GIB`
            (RAM left for the file cache — the server needs it for its
            on-disk lookup table), and `HALOGEN_CK_OVERLAY` (speed-arm
            checkpoint overlay).
          '';
        };

        gib = lib.mkOption {
          default = null;
          type = lib.types.nullOr lib.types.ints.positive;
          description = ''
            GPU-memory (GTT) ceiling in GiB, emitted as the `ttm`
            `pages_limit` modprobe option (page count computed: GiB *
            262144) — the standalone form of the lever
            `deniac.ai.amd.strix.vram` provides through nix-amd-ai. The
            118 GiB weights need a ceiling above ~118 GiB; 120 is the
            value for a 128 GB Strix Halo (upstream's own 128 GB row
            measures at 124 GiB).

            **Do not set this on a host that also runs
            `deniac.ai.amd.strix` with a `vram` profile** — both would
            define the same modprobe option and the eval would fail. On
            such hosts raise the ceiling through
            `hardware.amd-npu.gpuMemory.ttmSizeGiB` / `.pagePoolSizeGiB`
            instead (a host-side override that wins over the profile's
            `lib.mkDefault` leaves).

            null (default) leaves the kernel default untouched (~27 GB
            addressable — the server will not start at that ceiling).
          '';
        };

        extraOptions = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.str;
          description = ''
            Extra `podman run` flags, appended verbatim after every
            managed flag (escape hatch — the host owns what it adds).
          '';
        };
      };

      config =
        lib.mkIf cfg.enable {
          # The podman engine + its /etc/containers configuration (CNI
          # plugin dirs etc.) — a host that set virtualisation.podman
          # itself wins (mkDefault).
          virtualisation.podman.enable = lib.mkDefault true;

          services.firewall.allowedTCPPorts = lib.mkDefault [ cfg.port ];

          # Rootful podman under systemd. `SupplementaryGroups` +
          # `--group-add keep-groups` carry render/video into the
          # container for /dev/kfd and /dev/dri.
          systemd.services.halogen-flash = lib.mkDefault {
            description = "halogen-flash-server — OpenAI-compatible local inference (halogen-qwen3.8-flash-next)";
            wantedBy = [ "multi-user.target" ];
            after = [ "local-fs.target" "network-online.target" ];
            wants = [ "network-online.target" ];
            serviceConfig = {
              StateDirectory = "halogen-models";
              SupplementaryGroups = [ "render" "video" ];
              Restart = "always";
              RestartSec = "10s";
              # The first start downloads 118 GiB of weights — hours on a
              # slow link. systemd must not time the start out.
              TimeoutStartSec = "infinity";
              # Clean a leftover from an unclean stop so the fixed
              # container name does not block the next start.
              ExecStartPre = "${podman}/bin/podman rm -f --ignore halogen-flash-server";
              ExecStart = "${runner}/bin/halogen-flash-run";
            };
          };
        }
        // lib.mkIf (cfg.gib != null) {
          # Standalone-host GTT ceiling. Same option nix-amd-ai uses (the
          # ttm `pages_limit` modprobe option) — see `gib` for the
          # do-not-combine contract with ai.amd.strix.vram.
          boot.extraModprobeConfig = lib.mkDefault
            ("options ttm pages_limit=${toString (cfg.gib * 262144)}\n");
        };
    };
  };
}
