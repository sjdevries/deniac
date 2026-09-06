# deniac.ai.amd.strix tests — runs against the pinned den + nix-amd-ai inputs.
#
# Each case is a `denTest`: den evals one den flake per case (a host `igloo`
# plus the aspect under test) and yields the `{ expr, expected }` data. den's
# CI then runs the case with nix-unit, which deep-forces `expr` and compares
# it for deep equality with `expected` — so `expr` must be exactly the leaves
# under test (a flat projection), never a whole submodule: deep-forcing e.g.
# `hardware.amd-npu` wholesale would force `ds4.user` (an option with no value)
# and throw, and a full `lemonade` subtree would carry keys `expected` lacks.
#
# The `igloo` special arg is the host's evaluated NixOS config (lazy — only
# forced when destructured, so pure-NixOS cases stay home-manager-free).
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

    # Consumer-facing guarantee: once the `deniac` namespace is imported from
    # `inputs.self`, `deniac.ai.amd.strix` resolves to a usable den aspect
    # (a NixOS module under `nixos`) that a host can include. The other cases
    # exercise it by including it; this one asserts the node shape directly.
    test-namespace-export = denTest (
      {
        inputs,
        den,
        deniac,
        ...
      }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.amd.strix ];

        expr = deniac.ai.amd.strix ? nixos;
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

        # Flat leaf projection: nix-unit deep-forces `expr` and compares it
        # for deep equality with `expected`, so `expr` must be exactly the
        # leaves under test — selecting `igloo.hardware.amd-npu` wholesale
        # would deep-force `ds4.user` (an option with no value) and throw.
        expr = {
          enable = igloo.hardware.amd-npu.enable;
          enableNPU = igloo.hardware.amd-npu.enableNPU;
          enableFastFlowLM = igloo.hardware.amd-npu.enableFastFlowLM;
          enableLemonade = igloo.hardware.amd-npu.enableLemonade;
          enableImageGen = igloo.hardware.amd-npu.enableImageGen;
          enableROCm = igloo.hardware.amd-npu.enableROCm;
          enableVulkan = igloo.hardware.amd-npu.enableVulkan;
          enableVllm = igloo.hardware.amd-npu.enableVllm;
          exclusiveInference = igloo.hardware.amd-npu.exclusiveInference;
          gpuTarget = igloo.hardware.amd-npu.gpuTarget;
          ds4Enable = igloo.hardware.amd-npu.ds4.enable;
          lemonadeUser = igloo.hardware.amd-npu.lemonade.user;
          lemonadeHost = igloo.hardware.amd-npu.lemonade.host;
          lemonadePort = igloo.hardware.amd-npu.lemonade.port;
          lemonadeAutoStart = igloo.hardware.amd-npu.lemonade.autoStart;
          lemonadeFlashAttn = igloo.hardware.amd-npu.lemonade.flashAttn;
        };
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
          ds4Enable = false;
          lemonadeUser = "tux";
          lemonadeHost = "localhost";
          lemonadePort = 13305;
          lemonadeAutoStart = true;
          lemonadeFlashAttn = "on";
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

        # Flat leaf projection (see test-64gb note on why not the whole
        # submodule).
        expr = {
          enable = igloo.hardware.amd-npu.enable;
          gpuTarget = igloo.hardware.amd-npu.gpuTarget;
          gpuMemoryTtm = igloo.hardware.amd-npu.gpuMemory.ttmSizeGiB;
          gpuMemoryPagePool = igloo.hardware.amd-npu.gpuMemory.pagePoolSizeGiB;
          lemonadeUser = igloo.hardware.amd-npu.lemonade.user;
        };
        expected = {
          enable = true;
          gpuTarget = "gfx1151";
          gpuMemoryTtm = 96;
          gpuMemoryPagePool = 96;
          lemonadeUser = "tux";
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
