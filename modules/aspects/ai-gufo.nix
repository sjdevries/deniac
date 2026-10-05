# deniac.ai.gufo — gufo inference container (rootless podman).
#
# Runs gufo-org/gufo — an open-source (MIT), OpenAI-compatible local
# inference engine for AMD Strix Halo (gfx1151) — as a **rootless**
# podman container under a systemd *user* service, using the reproducible
# ghcr.io/gufo-org/toolboxes image (built from pinned Nix derivations).
#
# Default model: Qwen3.8 Flash-Next (Unsloth UD-Q4_K_XL) with the shared
# Q8_0 MTP predictor — the closest open analogue to the closed
# halogen-qwen3.8-flash-next box.
#
# Usage (on a gfx1151 host):
#   den.aspects.myhost.includes = [ deniac.ai.gufo ];
#   den.aspects.myhost.nixos.deniac.ai.gufo.enable = true;
#
# Rootless: the container runs as `user` (default "gufo"), which the
# aspect creates as a system user in the render/video groups with
# lingering enabled so the user service starts at boot. Pre-stage the
# weights in `modelsDir` (mounted read-only) before first start — this
# aspect does not download them.
#
# MEMORY CONTENTION — read before enabling alongside other AI aspects.
# gufo, halogen, and ComfyUI all draw from the SAME ~124 GiB unified
# memory pool on a 128 GB Strix Halo. They are NOT meant to be resident
# together at full size: halogen (118 GiB) + ComfyUI OOMs the box, and
# gufo at full Flash-Next context behaves the same way. Run at most one
# large LLM at a time. See the aspect `description` and docs for the
# swap strategy.

{ lib, ... }:
{
  deniac.ai.gufo = {
    description = ''
      gufo — containerised, open-source (MIT) OpenAI-compatible local
      inference for AMD Strix Halo (gfx1151). Runs the reproducible
      `ghcr.io/gufo-org/toolboxes/gufo-runtime` image (built from pinned
      Nix derivations) under **rootless** podman as a systemd user
      service. Default model: Qwen3.8 Flash-Next (Unsloth UD-Q4_K_XL) +
      shared Q8_0 MTP — the open counterpart to the closed
      `halogen-qwen3.8-flash-next`. The API is published on `port`
      (default 8080).

      Set `enable = true` to activate; leave it false (the default) to
      keep the aspect inert. The image targets gfx1151 only, and the
      host's GTT (GPU-memory) ceiling must be able to address the
      weights — see `gib` (standalone hosts) or `deniac.ai.amd.strix`.

      MEMORY CONTENTION: gufo, `deniac.ai.halogen-flash-server`, and
      `deniac.ai.comfyui` all draw from the same ~124 GiB unified pool.
      Do not enable two of them at full size at once — halogen + ComfyUI
      OOMs the box, and gufo at full Flash-Next context does too. Pick
      one large LLM backend per boot. To run ComfyUI for image/video
      generation, keep the LLM off or point `model` at a smaller GGUF
      that leaves room (gufo supports many models; a smaller target can
      coexist with image gen where the 118 GiB Flash-Next cannot).
    '';

    nixos =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.ai.gufo;

      # The podman engine + its /etc/containers configuration. A host
      # that set virtualisation.podman itself wins (mkDefault).
      podman = config.virtualisation.podman.package;

      # Speculative decoding: MTP with the shared predictor, or plain AR.
      speculativeArgs =
        if cfg.speculative == "mtp" then
          "--speculative mtp --mtp-model ${lib.escapeShellArg cfg.mtpModel}"
        else
          "--speculative off";

      # Restart-safe prompt cache (gufo --cache-disk). Lives under the
      # read-only /models mount's sibling is not writable, so it is placed
      # in the container's own home (gufo user's state), not /models.
      cacheDiskArg =
        if cfg.cacheDisk then "--cache-disk /home/gufo/.cache/gufo" else "";

      # The container's run line, as a script: ExecStart must be a single
      # command, and the flags are assembled from the aspect options.
      # Rootless: --userns=keep-id maps the container's 1000:1000 to the
      # service user; --group-add keep-groups carries render/video in for
      # /dev/kfd and /dev/dri.
      runner = pkgs.writeShellScriptBin "gufo-run" ''
        set -euo pipefail
        exec ${podman}/bin/podman run --rm \
          --name gufo \
          --userns=keep-id:uid=1000,gid=1000 \
          --device /dev/kfd \
          --device /dev/dri \
          --group-add keep-groups \
          --ulimit memlock=-1:-1 \
          ${lib.optionalString (cfg.memoryLow != null) "--cgroup-parent=gufo.slice "} \
          -p ${toString cfg.port}:${toString cfg.apiPort} \
          -v ${lib.escapeShellArg (cfg.modelsDir + ":/models:ro")} \
          ${lib.escapeShellArg cfg.image} \
          gufo serve --host 0.0.0.0 --port ${toString cfg.apiPort} llm \
            --model ${lib.escapeShellArg cfg.model} \
            ${speculativeArgs} \
            --sessions ${toString cfg.sessions} \
            --context ${toString cfg.context} \
            ${cacheDiskArg} \
            ${lib.concatStringsSep " " cfg.serveArgs} \
            ${lib.concatStringsSep " " cfg.extraOptions}
      '';
    in
    {
      options.deniac.ai.gufo = {
        enable = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = ''
            Start the gufo container. The image only runs on gfx1151
            (Strix Halo) and needs the model weights pre-staged in
            `modelsDir` plus a GTT ceiling that can address them.
            Default false: the aspect is inert until explicitly enabled,
            so it never contends for memory by surprise.
          '';
        };

        image = lib.mkOption {
          default = "ghcr.io/gufo-org/toolboxes/gufo-runtime:latest";
          type = lib.types.str;
          description = ''
            The container image to run. `:latest` is the stable floating
            alias. For reproducibility, pin to an immutable `X.Y.Z` tag
            or the `sha-<full-gufo-revision>` tag the toolboxes repo
            publishes alongside each release.
          '';
        };

        port = lib.mkOption {
          default = 8080;
          type = lib.types.port;
          description = ''
            Host port the OpenAI-compatible API is published on. The
            firewall hole is additive: same-priority list definitions
            concatenate, so a host that sets
            `networking.firewall.allowedTCPPorts` keeps its own ports and
            gains this one (replace the whole list with `lib.mkForce`).
          '';
        };

        apiPort = lib.mkOption {
          default = 8080;
          type = lib.types.port;
          description = ''
            Container-side port gufo binds (`gufo serve --port`). Kept
            separate from `port` so the host mapping and the in-container
            bind can differ if needed.
          '';
        };

        modelsDir = lib.mkOption {
          default = config.deniac.ai.model-store.paths.llm or "/var/lib/ai-models/llm";
          type = lib.types.str;
          description = ''
            Host directory mounted read-only as the container's `/models`
            volume.

            Batteries-included (Stability-Matrix-style sharing): defaults
            to the shared model-store's `llm` subdir
            (`deniac.ai.model-store.paths.llm`), so when the
            `deniac.ai.model-store` aspect is included, gufo reads from
            the shared tree automatically — and follows a custom store
            `root`. With no store included it falls back to the canonical
            `/var/lib/ai-models/llm`. Override for a standalone
            (non-shared) layout.

            Pre-populate it with the model files (see `model` /
            `mtpModel` defaults for the expected layout). Unlike halogen,
            gufo has no in-container download — weights are fetched
            out-of-band (e.g. `hf download unsloth/Qwen3.8-Flash-Next-GGUF
            --include "UD-Q4_K_XL/*" "MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"
            --local-dir <modelsDir>/qwen3.8-flash-next`) and the mount is
            always read-only.
          '';
        };

        model = lib.mkOption {
          default = "/models/qwen3.8-flash-next/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf";
          type = lib.types.str;
          description = ''
            Container path to the target GGUF (the first shard; gufo's
            loader discovers the remaining shards from it). Point at a
            smaller quantisation to leave memory for a co-resident
            workload.
          '';
        };

        speculative = lib.mkOption {
          default = "mtp";
          type = lib.types.enum [ "mtp" "off" ];
          description = ''
            Speculative decoding mode. `mtp` (default) uses the shared
            Q8_0 MTP predictor (`mtpModel`); `off` runs plain
            autoregressive decode and ignores `mtpModel`.
          '';
        };

        mtpModel = lib.mkOption {
          default = "/models/qwen3.8-flash-next/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf";
          type = lib.types.str;
          description = ''
            Container path to the shared MTP predictor, used when
            `speculative = "mtp"`.
          '';
        };

        sessions = lib.mkOption {
          default = 1;
          type = lib.types.ints.positive;
          description = ''
            `gufo serve --sessions N`: the bounded execution-session
            pool (concurrent generations), not remembered conversations.
            More sessions use more memory.
          '';
        };

        context = lib.mkOption {
          default = 0;
          type = lib.types.ints.unsigned;
          description = ''
            `gufo serve --context N`: per-session context capacity. 0
            (default) uses the model's native context (262144 for
            Flash-Next). Lower it to reduce memory when full context is
            not needed.
          '';
        };

        cacheDisk = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = ''
            Enable gufo's restart-safe prompt cache (`--cache-disk`),
            stored in the container user's home (not the read-only
            /models mount). Costs disk for faster warm restarts.
          '';
        };

        user = lib.mkOption {
          default = "gufo";
          type = lib.types.str;
          description = ''
            The unprivileged user the rootless container runs as. The
            aspect creates it as a system user in the `render` and `video`
            groups (for /dev/kfd and /dev/dri) with lingering enabled so
            the user service starts at boot. Override to reuse an existing
            user (mkDefault, so a host definition wins).
          '';
        };

        gib = lib.mkOption {
          default = null;
          type = lib.types.nullOr lib.types.ints.positive;
          description = ''
            GPU-memory (GTT) ceiling in GiB, emitted as the `ttm`
            `pages_limit` modprobe option (GiB * 262144) — the standalone
            form of the lever `deniac.ai.amd.strix.vram` provides through
            nix-amd-ai. Same do-not-combine contract as the halogen
            aspect: on a host that also runs `ai.amd.strix` with a `vram`
            profile, size the ceiling through
            `hardware.amd-npu.gpuMemory.ttmSizeGiB` instead, or the two
            `pages_limit` lines concatenate silently and the effective
            ceiling follows module ordering you do not control.

            null (default) leaves the kernel default (~27 GB) — the server
            will not start at that ceiling.
          '';
        };

        serveArgs = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.str;
          description = ''
            Extra `gufo serve` arguments, appended verbatim after the
            managed ones (escape hatch — e.g. `[ "--api-key" "..." ]` for
            bearer auth, though note that lands the key in the Nix store).
          '';
        };

        memoryLow = lib.mkOption {
          default = null;
          type = lib.types.nullOr lib.types.str;
          example = "32G";
          description = ''
            cgroup v2 `memory.low` for the container, as a systemd byte
            size (e.g. `"32G"`). Protects the container's pages — above
            all the mmap'd GGUF weights — from memory reclaim: under
            pressure the kernel evicts every other cgroup first, and
            touches this one only when nothing else can absorb the hit.

            Same eviction mechanism as the halogen aspect's option of
            the same name: gufo maps the GGUF weights, so they are
            accounted as `file` memory (page cache) — the kernel's
            *preferred* reclaim target, cheap to re-read for anything
            but a live inference request. A streaming workload (rsync,
            defrag, backups) can push the model out of RAM and stall
            or kill the server mid-request; with `swap = 0` the file
            pages are the only reclaimable memory, so they are exactly
            what goes.

            Rootless shape: the container is nested under a dedicated
            slice inside the service user's own cgroup tree
            (`--cgroup-parent=gufo.slice`, resolved by the user's
            systemd manager to
            `user-<uid>.slice/user@<uid>.service/gufo.slice`), and
            `MemoryLow` is set on `systemd.user.slices."gufo"` —
            cgroup v2 protection is inherited by the whole subtree.
            The slice is what makes it durable across podman's
            per-start random scope ids. The user manager's memory
            controller is delegated by NixOS, so the protection is
            effective within the user's allocation.

            Size it at or above the container's resident working set
            (weights + KV pool + runtime) with a little slack. It is a
            protection floor, not a reservation. Note the whole user
            slice is the kernel's unit of comparison against *other*
            users' slices too — keep the value inside what the user's
            session is meant to hold.

            null (default) leaves the container in podman's default
            placement with no reclaim protection. A host's own
            `--cgroup-parent` in `extraOptions` overrides the managed
            one (last flag wins).
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

      # `lib.mkMerge`, not `//`: `lib.mkIf` yields a tagged def, and `//`
      # would merge the tag FIELDS instead of the branches' contents.
      config =
        lib.mkMerge [
          (lib.mkIf cfg.enable {
            # The podman engine + configuration (mkDefault: a host that
            # set it itself wins).
            virtualisation.podman.enable = lib.mkDefault true;

            # The API port, reachable from the host network. Plain
            # definition (priority 100), not mkDefault — base modules
            # define `allowedTCPPorts` plainly and would filter a
            # mkDefault out; same-priority list defs concatenate.
            networking.firewall.allowedTCPPorts = [ cfg.port ];

            # Rootless service user: a system user in render/video with
            # lingering, so its user manager (and the service) starts at
            # boot. mkDefault so a host that already defines this user
            # wins.
            users.groups.${cfg.user} = lib.mkDefault { };
            users.users.${cfg.user} = lib.mkDefault {
              isSystemUser = true;
              group = cfg.user;
              extraGroups = [ "render" "video" ];
              linger = true;
            };

            # Rootless podman under a systemd USER service. The user's
            # manager runs it; `--userns=keep-id` maps the container's
            # 1000:1000 to this user, and `--group-add keep-groups`
            # carries render/video in for /dev/kfd and /dev/dri.
            systemd.user.services.gufo = {
              description = "gufo — OpenAI-compatible local inference (Qwen3.8 Flash-Next + MTP)";
              wantedBy = [ "default.target" ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              serviceConfig = {
                Restart = "always";
                RestartSec = "10s";
                # First load maps a large model; do not time it out.
                TimeoutStartSec = "infinity";
                # Clean a leftover from an unclean stop so the fixed
                # container name does not block the next start.
                ExecStartPre = "${podman}/bin/podman rm -f --ignore gufo";
                ExecStart = "${runner}/bin/gufo-run";
              };
            };
          })
          (lib.mkIf (cfg.memoryLow != null) {
            # Reclaim protection for the container's pages (see
            # `memoryLow`). Rootless: the slice lives in the service
            # user's own manager tree (`systemd.user.slices`), where
            # podman nests the container via `--cgroup-parent`. The
            # unit is only instantiated when something lands under it.
            systemd.user.slices."gufo".sliceConfig.MemoryLow = cfg.memoryLow;
          })
          (lib.mkIf (cfg.gib != null) {
            # Standalone-host GTT ceiling (see `gib` for the
            # do-not-combine contract with ai.amd.strix.vram). Plain
            # definition — the lines type concatenates same-priority
            # defs so the host's own modprobe options survive alongside.
            boot.extraModprobeConfig =
              "options ttm pages_limit=${toString (cfg.gib * 262144)}\n";
          })
        ];
    };
  };
}
