# deniac.ai.halogen-flash-server — halogen-flash-server container.
#
# Runs peonist-ai/halogen-flash-server — a containerised, OpenAI-compatible
# inference server for the halogen-qwen3.8-flash-next model (118 GiB of
# weights, AMD gfx1151 / Strix Halo only) — as a rootful podman container
# under systemd. The first start downloads the model into `modelsDir`;
# afterwards the container opens no outbound connections at all.
#
# Provenance: adapted from the upstream quickstart and host-settings
# sections (github.com/peonist-ai/halogen-flash-server README, first at
# image tag 0.6.2; the `image` default now tracks upstream at 0.16.2).
#
# Usage (on a gfx1151 host):
#
#   den.aspects.igloo.includes = [ deniac.ai.halogen-flash-server ];
#   den.aspects.igloo.nixos.deniac.ai.halogen-flash-server.enable = true;
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
          ${lib.optionalString (cfg.memoryLow != null) "--cgroup-parent=halogen.slice "} \
          ${lib.optionalString cfg.download "-e HALOGEN_DOWNLOAD=${lib.escapeShellArg cfg.modelRepo}"} \
          ${lib.concatMapStringsSep " " (k: "-e ${lib.escapeShellArg (k + "=" + cfg.env."${k}")}") (lib.attrNames cfg.env)} \
          -v ${lib.escapeShellArg (cfg.modelsDir + ":/models" + lib.optionalString (!cfg.download) ":ro")} \
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
          default = "ghcr.io/peonist-ai/halogen-flash-server:0.16.2";
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
            firewall hole for this port is additive: same-priority list
            definitions concatenate, so a host that sets
            `networking.firewall.allowedTCPPorts` keeps its own ports and
            gains this one (replace the whole list with `lib.mkForce`).
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
            `deniac.ai.amd.strix` with a `vram` profile.** Both write
            `options ttm pages_limit=…` to `boot.extraModprobeConfig`,
            which is `types.lines` — so the eval does **not** fail. The
            two lines concatenate silently and the effective ceiling is
            decided by module ordering you do not control.

            Verified 2026-09-15 with `gib = 124` and
            `hardware.amd-npu.gpuMemory.ttmSizeGiB = 99` both set: the
            generated config carries **both** lines
            (`pages_limit=25952256 page_pool_size=27262976` then
            `pages_limit=32505856`), and **reordering the host's
            `includes` list does not change which one lands last** — the
            order comes from the import structure (nix-amd-ai is
            imported at the top of the strix aspect module), not from
            the order you write `includes` in. Scalar module params are
            last-write-wins, so the result follows that ordering rather
            than your intent. Treat a silent wrong-ceiling as the
            failure mode here, not a loud error.

            On such hosts raise the ceiling through
            `hardware.amd-npu.gpuMemory.ttmSizeGiB` / `.pagePoolSizeGiB`
            instead (a host-side override that wins over the profile's
            `lib.mkDefault` leaves).

            The reverse case is safe by construction: on a host that does
            **not** include `ai.amd.strix`, `hardware.amd-npu.*` is not
            defined at all — nix-amd-ai's module arrives only via that
            aspect's `imports` — so `gib` cannot collide there; it is the
            only source of the option.

            null (default) leaves the kernel default untouched (~27 GB
            addressable — the server will not start at that ceiling).
          '';
        };

        memoryLow = lib.mkOption {
          default = null;
          type = lib.types.nullOr lib.types.str;
          example = "84G";
          description = ''
            cgroup v2 `memory.low` for the container, as a systemd byte
            size (e.g. `"84G"`). Protects the container's pages — above
            all the mmap'd model weights — from memory reclaim: under
            pressure the kernel evicts every other cgroup first, and
            touches this one only when nothing else can absorb the hit.

            Why this exists: the server opens the weights with `mmap`,
            so they are accounted as `file` memory (page cache) — and
            clean page cache is the kernel's *preferred* reclaim
            target, because re-reading it is normally cheap. For a
            live inference request it is not: a streaming workload
            (rsync, defrag, backups) can push the whole model out of
            RAM, and the re-fault mid-request stalls or kills the
            server. With `swap = 0` on the host the file pages are the
            only reclaimable memory, so they are exactly what goes.

            Implemented by nesting the container under a dedicated
            slice (`--cgroup-parent=halogen.slice`, via podman's
            systemd cgroup manager) and setting `MemoryLow` on that
            slice — cgroup v2 protection is inherited by the whole
            subtree. The slice is what makes it durable: podman gives
            every container a fresh random `libpod-*.scope` id on
            each start, so a value written into the scope at runtime
            vanishes with it, while the declared slice keeps the
            protection across every restart, reboot, and container
            recreation.

            Size it at or above the container's resident working set
            (weights + runtime) with a little slack. It is a
            protection floor, not a reservation — setting it well
            above actual usage wastes nothing.

            null (default) leaves the container in podman's default
            `machine.slice` with no reclaim protection. A host's own
            `--cgroup-parent` in `extraOptions` overrides the managed
            one (last flag wins), so the escape hatch can retarget the
            nesting if needed.
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

      # `lib.mkMerge`, not `//`: in this nixpkgs `lib.mkIf` yields a tagged
      # def (`{ _type = "if"; condition; content; }`), and `//` would merge
      # the tag FIELDS (silently dropping the first branch) instead of the
      # branches' contents.
      config =
        lib.mkMerge [
          (lib.mkIf cfg.enable {
            # The podman engine + its /etc/containers configuration (CNI
            # plugin dirs etc.) — a host that set virtualisation.podman
            # itself wins (mkDefault).
            virtualisation.podman.enable = lib.mkDefault true;

            # The API port, reachable from the host's network. The engine
            # port (8730) is never published — its protocol has no
            # authentication. Plain definition (priority 100), not
            # mkDefault: this nixpkgs's module system drops a definition
            # whose priority loses to another module's definition of the
            # same option — including for list options — and base modules
            # (podman/network-socket.nix, udp-over-tcp.nix) both define
            # `allowedTCPPorts` plainly, so a mkDefault [ port ] here
            # would never reach the firewall. Same-priority list defs
            # concatenate, so the hole stays additive.
            networking.firewall.allowedTCPPorts = [ cfg.port ];

            # Rootful podman under systemd. `SupplementaryGroups` +
            # `--group-add keep-groups` carry render/video into the
            # container for /dev/kfd and /dev/dri.
            #
            # Plain definition (priority 100), not mkDefault: on this
            # nixpkgs a host override of any sub-option (e.g.
            # `systemd.services.halogen-flash.enable = false` for an
            # installed-but-off-at-boot unit) would filter this whole
            # mkDefault definition out, leaving a unit with no ExecStart.
            # Same-priority attrsOf defs merge per key instead, so
            # `enable = false` composes with the full service while a
            # conflicting scalar override errors loudly rather than
            # corrupting the unit.
            systemd.services.halogen-flash = {
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
          })
          (lib.mkIf (cfg.memoryLow != null) {
            # Reclaim protection for the container's pages (see
            # `memoryLow`). The runner nests the container under this
            # slice with `--cgroup-parent`; the protection lives on the
            # slice so it survives podman's per-start random scope ids.
            # Plain definition (priority 100): a host that wants a
            # different value overrides the leaf, and the slice unit is
            # only instantiated when something lands under it.
            systemd.slices."halogen".sliceConfig.MemoryLow = cfg.memoryLow;
          })
          (lib.mkIf (cfg.gib != null) {
            # Standalone-host GTT ceiling. Same option nix-amd-ai uses (the
            # ttm `pages_limit` modprobe option) — see `gib` for the
            # do-not-combine contract with ai.amd.strix.vram.
            # Plain definition — same reason as the firewall hole above:
            # base modules (firewall.nix, network-interfaces.nix) carry
            # plain `extraModprobeConfig` definitions that would filter a
            # mkDefault out. The lines type concatenates same-priority
            # defs, so the host's modprobe options survive alongside.
            boot.extraModprobeConfig =
              "options ttm pages_limit=${toString (cfg.gib * 262144)}\n";
          })
        ];
    };
  };
}
