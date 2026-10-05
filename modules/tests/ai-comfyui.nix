# Tests for `ai.comfyui` — same fresh-eval pattern as tests/ai-gufo.nix.
# The aspect wraps comfyui-nix's `services.comfyui.*`; these assert the
# deniac option surface maps onto it. Flat leaf selections (nix-unit 2.x
# deep-forces `expr`).

{ denTest, ... }:
{
  flake.tests.ai-comfyui = {

    test-namespace-export = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.ai.comfyui.description != null;
          hasNixosModule = builtins.isFunction deniac.ai.comfyui.nixos;
        };
        expected = {
          hasDescription = true;
          hasNixosModule = true;
        };
      }
    );

    # Nothing set: the wrapped service stays off and the option defaults
    # hold.
    test-inert-by-default = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.comfyui ];

        expr = {
          comfyuiEnable = igloo.services.comfyui.enable;
          enable = igloo.deniac.ai.comfyui.enable;
          gpuSupport = igloo.deniac.ai.comfyui.gpuSupport;
          rocmChannel = igloo.deniac.ai.comfyui.rocmChannel;
          port = igloo.deniac.ai.comfyui.port;
        };
        expected = {
          comfyuiEnable = false;
          enable = false;
          gpuSupport = "none";
          rocmChannel = "rocm71";
          port = 8188;
        };
      }
    );

    # enable + rocm + rocm72 (the gfx1151-capable stable channel): the
    # deniac options map straight onto services.comfyui.*.
    test-enabled-rocm72 = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.comfyui ];
        den.aspects.igloo.nixos.deniac.ai.comfyui = {
          enable = true;
          gpuSupport = "rocm";
          rocmChannel = "rocm72";
        };

        expr = {
          comfyuiEnable = igloo.services.comfyui.enable;
          gpuSupport = igloo.services.comfyui.gpuSupport;
          rocmChannel = igloo.services.comfyui.rocmChannel;
          port = igloo.services.comfyui.port;
          dataDir = igloo.services.comfyui.dataDir;
          user = igloo.services.comfyui.user;
        };
        expected = {
          comfyuiEnable = true;
          gpuSupport = "rocm";
          rocmChannel = "rocm72";
          port = 8188;
          dataDir = "/var/lib/comfyui";
          user = "comfyui";
        };
      }
    );

    # The rocmNightly escape hatch maps through too (the reason the fork
    # exists — gfx1151 ahead of the stable wheels).
    test-rocm-nightly-channel = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.comfyui ];
        den.aspects.igloo.nixos.deniac.ai.comfyui = {
          enable = true;
          gpuSupport = "rocm";
          rocmChannel = "rocmNightly";
          user = "tux";
        };

        expr = {
          rocmChannel = igloo.services.comfyui.rocmChannel;
          user = igloo.services.comfyui.user;
        };
        expected = {
          rocmChannel = "rocmNightly";
          user = "tux";
        };
      }
    );
  };
}
