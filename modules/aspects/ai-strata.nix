# deniac.ai.strata — Strata as a systemd service (wrapper around an
# installed engine).
#
# Strata (Niko1221/Strata, MIT) runs Qwen3.8-Flash-Next on a discrete
# GPU by tiering the MoE experts across GPU VRAM + host RAM + SSD. It is
# llama.cpp/ggml-based and consumes GGUF.
#
# ⚠ RUNTIME REALITY (why this is a wrapper, not a container):
#   * Strata's Docker image is **NVIDIA-only** (`FROM nvidia/cuda`,
#     `STRATA_ENABLE_CUDA=ON`). There is **no AMD container**.
#   * The AMD path (RX 7900 XT/XTX = gfx1100, etc.) is a **natively
#     compiled HIP/ROCm engine** produced by `setup.py` — not packaged
#     in nixpkgs.
#   * gfx1151 (Strix Halo / Ryzen AI Max+) is **experimental but
#     supported on Linux since Strata 0.1.40** — the Aurora port merged,
#     owner-confirmed in
#     https://github.com/Niko1221/Strata/issues/612 ("gfx1151 (Strix
#     Halo) is admitted as experimental in 0.1.40 on Linux"). `setup.sh`
#     auto-detects the chip (PCI 1002:1586), compiles the HIP engine
#     for it itself, and recommends UD-IQ4_XS from ~80 GB of unified
#     memory. No opt-in flag is needed — upstream docs/STRIX_HALO.md has
#     the toolchain details. 0.1.41 added gfx1151 hipBLASLt tuning
#     tables (#1388) and `STRATA_PREFILL_STREAM_MIN=128` in the gfx1151
#     fast config (#1391); 0.1.42 adds opt-in AMD/multi-GPU speedups
#     and fixes for Windows AMD and tight-RAM machines. (Windows Halo
#     support is still pending, #918.)
#
# Version reference: this aspect wraps the out-of-band install and pins
# nothing itself. The bump target is tag **v0.1.42** =
# `61b3fb5dd3f1e8ec09cf7e4e05208bc6d3c46406` (2026-10-10), the
# latest release (folds in the never-released 0.1.41.1 fixes).
#
# So this aspect does NOT build or containerize the engine. It manages a
# systemd service around a Strata install you create out-of-band with
# `./setup.sh` (which compiles the HIP engine and lays down
# `run-<model>.sh`), and wires the shared `ai.model-store` GGUF dir in
# via `--gguf-dir`. A full pure-Nix path needs a Nix derivation for the
# compiled engine (or an upstream AMD image) — the missing piece.
#
# Batteries-included: `ggufDir` defaults to the shared model-store's
# `gguf` path, so the weights live in the shared tree (downloaded once,
# backed up once) rather than a private Strata-data folder.
#
# Usage:
#   # 1. install the engine out-of-band (compiles the AMD HIP engine):
#   #    git clone https://github.com/Niko1221/Strata /opt/strata
#   #    cd /opt/strata && ./setup.sh --model IQ2_XS \
#   #        --gguf-dir /var/lib/ai-models/gguf --yes
#   # 2. enable the service:
#   den.aspects.igloo.includes = [ deniac.ai.model-store deniac.ai.strata ];
#   den.aspects.igloo.nixos.deniac.ai.strata.enable = true;

{ lib, ... }:
{
  deniac.ai.strata = {
    description = ''
      Strata (Niko1221/Strata, MIT) as a systemd service — a wrapper
      around a Strata install created out-of-band with `./setup.sh`
      (which compiles the AMD HIP/ROCm engine and lays down
      `run-<model>.sh`). The shared `ai.model-store` GGUF dir is wired
      in via `--gguf-dir`, so weights live in the shared tree.

      This is a WRAPPER, not a container: Strata's Docker image is
      NVIDIA-only and the AMD engine is compiled imperatively (not in
      nixpkgs). Targets discrete AMD GPUs (gfx1100+, e.g. RX 7900
      XT/XTX), and — experimental, Linux only — gfx1151 / Strix Halo
      (Ryzen AI Max+) since Strata 0.1.40: the Aurora port merged
      (Strata#612), and `setup.sh` auto-detects the chip; no extra
      option is needed on this side. Bump target: v0.1.42 (latest,
      2026-10-10), which adds opt-in AMD/multi-GPU speedups and fixes
      for Windows AMD and tight-RAM machines.
    '';

    nixos =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.ai.strata;
      runner = pkgs.writeShellScriptBin "strata-run" ''
        #!${pkgs.runtimeShell}
        set -eu
        RUN="${cfg.strataDir}/run-${cfg.model}.sh"
        if [ ! -x "$RUN" ]; then
          echo "strata: $RUN not found — install the engine first:" >&2
          echo "  cd ${cfg.strataDir} && ./setup.sh --model ${cfg.model} --gguf-dir ${cfg.ggufDir} --yes" >&2
          exit 1
        fi
        exec "$RUN" --gguf-dir ${lib.escapeShellArg cfg.ggufDir} \
          --port ${toString cfg.port} --host ${cfg.host} ${toString cfg.extraArgs}
      '';
    in
    {
      options.deniac.ai.strata = {
        enable = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = "Start the Strata service. Inert by default.";
        };

        strataDir = lib.mkOption {
          default = "/opt/strata";
          type = lib.types.str;
          description = ''
            Where Strata is installed (the folder you ran `./setup.sh`
            in). The service runs the installed `run-<model>.sh` from
            here. Must be installed out-of-band — this aspect does not
            build the engine.
          '';
        };

        model = lib.mkOption {
          default = "IQ2_XS";
          type = lib.types.str;
          description = ''
            The Strata model size to run (selects `run-<model>.sh`):
            e.g. `Q2_0`, `IQ2_XS`, `IQ3_XXS`, `IQ3_S`, `coder`. Must
            match a model you set up with `./setup.sh`.
          '';
        };

        ggufDir = lib.mkOption {
          default = config.deniac.ai.model-store.paths.gguf or "/var/lib/ai-models/gguf";
          type = lib.types.str;
          description = ''
            GGUF files dir, passed to Strata via `--gguf-dir`. Defaults
            to the shared `ai.model-store` `gguf` path so the weights
            live in the shared tree. (Strata builds its expert packs /
            MTP draft layer from these at setup time.)
          '';
        };

        port = lib.mkOption {
          default = 8080;
          type = lib.types.port;
          description = "Host port for the OpenAI-compatible API.";
        };

        host = lib.mkOption {
          default = "127.0.0.1";
          type = lib.types.str;
          description = "Bind address for the published port (loopback by default).";
        };

        user = lib.mkOption {
          default = "strata";
          type = lib.types.str;
          description = "Service user (created with render/video for GPU access).";
        };

        extraArgs = lib.mkOption {
          default = [ ];
          type = lib.types.listOf lib.types.str;
          description = "Extra args appended to the run script verbatim.";
        };
      };

      config =
        lib.mkMerge [
          (lib.mkIf cfg.enable {
            users.groups.${cfg.user} = lib.mkDefault { };
            users.users.${cfg.user} = lib.mkDefault {
              isSystemUser = true;
              group = cfg.user;
              extraGroups = [ "render" "video" ];
            };

            networking.firewall.allowedTCPPorts =
              lib.optionals (cfg.host != "127.0.0.1" && cfg.host != "localhost")
                [ cfg.port ];

            systemd.services.strata = {
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                User = cfg.user;
                Group = cfg.user;
                Restart = "always";
                RestartSec = "5s";
                # First model load + expert-pack prep can take minutes.
                TimeoutStartSec = "infinity";
                ExecStart = "${runner}/bin/strata-run";
              };
            };
          })
        ];
    };
  };
}
