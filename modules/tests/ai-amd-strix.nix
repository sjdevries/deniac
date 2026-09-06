# deniac.ai.amd.strix tests — runs against the pinned den + nix-amd-ai inputs.
#
# Each case is a `denTest`: den evals one den flake per case (a host `igloo`,
# the aspect under test, and `expr`/`expected` compared by denTest — shallow
# partial match when both are attrsets). The `igloo` special arg is the host's
# evaluated NixOS config (lazy — only forced when destructured, so pure-NixOS
# cases stay home-manager-free).
#
# The aspect under test lives in a separate tree file
# (`modules/aspects/ai-amd-strix.nix`), which the fresh denTest eval does NOT
# load. So each case re-registers the `deniac` namespace from `inputs.self`
# (the deniac flake itself — its `denful.deniac` output is a separate config
# branch from `flake.tests`, so this does not recurse). That makes `deniac`
# a module-arg in the fresh eval, so `deniac.ai.amd.strix` resolves.

{ denTest, ... }:
{
  flake.tests.ai-amd-strix = {

    # The namespace is exported to flake.denful, so consumers can reference
    # deniac.ai.amd.strix directly (the `deniac` module-arg comes from
    # `config._module.args.deniac = config.den.ful.deniac`).
    test-namespace-export = denTest (
      {
        inputs,
        config,
        den,
        deniac,
        ...
      }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.amd.strix ];

        expr = config.flake.denful ? deniac;
        expected = true;
      }
    );

    # Profile "64gb" (Strix Point): NPU + FLM + Lemonade on, gfx1150 target,
    # GPU memory pool left at the kernel default (upstream: no-op on 64 GB).
    test-64gb = denTest (
      {
        inputs,
        den,
        deniac,
        igloo,
        ...
      }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.amd.strix ];
        den.aspects.igloo.nixos.deniac.ai.amd.strix.profile = "64gb";
        den.aspects.igloo.nixos.deniac.ai.amd.strix.user = "tux";

        expr = igloo.hardware.amd-npu;
        expected = {
          enable = true;
          enableNPU = true;
          enableFastFlowLM = true;
          enableLemonade = true;
          enableImageGen = true;
          enableROCm = false;
          enableVulkan = false;
          enableVllm = false;
          exclusiveInference = false;
          gpuTarget = "gfx1150";
          gpuMemory = {
            ttmSizeGiB = null;
            pagePoolSizeGiB = null;
          };
          ds4.enable = false;
          lemonade = {
            user = "tux";
            host = "localhost";
            port = 13305;
            autoStart = true;
            flashAttn = "on";
            models = [ ];
            pruneUnlistedModels = false;
            customModels = { };
          };
        };
      }
    );

    # Profile "128gb" (Strix Halo): same stack, gfx1151 target, GTT ceiling
    # raised to the 96 GiB pair upstream measured on a Halo host.
    test-128gb = denTest (
      {
        inputs,
        den,
        deniac,
        igloo,
        ...
      }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.amd.strix ];
        den.aspects.igloo.nixos.deniac.ai.amd.strix.profile = "128gb";
        den.aspects.igloo.nixos.deniac.ai.amd.strix.user = "tux";

        expr = igloo.hardware.amd-npu;
        expected = {
          enable = true;
          gpuTarget = "gfx1151";
          gpuMemory = {
            ttmSizeGiB = 96;
            pagePoolSizeGiB = 96;
          };
          lemonade.user = "tux";
        };
      }
    );

    # Profile set but no user: the aspect stays inert — nix-amd-ai keeps its
    # own default (enable = false) rather than failing on the required
    # lemonade.user option.
    test-user-required = denTest (
      {
        inputs,
        den,
        deniac,
        igloo,
        ...
      }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.amd.strix ];
        den.aspects.igloo.nixos.deniac.ai.amd.strix.profile = "128gb";

        expr = igloo.hardware.amd-npu.enable;
        expected = false;
      }
    );

    # No profile (and no user): the aspect is entirely inert — upstream
    # defaults hold.
    test-inert-by-default = denTest (
      {
        inputs,
        den,
        deniac,
        igloo,
        ...
      }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.amd.strix ];

        expr = {
          enable = igloo.hardware.amd-npu.enable;
          profile = igloo.deniac.ai.amd.strix.profile;
          user = igloo.deniac.ai.amd.strix.user;
        };
        expected = {
          enable = false;
          profile = null;
          user = null;
        };
      }
    );
  };
}
