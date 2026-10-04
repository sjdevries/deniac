# deniac.ai.comfyui — ComfyUI as a NixOS service, wrapping comfyui-nix.
#
# Wraps the utensils/comfyui-nix NixOS module (pinned flake input) with a
# small `deniac.ai.comfyui` option surface that maps onto `services.comfyui.*`.
#
# Why this aspect exists: AMD's stable pytorch.org ROCm wheels lag new-GPU
# ISA support by months — gfx1030 (5700XT), gfx1100 (7900XTX) and gfx1151
# (Strix Halo) all needed AMD's nightly channel before the stable wheels
# carried their ISA. The `rocmChannel` knob gives a host an escape hatch to
# run ComfyUI on an AMD GPU the stable wheels don't cover yet.
#
# Usage (a host running ComfyUI on a Strix Halo iGPU):
#
#   den.aspects.onyxia.includes = [ deniac.ai.comfyui ];
#   den.aspects.onyxia.nixos.deniac.ai.comfyui = {
#     enable = true;
#     gpuSupport = "rocm";
#     rocmChannel = "rocmNightly";   # gfx1151 nightly wheels
#     user = "sdevries";
#   };
#
# Everything comfyui-nix offers beyond the knobs here (extraArgs,
# extraPythonPackages, customNodes, listenAddress, …) can still be set
# directly on the host via `services.comfyui.*` — this aspect wraps only the
# common ones.
#
# NOTE: the pinned input is currently the sjdevries fork's
# `feat/rocm-nightly-channel` branch (see flake.nix) so the rocmNightly
# change can be tested on real gfx1151 hardware before the upstream PR
# merges. Re-point to github:utensils/comfyui-nix once merged.

{ inputs, lib, ... }:
let
  # Capture the comfyui-nix NixOS module now: the `nixos` content below is
  # evaluated later inside the host's nixosSystem eval, where `inputs` is
  # not a module argument.
  comfyuiModule = inputs.comfyui-nix.nixosModules.default;
in
{
  deniac.ai.comfyui = {
    description = ''
      ComfyUI — the node-graph image/video generation UI — as a NixOS
      service, wrapping the utensils/comfyui-nix flake (pinned input).

      The `rocmChannel` knob selects the ROCm wheel set when
      `gpuSupport = "rocm"`: "rocm71" / "rocm72" (stable) or
      "rocmNightly" (AMD's gfx1151 nightly, for AMD GPUs ahead of the
      stable wheels — e.g. Strix Halo / Ryzen AI MAX 395).
    '';

    nixos =
    { config, lib, ... }:
    let
      cfg = config.deniac.ai.comfyui;
    in
    {
      imports = [ comfyuiModule ];

      options.deniac.ai.comfyui = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable the ComfyUI service.";
        };

        gpuSupport = lib.mkOption {
          type = lib.types.enum [ "none" "cuda" "rocm" "xpu" ];
          default = "none";
          description = "GPU backend for ComfyUI (mirrors comfyui-nix's gpuSupport).";
        };

        rocmChannel = lib.mkOption {
          type = lib.types.enum [ "rocm71" "rocm72" "rocmNightly" ];
          default = "rocm71";
          description = ''
            When `gpuSupport = "rocm"`, which ROCm wheel set to use.

            - "rocm71" (default): the stable ROCm 7.1 wheels.
            - "rocm72": the stable ROCm 7.2 wheels. Use this for gfx1151
              (Strix Halo): it is the first stable whose HSA runtime
              (Ext 1.15 + gfx11-generic ISA) runs on that iGPU — rocm71
              SEGVs at the first kernel launch there.
            - "rocmNightly": AMD's gfx1151 nightly wheels, for AMD GPUs
              whose ISA no stable wheel carries yet.

            No effect unless `gpuSupport = "rocm"`.
          '';
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 8188;
          description = "Port ComfyUI listens on.";
        };

        dataDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/comfyui";
          description = "ComfyUI data directory (models, output, workflows).";
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = "comfyui";
          description = "Account the ComfyUI service runs as.";
        };

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open the firewall for the ComfyUI port.";
        };
      };

      config = lib.mkIf cfg.enable {
        services.comfyui = {
          enable = true;
          inherit (cfg) gpuSupport rocmChannel port dataDir user openFirewall;
        };
      };
    };
  };
}
