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

    # chipset "strix-point": NPU + FLM + Lemonade on, gfx1150 target, GPU
    # memory pool left at the kernel default (vram unset → both upstream
    # gpuMemory options stay null).
    test-strix-point = denTest (
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
        den.aspects.igloo.nixos.deniac.ai.amd.strix.chipset = "strix-point";
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
          gpuMemoryTtm = igloo.hardware.amd-npu.gpuMemory.ttmSizeGiB;
          gpuMemoryPagePool = igloo.hardware.amd-npu.gpuMemory.pagePoolSizeGiB;
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
          enableROCm = true;
          enableVulkan = true;
          enableVllm = false;
          exclusiveInference = false;
          gpuTarget = "gfx1150";
          ds4Enable = false;
          gpuMemoryTtm = null; # kernel default (~27 GB) untouched
          gpuMemoryPagePool = null;
          lemonadeUser = "tux";
          lemonadeHost = "localhost";
          lemonadePort = 13305;
          lemonadeAutoStart = true;
          lemonadeFlashAttn = "on";
        };
      }
    );

    # chipset "strix-halo" + vram "128gb": same stack, gfx1151 target, GTT
    # ceiling raised to the 104 GiB pair (the known-stable ceiling on a
    # 128 GB board — stutters reported past ~108 GiB; upstream's own Halo
    # measurements ran at ttmSizeGiB = 104).
    test-strix-halo-128gb = denTest (
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
        den.aspects.igloo.nixos.deniac.ai.amd.strix.chipset = "strix-halo";
        den.aspects.igloo.nixos.deniac.ai.amd.strix.vram = "128gb";
        den.aspects.igloo.nixos.deniac.ai.amd.strix.user = "tux";

        # Flat leaf projection (see test-strix-point note on why not the
        # whole submodule).
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
          gpuMemoryTtm = 104;
          gpuMemoryPagePool = 104;
          lemonadeUser = "tux";
        };
      }
    );

    # chipset "strix-halo" + vram "64gb": the vram axis is independent of the
    # chipset axis (a 64 GB Strix Halo board is a real thing) — same gfx1151
    # target, GTT ceiling at the 56 GiB pair.
    test-strix-halo-64gb = denTest (
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
        den.aspects.igloo.nixos.deniac.ai.amd.strix.chipset = "strix-halo";
        den.aspects.igloo.nixos.deniac.ai.amd.strix.vram = "64gb";
        den.aspects.igloo.nixos.deniac.ai.amd.strix.user = "tux";

        # Flat leaf projection (see test-strix-point note on why not the
        # whole submodule).
        expr = {
          gpuTarget = igloo.hardware.amd-npu.gpuTarget;
          gpuMemoryTtm = igloo.hardware.amd-npu.gpuMemory.ttmSizeGiB;
          gpuMemoryPagePool = igloo.hardware.amd-npu.gpuMemory.pagePoolSizeGiB;
        };
        expected = {
          gpuTarget = "gfx1151";
          gpuMemoryTtm = 56;
          gpuMemoryPagePool = 56;
        };
      }
    );

    # chipset + vram set but no user: the aspect stays inert — nix-amd-ai
    # keeps its own default (enable = false) rather than failing on the
    # required lemonade.user option.
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
        den.aspects.igloo.nixos.deniac.ai.amd.strix.chipset = "strix-halo";
        den.aspects.igloo.nixos.deniac.ai.amd.strix.vram = "128gb";

        expr = igloo.hardware.amd-npu.enable;
        expected = false;
      }
    );

    # Nothing set: the aspect is entirely inert — upstream defaults hold and
    # the aspect's own options keep their null defaults.
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
          chipset = igloo.deniac.ai.amd.strix.chipset;
          vram = igloo.deniac.ai.amd.strix.vram;
          user = igloo.deniac.ai.amd.strix.user;
        };
        expected = {
          enable = false;
          chipset = null;
          vram = null;
          user = null;
        };
      }
    );
  };
}
