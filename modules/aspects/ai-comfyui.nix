# deniac.ai.comfyui — ComfyUI as a NixOS service, wrapping comfyui-nix.
#
# Wraps the utensils/comfyui-nix NixOS module (pinned flake input) with a
# small `deniac.ai.comfyui` option surface that maps onto `services.comfyui.*`.
#
# Why this aspect exists: AMD's stable pytorch.org ROCm wheels lag new-GPU
# ISA support by months — gfx1030 (5700XT), gfx1100 (7900XTX) and gfx1151
# (Strix Halo) each needed a newer wheel set than the then-default before the
# stable wheels carried their ISA. The `rocmChannel` knob makes that a
# deliberate per-host choice instead of inheriting whatever the default
# happens to be.
#
# For gfx1151 the answer is now `rocmChannel = "rocm72"` — the first STABLE
# release whose HSA runtime (Ext 1.15) + gfx11-generic ISA actually runs on
# that iGPU. Verified on real hardware 2026-10-31.
#
# Usage (a host running ComfyUI on a Strix Halo iGPU):
#
#   den.aspects.igloo.includes = [ deniac.ai.comfyui ];
#   den.aspects.igloo.nixos.deniac.ai.comfyui = {
#     enable = true;
#     gpuSupport = "rocm";
#     rocmChannel = "rocm72";   # gfx1151 (Strix Halo) needs >= rocm72
#     user = "tux";
#   };
#
# Everything comfyui-nix offers beyond the knobs here (extraArgs,
# extraPythonPackages, customNodes, listenAddress, …) can still be set
# directly on the host via `services.comfyui.*` — this aspect wraps only the
# common ones.
#
# NOTE (2026-11-08): this input used to be the sjdevries fork's
# nightly-channel branch while the rocmChannel change was being proven on
# real gfx1151 hardware. It merged upstream (utensils/comfyui-nix #112 +
# #115) and the pin moved back to upstream. `rocmNightly` was a value on
# that fork branch only — it is NOT an upstream option, so it has been
# removed from the enum below. Passing it would now fail at eval with an
# attribute lookup error inside comfyui-nix's python-overrides.

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
      `gpuSupport = "rocm"`: "rocm71" (default) or "rocm72" (stable,
      torch 2.14.x). Use "rocm72" for gfx1151 (Strix Halo / Ryzen AI MAX
      395) — the first stable release whose HSA runtime actually runs on
      that iGPU.
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
          type = lib.types.enum [ "rocm71" "rocm72" ];
          default = "rocm71";
          description = ''
            When `gpuSupport = "rocm"`, which ROCm wheel set to use.
            Mirrors comfyui-nix's own `rocmChannel` enum exactly — keep the
            two in sync when bumping the input.

            - "rocm71" (default): the stable ROCm 7.1 wheels.
            - "rocm72": the stable ROCm 7.2 wheels (torch 2.14.x). Use this
              for gfx1151 (Strix Halo): it is the first stable whose HSA
              runtime (Ext 1.15 + gfx11-generic ISA) runs on that iGPU —
              rocm71 SEGVs at the first kernel launch there.

            No effect unless `gpuSupport = "rocm"`.

            comfyui-nix also flips `rocmUsePyTorchAttention` to true
            automatically when this is "rocm72" — gfx1151 ships no xformers
            `ckF` kernels, so the default xformers path raises "No operator
            found for memory_efficient_attention_forward". That knob is not
            re-exposed here; set `services.comfyui.rocmUsePyTorchAttention`
            directly if you need to override it.
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
